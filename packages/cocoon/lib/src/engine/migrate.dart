/// The on-device migration runner.
///
/// Runs inside the single open transaction: drops the field columns of every
/// migrated table (the reconciler rebuilds them from the rewritten documents
/// right after), rewrites the stored wire bytes in batches of 500, logs one
/// change row per rewritten document, and reports progress. See
/// `Cocoon.open`'s `migrations` parameter.
library;

import 'dart:typed_data';

import '../migration.dart';
import '../wire.dart';
import 'executor.dart';
import 'naming.dart';
import 'schema_sql.dart';

/// Documents re-read and rewritten per batch.
const migrationBatchSize = 500;

/// Applies every step of [pending] (sorted ascending by version, all with a
/// version greater than the stored one) to the database inside [tx].
///
/// Returns the SQL table names that were rewritten, so the reconciler can
/// rebuild their columns and indexes even when its stored shape hash
/// happens to match.
///
/// Throws an [ArgumentError] when two steps share a version, or when a step
/// names a model whose adapter was not registered at open: a migration for
/// an unregistered collection cannot run, and silently skipping it would
/// corrupt the field numbers of that data forever.
Future<Set<String>> runSchemaMigrationsInTx({
  required CocoonTx tx,
  required SchemaRegistry registry,
  required List<CocoonMigration> pending,
  required bool keepChanges,
  void Function(int done, int total)? onProgress,
}) async {
  for (var i = 1; i < pending.length; i++) {
    if (pending[i].version == pending[i - 1].version) {
      throw ArgumentError.value(
        pending[i].version,
        'migrations',
        'Two migrations declare version ${pending[i].version}',
      );
    }
  }
  final stepsByModel = <String, List<FieldMigration>>{};
  for (final migration in pending) {
    for (final step in migration.fields) {
      stepsByModel.putIfAbsent(step.model, () => []).add(step);
    }
  }

  final tables = <String, List<FieldMigration>>{};
  for (final MapEntry(key: model, value: steps) in stepsByModel.entries) {
    final entry = registry.byModel(model);
    if (entry == null) {
      throw ArgumentError.value(
        model,
        'migrations',
        'A migration rewrites model "$model", but no adapter for it was '
            'registered when the database was opened; register every '
            'collection of the app when migrations are used',
      );
    }
    tables[entry.table] = List.unmodifiable(steps);
  }

  var total = 0;
  final existing = <String, bool>{};
  for (final table in tables.keys) {
    final exists =
        await tx.getOptional(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          'AND name = ?',
          [table],
        ) !=
        null;
    existing[table] = exists;
    if (exists) {
      final row = await tx.getOptional('SELECT count(*) AS c FROM $table');
      total += row!['c']! as int;
    }
  }

  var done = 0;
  onProgress?.call(0, total);
  final rewrittenTables = <String>{};
  for (final MapEntry(key: table, value: steps) in tables.entries) {
    if (!existing[table]!) {
      // A brand-new collection: the reconciler creates its table after the
      // migrations, and there is no old data to rewrite.
      continue;
    }
    rewrittenTables.add(table);
    done += await _migrateTable(
      tx,
      table: table,
      steps: steps,
      keepChanges: keepChanges,
      progress: onProgress == null
          ? null
          : (rows) {
              done += rows;
              onProgress(done, total);
            },
    );
  }
  return rewrittenTables;
}

/// Drops every declared index and field column of [table], then rewrites its
/// documents through [steps] in batches. Returns the number of rows scanned.
///
/// Dropping all `f_` columns up front keeps the rewrite shape-agnostic: the
/// reconciler re-adds every declared column from the rewritten bytes right
/// after, which is exactly what makes same-name type changes (whose SQLite
/// column type or CHECK constraint differs from the old one) safe.
Future<int> _migrateTable(
  CocoonTx tx, {
  required String table,
  required List<FieldMigration> steps,
  required bool keepChanges,
  required void Function(int rows)? progress,
}) async {
  // Columns cannot be dropped while an index references them; every index
  // is rebuilt by the reconciler afterwards.
  final indexes = await tx.getAll(
    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
    [table],
  );
  for (final row in indexes) {
    final name = row['name']! as String;
    if (name.startsWith('cx_${table}_')) {
      await tx.execute('DROP INDEX IF EXISTS "$name"');
    }
  }
  final columns = await tx.getAll('PRAGMA table_info($table)');
  for (final row in columns) {
    final name = row['name']! as String;
    if (name.startsWith('f_')) {
      await tx.execute('ALTER TABLE $table DROP COLUMN "$name"');
    }
  }

  final updateSql = 'UPDATE $table SET data = ? WHERE path = ?';
  var scanned = 0;
  var lastPath = '';
  while (true) {
    final rows = await tx.getAll(
      'SELECT path, data FROM $table '
      'WHERE path > ? ORDER BY path LIMIT $migrationBatchSize',
      [lastPath],
    );
    if (rows.isEmpty) {
      break;
    }
    final updates = <List<Object?>>[];
    final rewritten = <String>[];
    for (final row in rows) {
      final path = row['path']! as String;
      lastPath = path;
      var bytes = row['data']! as Uint8List;
      var changed = false;
      for (final step in steps) {
        final rewrittenBytes = rewriteField(
          bytes,
          from: step.fromNumber,
          fromWire: step.fromWire,
          fromMap: step.fromMap,
          to: step.toNumber,
          toWire: step.toWire,
          toMap: step.toMap,
          convert: step.convert,
        );
        // rewriteField returns the same instance when the old field is
        // absent; such documents are neither updated nor logged.
        if (!identical(rewrittenBytes, bytes)) {
          bytes = rewrittenBytes;
          changed = true;
        }
      }
      scanned++;
      if (changed) {
        updates.add([bytes, path]);
        rewritten.add(path);
      }
    }
    if (updates.isNotEmpty) {
      await tx.executeBatch(updateSql, updates);
      if (keepChanges) {
        final at = DateTime.now().toUtc().microsecondsSinceEpoch;
        await tx.executeBatch(
          'INSERT INTO $changesTableName (tbl, path, op, at) '
          "VALUES (?, ?, 'set', ?)",
          [
            for (final path in rewritten) [table, path, at],
          ],
        );
      }
    }
    progress?.call(rows.length);
  }
  return scanned;
}
