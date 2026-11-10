/// The on-device migration runner.
///
/// Runs inside the single open transaction: drops the field columns of every
/// rewritten table (the reconciler rebuilds them from the rewritten documents
/// right after), rewrites the stored wire bytes in batches of 500 — field
/// rewrites at the wire level, then document backfills through the decoded
/// documents — logs one change row per rewritten document, and reports
/// progress. See `Cocoon.open`'s `migrations` parameter.
library;

import 'dart:typed_data';

import '../migration.dart';
import '../wire.dart';
import 'executor.dart';
import 'naming.dart';
import 'schema_sql.dart';

/// Documents re-read and rewritten per batch.
const migrationBatchSize = 500;

/// The migration steps of one model: its wire-level field rewrites, then its
/// document backfills (the stubs see the document as the rewrites left it).
typedef _ModelSteps = ({
  List<FieldMigration> rewrites,
  List<BackfillMigration<Object?>> backfills,
});

/// Applies every step of [pending] (sorted ascending by version, all with a
/// version greater than the stored one) to the database inside [tx].
///
/// Returns the SQL table names that were rewritten or backfilled, so the
/// reconciler can rebuild their columns and indexes even when its stored
/// shape hash happens to match.
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
  final rewritesByModel = <String, List<FieldMigration>>{};
  final backfillsByModel = <String, List<BackfillMigration<Object?>>>{};
  for (final migration in pending) {
    for (final step in migration.fields) {
      rewritesByModel.putIfAbsent(step.model, () => []).add(step);
    }
    for (final step in migration.backfills) {
      backfillsByModel.putIfAbsent(step.model, () => []).add(step);
    }
  }

  final tables = <String, _ModelSteps>{};
  for (final model in {...rewritesByModel.keys, ...backfillsByModel.keys}) {
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
    tables[model] = (
      rewrites: rewritesByModel[model] ?? const [],
      backfills: backfillsByModel[model] ?? const [],
    );
  }

  var total = 0;
  final existing = <String, bool>{};
  for (final model in tables.keys) {
    final table = registry.byModel(model)!.table;
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
  for (final MapEntry(key: model, value: steps) in tables.entries) {
    final entry = registry.byModel(model)!;
    if (!existing[entry.table]!) {
      // A brand-new collection: the reconciler creates its table after the
      // migrations, and there is no old data to rewrite.
      continue;
    }
    rewrittenTables.add(entry.table);
    done += await _migrateTable(
      tx,
      entry: entry,
      rewrites: steps.rewrites,
      backfills: steps.backfills,
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

/// Migrates [entry]'s table through [rewrites] and [backfills] in batches.
/// Returns the number of rows scanned.
///
/// Tables with field rewrites drop every declared index and `f_` column up
/// front: the rewrite is then shape-agnostic (a same-name type change's new
/// column type or CHECK cannot conflict with the old one) and the reconciler
/// re-adds every declared column from the rewritten bytes right after.
/// Backfill-only tables keep their columns: the added field's column does
/// not exist yet, and the reconciler adds it from the backfilled bytes.
///
/// Rows are scanned in rowid order and updated by their scope key; the
/// change-log rows a rewrite or backfill appends carry the full path derived
/// from each row's key columns.
Future<int> _migrateTable(
  CocoonTx tx, {
  required RegistryEntry entry,
  required List<FieldMigration> rewrites,
  required List<BackfillMigration<Object?>> backfills,
  required bool keepChanges,
  required void Function(int rows)? progress,
}) async {
  final table = entry.table;
  if (rewrites.isNotEmpty) {
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
  }

  final keyWhere = [
    ...entry.paramSqlNames,
    'id',
  ].map((name) => '$name = ?').join(' AND ');
  final updateSql = 'UPDATE $table SET data = ? WHERE $keyWhere';
  var scanned = 0;
  var lastRowId = 0;
  while (true) {
    final rows = await tx.getAll(
      'SELECT rowid, ${[...entry.paramSqlNames, 'id', 'data'].join(', ')} '
      'FROM $table WHERE rowid > ? ORDER BY rowid LIMIT $migrationBatchSize',
      [lastRowId],
    );
    if (rows.isEmpty) {
      break;
    }
    final updates = <List<Object?>>[];
    final rewritten = <(String, String)>[];
    for (final row in rows) {
      lastRowId = row['rowid']! as int;
      var bytes = row['data']! as Uint8List;
      var changed = false;
      for (final step in rewrites) {
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
      if (backfills.isNotEmpty) {
        // One decode per row: every backfill stub of this migration sees the
        // same document — the one this version's rewrites left. The stubs'
        // values are written at their (fresh) field numbers, replacing
        // whatever the bytes carried.
        final doc = entry.adapter.decode(bytes);
        for (final step in backfills) {
          final value = step.apply(doc);
          if (value == null) {
            throw ArgumentError(
              'The backfill of ${step.model}.${step.fieldName} returned null, '
              'but the field is non-nullable: return the value existing '
              'documents should read (or throw to abort the migration)',
            );
          }
          bytes = writeField(
            bytes,
            field: step.fieldNumber,
            wire: step.wire,
            value: _backfillWireValue(value, step.fieldType),
          );
          changed = true;
        }
      }
      scanned++;
      if (changed) {
        updates.add([
          bytes,
          for (final name in entry.paramSqlNames) row[name]! as String,
          row['id']! as String,
        ]);
        rewritten.add((table, entry.pathOfKeyRow(row)));
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
            for (final (tbl, path) in rewritten) [tbl, path, at],
          ],
        );
      }
    }
    progress?.call(rows.length);
  }
  return scanned;
}

/// Converts a backfill stub's returned value to the wire-level value
/// [writeField] encodes: `DateTime` fields take the value's UTC
/// microseconds (the generator encodes them the same way), enums their
/// name; every other storable scalar is already wire-shaped and the wire
/// write type-checks it.
Object _backfillWireValue(Object value, String fieldType) {
  final base = fieldType.endsWith('?')
      ? fieldType.substring(0, fieldType.length - 1)
      : fieldType;
  if (base == 'DateTime') {
    return (value as DateTime).toUtc().microsecondsSinceEpoch;
  }
  if (base.startsWith('enum:')) {
    return (value as Enum).name;
  }
  return value;
}
