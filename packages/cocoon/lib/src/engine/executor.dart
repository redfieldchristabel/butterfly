/// The internal executor interface every Cocoon database talks to.
///
/// The only implementation is `SqliteExecutor` (package:sqlite_async), which
/// lives in `sqlite_executor.dart` — the single file allowed to import the
/// SQLite packages. Swapping to another executor (raw `package:sqlite3`, or a
/// web build later) touches that one file.
library;

/// Read-only access used by query execution and document reads.
abstract interface class CocoonRead {
  /// Runs a `SELECT` and returns every row as a name-to-value map.
  Future<List<Map<String, Object?>>> getAll(String sql, [List<Object?> args]);

  /// Runs a `SELECT` that should return at most one row.
  Future<Map<String, Object?>?> getOptional(String sql, [List<Object?> args]);
}

/// Read/write access inside a single transaction.
abstract interface class CocoonTx implements CocoonRead {
  /// Runs one write statement (`INSERT`, `UPDATE`, `DELETE`, DDL).
  Future<void> execute(String sql, [List<Object?> args]);

  /// Runs one write statement once per parameter set; faster than repeated
  /// [execute] calls.
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets);
}

/// A Cocoon database handle: transactions plus the same read/write surface.
abstract interface class CocoonExecutor implements CocoonTx {
  /// Runs [body] inside one write transaction; an exception rolls everything
  /// back.
  Future<T> writeTransaction<T>(Future<T> Function(CocoonTx tx) body);

  /// Runs [body] inside one read transaction; the body sees reads only.
  Future<T> readTransaction<T>(Future<T> Function(CocoonRead tx) body);

  /// Closes the underlying database.
  Future<void> close();
}
