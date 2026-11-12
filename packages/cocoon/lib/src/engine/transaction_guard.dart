/// The transaction guard: an immediate, readable error when a database call
/// that must go through the transaction object is made on the database
/// itself inside a `runTransaction` body.
///
/// `Cocoon.runTransaction` runs its body in a [Zone] carrying a
/// [TransactionScope] (`{db, active}`). Every public read/write entry point
/// costs one zone lookup ([currentScopeFor]) and throws a
/// [TransactionMisuseError] when the SAME database's transaction is still
/// open — a write would wait forever for the write lock the body already
/// holds, and a read would silently return committed data without the
/// transaction's own writes. Calls on a different open `Cocoon` (another
/// database file) are allowed. The check is always on, debug and release:
/// it prevents a hang, not a bug that only shows in development.
///
/// The scope deactivates the moment the SQL transaction ends (commit OR
/// rollback), before any post-commit engine work, so futures and timers the
/// body created that run later never trip the guard.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import 'cocoon.dart';

/// Thrown when a read or write that must go through the transaction object
/// is made on the [Cocoon] database itself inside a `runTransaction` body.
///
/// Inside a transaction body every database access goes through the
/// `tx` object ([CocoonTransaction]): a call on the database would either
/// wait for the write lock the transaction already holds (writes, batch
/// commits, bulk writers, nested transactions) or read a snapshot that can
/// never see the transaction's own uncommitted writes (reads and queries).
/// The error carries the rejected [operation] (for example `DocRef.set`)
/// and its [message] ends with a one-line `Fix:` hint. The body's
/// transaction rolls back, exactly like any other exception.
///
/// ```dart
/// await db.runTransaction((tx) async {
///   await ref.set(value); // throws TransactionMisuseError (operation: DocRef.set)
///   await tx.set(ref, value); // right: through the transaction
/// });
/// ```
final class TransactionMisuseError extends StateError {
  TransactionMisuseError._(this.operation, String message) : super(message);

  /// Builds the write variant: the call would wait forever for the
  /// transaction's own write lock.
  @internal
  factory TransactionMisuseError.write(String operation) =>
      TransactionMisuseError._(
        operation,
        '$operation was called on the database inside runTransaction; it '
        "would wait forever for this transaction's own write lock.\n"
        'Fix: use tx.set / tx.update / tx.delete inside the transaction, '
        'or call it after runTransaction returns.',
      );

  /// Builds the read variant: the call reads committed data only and can
  /// never see the transaction's own writes.
  @internal
  factory TransactionMisuseError.read(String operation) =>
      TransactionMisuseError._(
        operation,
        '$operation was called on the database inside runTransaction; it '
        'reads committed data only and cannot see this transaction\'s '
        'writes.\n'
        'Fix: use tx.get / tx.getAll inside the transaction, or run the '
        'query before runTransaction and pass the ids in.',
      );

  /// Builds the nested-transaction variant.
  @internal
  factory TransactionMisuseError.nested() => TransactionMisuseError._(
    'Cocoon.runTransaction',
    'Nested runTransaction calls are not supported: the body already holds '
        "the database's single write lock, so a nested transaction would "
        'wait forever for it.\n'
        'Fix: use the outer tx (tx.get / tx.set / tx.update / tx.delete) '
        'for this work, or run the nested runTransaction after the outer '
        'one returns.',
  );

  /// The rejected operation, e.g. `DocRef.set` or `Cocoon.runTransaction`.
  final String operation;

  @override
  String toString() => 'TransactionMisuseError: $message';
}

/// The guard state one `runTransaction` body runs in: the guarded [db] and
/// whether its SQL transaction is still open. Carried to the body (and to
/// every future or timer it creates) through a [Zone] value; the same
/// object is handed to [Cocoon.writeTx] so it can end the guard the moment
/// the SQL transaction ends.
final class TransactionScope {
  TransactionScope(this.db);

  /// The database whose transaction this scope guards.
  final Cocoon db;

  /// Whether the SQL transaction is still open. Commit and rollback both
  /// clear it, before anything that runs after the transaction.
  bool active = true;

  /// Ends the guard: everything running later sees an inactive scope.
  void deactivate() {
    active = false;
  }
}

/// The [Zone] key the transaction scope travels under.
final Object _transactionScopeKey = Object();

/// The guard scope of a `runTransaction` body running in the current zone,
/// when it belongs to THIS [db] and its SQL transaction is still open —
/// `null` outside any transaction, after the transaction ended, and for a
/// different open [Cocoon] (another database file, which is allowed).
@internal
TransactionScope? currentScopeFor(Cocoon db) {
  final scope = Zone.current[_transactionScopeKey];
  if (scope is TransactionScope && scope.active && identical(scope.db, db)) {
    return scope;
  }
  return null;
}

/// Throws a [TransactionMisuseError] when THIS [db] is inside its own
/// `runTransaction` body in the current zone: [read] picks the message
/// variant. The entry points a user calls check this; internal engine
/// paths (WriteTx, batch and bulk-writer internals, watches, migrations,
/// retention, the inspector) never do.
@internal
void checkNotInTransaction(Cocoon db, String operation, {required bool read}) {
  if (currentScopeFor(db) != null) {
    throw read
        ? TransactionMisuseError.read(operation)
        : TransactionMisuseError.write(operation);
  }
}

/// Runs [body] with [scope] installed as the current zone's guard scope:
/// every public entry point the body (or a future or timer it created)
/// calls on [TransactionScope.db] is checked against it.
@internal
R runInTransactionScope<R>(TransactionScope scope, R Function() body) =>
    runZoned(body, zoneValues: {_transactionScopeKey: scope});
