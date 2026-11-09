import 'package:sqlite_async/native.dart' show NativeSqliteOpenFactory;
import 'package:sqlite_async/sqlite_async.dart';

import 'executor.dart';

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
    final rows = await _db.getAll(sql, args);
    return [for (final row in rows) Map<String, Object?>.of(row)];
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
