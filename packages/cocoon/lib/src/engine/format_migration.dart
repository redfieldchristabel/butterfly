/// The storage-format migration: rebuilding an older file's collection
/// tables to the current layout, inside the open.
///
/// Cocoon stamps every file with its storage format version
/// (`_cocoon_meta`, [formatVersionMetaKey]). Format 1 stored a redundant
/// `path TEXT NOT NULL UNIQUE` column (and its autoindex) in every
/// collection table; format 2 ([storageFormatVersion], this engine) drops
/// both — a document is its scope key (the `p_` param columns plus `id`,
/// enforced by the unique scope index) and the path is derived from it.
///
/// An older file is rebuilt **table by table** — new table, `INSERT ...
/// SELECT`, drop, rename, recreate the indexes — inside the single open
/// transaction, so a crash at any point rolls back to the old layout and
/// the next open redoes the work. A file written by a NEWER format refuses
/// to open with [StorageFormatTooNewException].
library;

import 'package:meta/meta.dart';

import 'executor.dart';
import 'naming.dart';

/// The file at [path] was written by a storage format newer than this
/// engine's ([storageFormatVersion]): the app is older than the app that
/// last wrote the file. Upgrade the app and try again.
final class StorageFormatTooNewException implements Exception {
  /// Builds the exception with the file's format version and the greatest
  /// version this engine reads.
  StorageFormatTooNewException({
    required this.path,
    required this.formatVersion,
    required this.maxSupported,
  });

  /// The database file that refused to open. Empty when the format was
  /// refused without a file (a custom executor over an old file).
  final String path;

  /// The storage format version the file carries.
  final int formatVersion;

  /// The greatest storage format version this engine understands.
  final int maxSupported;

  @override
  String toString() =>
      'StorageFormatTooNewException: ${path.isEmpty ? 'the database' : path} '
      'was written in storage format $formatVersion; this Cocoon reads up '
      'to $maxSupported. The file was written by a newer app version — '
      'upgrade the app and open it again.';
}

/// The steps of one table's rebuild, in order. Tests inject a failure
/// before a step ([FormatMigrator.debugFailBeforeStep]) to prove the open
/// rolls back cleanly and the next open finishes the migration.
enum FormatMigrationStep {
  /// Create the replacement table with the current layout.
  createTable,

  /// Copy every row from the old table into the replacement.
  copyRows,

  /// Drop the old table (its `path` column and autoindex go with it).
  dropTable,

  /// Rename the replacement table over the old name.
  renameTable,

  /// Recreate the old table's named indexes on the rebuilt table.
  recreateIndexes,

  /// Stamp the new [formatVersionMetaKey] into `_cocoon_meta`.
  writeVersion,
}

/// Rebuilds an older file's collection tables to [storageFormatVersion].
final class FormatMigrator {
  FormatMigrator._();

  /// When set, the next [migrateInTx] throws a [StateError] just before the
  /// given step, without performing it, and clears itself. Test-only; the
  /// open transaction rolls back, so the file keeps its old layout.
  @visibleForTesting
  static FormatMigrationStep? debugFailBeforeStep;

  /// Rebuilds every collection table of [tx]'s database that still carries
  /// the format-1 `path` column, then stamps the new format version.
  ///
  /// Runs inside the caller's write transaction (the open's). [onProgress]
  /// reports `(documents copied, documents total)` after each table.
  /// Returns how many tables were rebuilt: 0 for a fresh database or an
  /// already-current file, more when an older layout was actually converted
  /// (the open decides on a post-upgrade compaction from this).
  ///
  /// The rebuild is shape-preserving: each table is recreated from its own
  /// stored `CREATE` SQL minus the `path` column, so hand-tuned or
  /// not-currently-registered tables survive the upgrade too; the open's
  /// schema reconciliation aligns registered tables with the app's current
  /// adapters right after.
  static Future<int> migrateInTx(
    CocoonTx tx, {
    void Function(int done, int total)? onProgress,
  }) async {
    final injected = debugFailBeforeStep;
    debugFailBeforeStep = null;
    final tables = await _collectionTablesWithPath(tx);
    var total = 0;
    final counts = <String, int>{};
    for (final table in tables) {
      final row = await tx.getOptional('SELECT count(*) AS c FROM "$table"');
      final count = row?['c']! as int;
      counts[table] = count;
      total += count;
    }
    var done = 0;
    onProgress?.call(0, total);
    for (final table in tables) {
      done += await _rebuildTable(
        tx,
        table,
        counts[table]!,
        injected,
        progress: onProgress == null
            ? null
            : (rows) {
                done += rows;
                onProgress(done, total);
              },
      );
    }
    _failBefore(injected, FormatMigrationStep.writeVersion);
    await tx.execute(
      'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
      [formatVersionMetaKey, '$storageFormatVersion'],
    );
    return tables.length;
  }

  /// Throws the injected [StateError] when [injected] names [step].
  static void _failBefore(
    FormatMigrationStep? injected,
    FormatMigrationStep step,
  ) {
    if (injected == step) {
      throw StateError('Injected test failure before the $step step');
    }
  }

  /// The user tables (not SQLite's `sqlite_*`, not Cocoon's `_cocoon_*`)
  /// whose columns still include the format-1 `path` column, in file order.
  static Future<List<String>> _collectionTablesWithPath(CocoonTx tx) async {
    final tables = await tx.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY rowid",
    );
    final result = <String>[];
    for (final row in tables) {
      final name = row['name']! as String;
      if (name.startsWith('sqlite_') || name.startsWith('_cocoon')) {
        continue;
      }
      final columns = await tx.getAll('PRAGMA table_info("$name")');
      if (columns.any((column) => column['name'] == 'path')) {
        result.add(name);
      }
    }
    return result;
  }

  /// Rebuilds [table] without its `path` column. [count] is the table's row
  /// count, reported through [progress] after the copy. Returns [count].
  ///
  /// The stored `CREATE` SQL is the exact statement the old engine ran, so
  /// removing its one `path` column definition and re-running it against a
  /// temporary name reproduces the table's real shape (types, CHECK
  /// constraints) without needing the app's adapters.
  static Future<int> _rebuildTable(
    CocoonTx tx,
    String table,
    int count,
    FormatMigrationStep? injected, {
    required void Function(int rows)? progress,
  }) async {
    final createRow = await tx.getOptional(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    final createSql = createRow?['sql']! as String;
    // The format-1 DDL always declared `path` as the first column with a
    // trailing comma; remove it together with that comma (and whatever
    // whitespace the stored statement carries around it).
    final pathDef = RegExp(r'\s*path TEXT NOT NULL UNIQUE\s*,');
    if (!pathDef.hasMatch(createSql)) {
      throw StateError(
        'Storage format migration: table $table has a path column but its '
        'CREATE statement does not declare one as Cocoon wrote it',
      );
    }
    final columns = await tx.getAll('PRAGMA table_info("$table")');
    final kept = [
      for (final column in columns)
        if (column['name'] != 'path') '"${column['name']}"',
    ];
    final tmp = '${table}_cocoon_format2_tmp';
    // SQLite stores the executed statement verbatim minus `IF NOT EXISTS`,
    // so the header may carry either form.
    final tmpCreate = createSql
        .replaceFirst(pathDef, '')
        .replaceFirst(
          RegExp(r'^\s*CREATE TABLE (?:IF NOT EXISTS\s+)?\S+\s*\('),
          'CREATE TABLE "$tmp" (',
        );
    final indexSqls = [
      for (final row in await tx.getAll(
        "SELECT sql FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = ? AND sql IS NOT NULL",
        [table],
      ))
        row['sql']! as String,
    ];

    _failBefore(injected, FormatMigrationStep.createTable);
    await tx.execute('DROP TABLE IF EXISTS "$tmp"');
    await tx.execute(tmpCreate);
    _failBefore(injected, FormatMigrationStep.copyRows);
    await tx.execute(
      'INSERT INTO "$tmp" (${kept.join(', ')}) '
      'SELECT ${kept.join(', ')} FROM "$table"',
    );
    _failBefore(injected, FormatMigrationStep.dropTable);
    await tx.execute('DROP TABLE "$table"');
    _failBefore(injected, FormatMigrationStep.renameTable);
    await tx.execute('ALTER TABLE "$tmp" RENAME TO "$table"');
    _failBefore(injected, FormatMigrationStep.recreateIndexes);
    for (final sql in indexSqls) {
      await tx.execute(sql);
    }
    progress?.call(count);
    return count;
  }
}
