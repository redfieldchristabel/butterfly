import 'package:cocoon/src/engine/executor.dart';

/// Records every statement that reaches SQLite, including statements inside
/// transactions, and forwards everything to a real executor.
final class SpyExecutor implements CocoonExecutor {
  SpyExecutor(this._inner);

  final CocoonExecutor _inner;

  /// Every SQL statement seen, in order, including inside transactions.
  final List<String> statements = [];

  /// Optional test hook: awaited with every statement before it forwards to
  /// SQLite. Lets a test act while a multi-statement read is still in
  /// flight (e.g. commit a write between two getAll chunks).
  Future<void> Function(String sql)? onStatement;

  Iterable<String> get ddlStatements => statements.where(
    (sql) => RegExp(
      r'^(CREATE|ALTER|DROP)\b',
      caseSensitive: false,
    ).hasMatch(sql.trim()),
  );

  Future<void> _record(String sql) async {
    statements.add(sql);
    final hook = onStatement;
    if (hook != null) {
      await hook(sql);
    }
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    await _record(sql);
    return _inner.getAll(sql, args);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    await _record(sql);
    return _inner.getOptional(sql, args);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    await _record(sql);
    return _inner.execute(sql, args);
  }

  @override
  Future<void> executeBatch(
    String sql,
    List<List<Object?>> parameterSets,
  ) async {
    await _record(sql);
    return _inner.executeBatch(sql, parameterSets);
  }

  @override
  Future<T> writeTransaction<T>(Future<T> Function(CocoonTx tx) body) =>
      _inner.writeTransaction<T>((tx) => body(_SpyTx(this, tx)));

  /// Whether a [readTransaction] body is currently running; lets a test
  /// prove that a statement was recorded inside the read transaction.
  bool inReadTransaction = false;

  @override
  Future<T> readTransaction<T>(Future<T> Function(CocoonRead tx) body) =>
      _inner.readTransaction<T>((tx) async {
        inReadTransaction = true;
        try {
          return await body(_SpyReadTx(this, tx));
        } finally {
          inReadTransaction = false;
        }
      });

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
  ]) async {
    await _spy._record(sql);
    return _inner.getAll(sql, args);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    await _spy._record(sql);
    return _inner.getOptional(sql, args);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    await _spy._record(sql);
    return _inner.execute(sql, args);
  }

  @override
  Future<void> executeBatch(
    String sql,
    List<List<Object?>> parameterSets,
  ) async {
    await _spy._record(sql);
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
  ]) async {
    await _spy._record(sql);
    return _inner.getAll(sql, args);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    await _spy._record(sql);
    return _inner.getOptional(sql, args);
  }
}
