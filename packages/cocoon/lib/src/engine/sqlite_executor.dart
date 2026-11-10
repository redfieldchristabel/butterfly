import 'dart:io';
import 'dart:isolate';

import 'package:sqlite_async/native.dart' show NativeSqliteOpenFactory;
import 'package:sqlite_async/sqlite_async.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

import 'aggregate.dart' show AggregateOverflowException;
import 'executor.dart';
import 'naming.dart';

/// [CocoonExecutor] on a `SqliteDatabase` (package:sqlite_async, WAL by
/// default).
///
/// This is the only file in Cocoon allowed to import `package:sqlite_async`
/// or `package:sqlite3`.
final class SqliteExecutor implements CocoonExecutor {
  /// Wraps an open database.
  SqliteExecutor(this._db);

  final SqliteDatabase _db;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    List<Map<String, Object?>> rows;
    try {
      rows = [
        for (final row in await _db.getAll(sql, args))
          Map<String, Object?>.of(row),
      ];
    } on raw.SqliteException catch (error) {
      // SQLite refuses to wrap: an aggregate SUM past ±2^63 aborts the
      // statement with "integer overflow". Surface it as the typed error
      // (no other Cocoon statement can legitimately produce that message).
      if (error.message.contains('integer overflow')) {
        throw AggregateOverflowException(
          'A sum in this aggregate query exceeded the 64-bit integer '
          'range: ${error.message}',
        );
      }
      rethrow;
    }
    return rows;
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final row = await _db.getOptional(sql, args);
    return row == null ? null : Map<String, Object?>.of(row);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    await _db.execute(sql, args);
  }

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _db.executeBatch(sql, parameterSets);

  @override
  Future<T> writeTransaction<T>(Future<T> Function(CocoonTx tx) body) =>
      _db.writeTransaction<T>((ctx) => body(_SqliteTx(ctx)));

  @override
  Future<T> readTransaction<T>(Future<T> Function(CocoonRead tx) body) =>
      _db.readTransaction<T>((ctx) => body(_SqliteReadTx(ctx)));

  @override
  Future<void> close() => _db.close();
}

/// The open factory behind `Cocoon.open`: sqlite_async's native factory plus
/// the `PRAGMA`s [CocoonOptions] tunes for which the factory API has no
/// option — the page cache (`PRAGMA cache_size`), the temp store
/// (`PRAGMA temp_store = MEMORY`) and the WAL auto-checkpoint interval
/// (`PRAGMA wal_autocheckpoint`).
///
/// sqlite_async runs [pragmaStatements] on EVERY connection it opens (the
/// primary write connection and every pooled reader), so the knobs hold for
/// writes and reads alike.
final class CocoonSqliteOpenFactory extends NativeSqliteOpenFactory {
  /// Builds the factory; [pageCacheKib] is the negative-KiB `cache_size`
  /// (0 keeps SQLite's default), [tempStoreInMemory] adds
  /// `PRAGMA temp_store = MEMORY` and [walAutoCheckpointPages] sets the
  /// checkpoint interval on writable connections (0 keeps SQLite's default).
  CocoonSqliteOpenFactory({
    required super.path,
    required super.sqliteOptions,
    required int pageCacheKib,
    required bool tempStoreInMemory,
    required int walAutoCheckpointPages,
  }) : _pageCacheKib = pageCacheKib,
       _tempStoreInMemory = tempStoreInMemory,
       _walAutoCheckpointPages = walAutoCheckpointPages;

  final int _pageCacheKib;
  final bool _tempStoreInMemory;
  final int _walAutoCheckpointPages;

  @override
  List<String> pragmaStatements(SqliteOpenOptions options) => [
    ...super.pragmaStatements(options),
    // Writer only: the big cache and in-memory temp store are what bulk
    // writes need; readers keep SQLite's defaults so a phone with several
    // pooled readers doesn't hold several 64 MiB caches, and reads behave as
    // they were measured.
    if (!options.readOnly && _pageCacheKib > 0)
      'PRAGMA cache_size = -$_pageCacheKib',
    if (!options.readOnly && _tempStoreInMemory) 'PRAGMA temp_store = MEMORY',
    if (!options.readOnly && _walAutoCheckpointPages > 0)
      'PRAGMA wal_autocheckpoint = $_walAutoCheckpointPages',
    // The larger checkpoint interval lets the WAL grow to ~32 MiB under bulk
    // writes; once a checkpoint resets it, shrink the file back so an idle
    // database doesn't keep that much disk.
    if (!options.readOnly) 'PRAGMA journal_size_limit = $walIdleLimitBytes',
  ];
}

/// The WAL size SQLite truncates back to after a checkpoint (4 MiB).
const walIdleLimitBytes = 4 * 1024 * 1024;

final class _SqliteTx implements CocoonTx {
  _SqliteTx(this._ctx);

  final SqliteWriteContext _ctx;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final rows = await _ctx.getAll(sql, args);
    return [for (final row in rows) Map<String, Object?>.of(row)];
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final row = await _ctx.getOptional(sql, args);
    return row == null ? null : Map<String, Object?>.of(row);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    await _ctx.execute(sql, args);
  }

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _ctx.executeBatch(sql, parameterSets);
}

final class _SqliteReadTx implements CocoonRead {
  _SqliteReadTx(this._ctx);

  final SqliteReadContext _ctx;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final rows = await _ctx.getAll(sql, args);
    return [for (final row in rows) Map<String, Object?>.of(row)];
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final row = await _ctx.getOptional(sql, args);
    return row == null ? null : Map<String, Object?>.of(row);
  }
}

// -- Raw file work behind the backup primitives -----------------------------
//
// Backup copies, metadata stamping and integrity inspection work on FILES
// (the backup, the copy, the restored database), not on the open
// `CocoonExecutor`, so they run raw `package:sqlite3` connections inside
// `Isolate.run`: a large file is read off the calling isolate, the source
// database's own connections are untouched (SQLite happily serves one more
// read-only workload next to sqlite_async's writer in WAL mode), and a copy
// keeps the journal mode `VACUUM INTO` produced instead of being re-headered
// to WAL by a sqlite_async open.

/// The internal metadata and health of a Cocoon SQLite file, read raw.
final class RawFileMeta {
  RawFileMeta({
    required this.integrity,
    required this.hasCocoonMeta,
    required this.values,
    required this.lastChangeSeq,
  });

  /// The `PRAGMA integrity_check` messages, exactly `['ok']` when the file
  /// is healthy. Empty when the caller asked to skip the check (a file this
  /// process just wrote).
  final List<String> integrity;

  /// Whether the file has a `_cocoon_meta` table.
  final bool hasCocoonMeta;

  /// The `_cocoon_meta` rows, empty when the table is absent.
  final Map<String, String> values;

  /// The change log's AUTOINCREMENT head (`sqlite_sequence` of
  /// `_cocoon_changes`), `0` when the log was never written.
  final int lastChangeSeq;

  /// The parsed `schema_version` meta value, `null` when absent.
  int? get schemaVersion => int.tryParse(values[schemaVersionMetaKey] ?? '');

  /// The parsed `format_version` meta value (the file's storage format),
  /// `null` when the file predates format tracking.
  int? get storageFormatVersion =>
      int.tryParse(values[formatVersionMetaKey] ?? '');
}

/// Writes a consistent, compacted copy of the SQLite file at [sourcePath]
/// to [targetPath] with `VACUUM INTO` (the statement takes one read snapshot
/// of the source and creates a fresh, compacted, single-file database in
/// rollback-journal mode; the source must exist and is only read).
///
/// [targetPath] must not exist — SQLite refuses to overwrite, which is what
/// makes the partial-file protocol in `BackupOperations` safe.
Future<void> vacuumInto({
  required String sourcePath,
  required String targetPath,
}) {
  return Isolate.run(() => _vacuumIntoSync(sourcePath, targetPath));
}

void _vacuumIntoSync(String sourcePath, String targetPath) {
  if (!File(sourcePath).existsSync()) {
    throw FileSystemException('No such file', sourcePath);
  }
  final db = raw.sqlite3.open(sourcePath);
  try {
    db.execute('PRAGMA busy_timeout = 10000');
    db.execute('VACUUM INTO ${_sqlString(targetPath)}');
  } finally {
    db.close();
  }
}

/// Reads a Cocoon SQLite file's structure and `_cocoon_meta` rows raw, with
/// `PRAGMA integrity_check` when [withIntegrity] is set (an integrity check
/// reads every page; the caller decides whether the file warrants it).
///
/// A file SQLite cannot read (garbage, truncated) makes the first statement
/// throw; the caller maps that to a typed backup error.
Future<RawFileMeta> readCocoonMeta(String path, {required bool withIntegrity}) {
  return Isolate.run(() => _readCocoonMetaSync(path, withIntegrity));
}

RawFileMeta _readCocoonMetaSync(String path, bool withIntegrity) {
  final db = raw.sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 10000');
    final integrity = withIntegrity
        ? [
            for (final row in db.select('PRAGMA integrity_check'))
              '${row.values.first}',
          ]
        : const <String>[];
    final hasMeta =
        db
                .select(
                  "SELECT count(*) AS c FROM sqlite_master WHERE type = 'table' "
                  'AND name = ?',
                  [metaTableName],
                )
                .first
                .values
                .first
            as int >
        0;
    final values = <String, String>{
      if (hasMeta)
        for (final row in db.select('SELECT key, value FROM $metaTableName'))
          row['key']! as String: row['value']! as String,
    };
    return RawFileMeta(
      integrity: integrity,
      hasCocoonMeta: hasMeta,
      values: values,
      lastChangeSeq: _changeSeqHeadOf(db),
    );
  } finally {
    db.close();
  }
}

/// Writes [values] into a file's `_cocoon_meta` (creating the table when it
/// is missing) and replaces the instance id with [instanceId], in one
/// transaction. Also records the file's own change-log head under
/// `backup_last_change_seq` — by construction it matches `sqlite_sequence`.
///
/// Used on backup copies (stamping backup metadata, re-rolling the throwaway
/// instance id) and on restored databases (the final instance id). Returns
/// the file's metadata as it is after the write.
Future<RawFileMeta> stampCocoonMeta({
  required String path,
  required Map<String, String> values,
  required String instanceId,
}) {
  return Isolate.run(() => _stampCocoonMetaSync(path, values, instanceId));
}

RawFileMeta _stampCocoonMetaSync(
  String path,
  Map<String, String> values,
  String instanceId,
) {
  final db = raw.sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 10000');
    db.execute('BEGIN IMMEDIATE');
    var committed = false;
    try {
      db.execute(
        'CREATE TABLE IF NOT EXISTS $metaTableName '
        '(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      final all = {
        ...values,
        backupLastChangeSeqMetaKey: '${_changeSeqHeadOf(db)}',
        instanceIdMetaKey: instanceId,
      };
      for (final MapEntry(key: key, value: value) in all.entries) {
        db.execute(
          'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
          [key, value],
        );
      }
      db.execute('COMMIT');
      committed = true;
    } finally {
      if (!committed) {
        try {
          db.execute('ROLLBACK');
        } on Object {
          // A statement error may have rolled the transaction back already.
        }
      }
    }
  } finally {
    db.close();
  }
  return _readCocoonMetaSync(path, false);
}

/// The change log's AUTOINCREMENT head, `0` when the log was never written
/// (the `sqlite_sequence` table itself may not exist yet).
int _changeSeqHeadOf(raw.Database db) {
  final hasSequence =
      db
              .select(
                "SELECT count(*) AS c FROM sqlite_master WHERE type = 'table' "
                "AND name = 'sqlite_sequence'",
              )
              .first
              .values
              .first
          as int >
      0;
  if (!hasSequence) {
    return 0;
  }
  final row = db.select('SELECT seq FROM sqlite_sequence WHERE name = ?', [
    changesTableName,
  ]).firstOrNull;
  return row == null ? 0 : row['seq']! as int;
}

/// Quotes [value] as a SQL string literal (the only place Cocoon inlines a
/// runtime value into SQL: `VACUUM INTO` takes no bound parameters).
String _sqlString(String value) => "'${value.replaceAll("'", "''")}'";
