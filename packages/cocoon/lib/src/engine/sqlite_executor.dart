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
