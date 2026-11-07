import 'package:cocoon/src/engine/executor.dart';

/// Records every statement that reaches SQLite, including statements inside
/// transactions, and forwards everything to a real executor.
final class SpyExecutor implements CocoonExecutor {
  SpyExecutor(this._inner);

  final CocoonExecutor _inner;

  /// Every SQL statement seen, in order, including inside transactions.
  final List<String> statements = [];

  Iterable<String> get ddlStatements => statements.where(
    (sql) => RegExp(
      r'^(CREATE|ALTER|DROP)\b',
      caseSensitive: false,
    ).hasMatch(sql.trim()),
  );

  void _record(String sql) => statements.add(sql);

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) {
    _record(sql);
    return _inner.getAll(sql, args);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) {
    _record(sql);
    return _inner.getOptional(sql, args);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) {
    _record(sql);
    return _inner.execute(sql, args);
  }

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) {
    _record(sql);
    return _inner.executeBatch(sql, parameterSets);
  }

  @override
  Future<T> writeTransaction<T>(Future<T> Function(CocoonTx tx) body) =>
      _inner.writeTransaction<T>((tx) => body(_SpyTx(this, tx)));

  @override
  Future<T> readTransaction<T>(Future<T> Function(CocoonRead tx) body) =>
      _inner.readTransaction<T>((tx) => body(_SpyReadTx(this, tx)));

  @override
  Future<void> close() => _inner.close();
}

final class _SpyTx implements CocoonTx {
  _SpyTx(this._spy, this._inner);

  final SpyExecutor _spy;
  final CocoonTx _inner;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) {
    _spy._record(sql);
    return _inner.getAll(sql, args);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) {
    _spy._record(sql);
    return _inner.getOptional(sql, args);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) {
    _spy._record(sql);
    return _inner.execute(sql, args);
  }

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) {
    _spy._record(sql);
    return _inner.executeBatch(sql, parameterSets);
  }
}

final class _SpyReadTx implements CocoonRead {
  _SpyReadTx(this._spy, this._inner);

  final SpyExecutor _spy;
  final CocoonRead _inner;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) {
    _spy._record(sql);
    return _inner.getAll(sql, args);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) {
    _spy._record(sql);
    return _inner.getOptional(sql, args);
  }
}
