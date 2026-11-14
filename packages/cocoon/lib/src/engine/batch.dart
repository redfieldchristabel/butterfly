import 'package:meta/meta.dart';

import 'cocoon.dart';
import 'refs.dart';
import 'transaction_guard.dart';
import 'write_buffer.dart' show writeFlushThreshold;

/// One queued [WriteBatch] operation.
enum BatchOpKind {
  /// Upsert the document (`WriteBatch.set`).
  set,

  /// Replace an existing document (`WriteBatch.update`).
  update,

  /// Delete the document and its subtree (`WriteBatch.delete`).
  delete,
}

/// A queued operation of a [WriteBatch]: its [kind], the document [ref] and,
/// for writes, the [value].
final class BatchOp {
  /// Builds a queued operation; the engine's batch implementations do.
  @internal
  const BatchOp(this.kind, this.ref, this.value);

  /// The kind of write.
  final BatchOpKind kind;

  /// The document the operation targets.
  final DocRef<Object> ref;

  /// The value to store, for [BatchOpKind.set] and [BatchOpKind.update].
  final Object? value;
}

/// A Firestore-style batch of document writes committed as one transaction.
///
/// `set`, `update` and `delete` only validate and queue — they are
/// synchronous and touch nothing on disk. `commit()` then runs every queued
/// operation, in call order, inside ONE write transaction:
///
/// - consecutive same-SQL operations group into one batched statement, so a
///   bulk write costs two round trips per ~[writeFlushThreshold] documents
///   instead of two per document — this is Cocoon's bulk-write path;
/// - every touched document appends its change-log row in one batch;
/// - the hot-document cache is updated once, after the commit, and the
///   watches receive exactly one commit event.
///
/// Semantics per operation are the standalone ones: `set` upserts, `update`
/// replaces an existing document (the whole batch fails when the document is
/// missing — checked against the transaction's state, so a `set` earlier in
/// the batch satisfies a later `update` of the same document, and a `delete`
/// in between fails it), and `delete` removes the document and its whole
/// subtree. Any failure rolls everything back: no rows, no cache updates, no
/// watch event.
///
/// ```dart
/// final batch = db.batch();
/// batch.set(a1, account);
/// batch.delete(txRef);
/// await batch.commit();
/// ```
///
/// A batch is single-use: calling [commit] twice throws a [StateError].
abstract interface class WriteBatch {
  /// Queues an upsert of [value] at [ref].
  ///
  /// Throws an [ArgumentError] when [ref]'s adapter was not registered when
  /// the database was opened (the same validation a standalone `set` runs,
  /// but at queue time).
  void set<T extends Object>(DocRef<T> ref, T value);

  /// Queues a replace of the existing document at [ref] with [value].
  ///
  /// The whole batch fails when the document does not exist at commit time.
  /// Throws an [ArgumentError] at queue time for an unregistered adapter.
  void update<T extends Object>(DocRef<T> ref, T value);

  /// Queues a delete of [ref] and its whole subtree.
  ///
  /// Throws an [ArgumentError] at queue time for an unregistered adapter.
  void delete(DocRef<Object> ref);

  /// Every queued operation, in call order. Reading it never commits.
  List<BatchOp> get ops;

  /// Runs every queued operation, in call order, inside one write
  /// transaction. Committing an empty batch is a no-op: no transaction, no
  /// change rows, no watch event.
  ///
  /// Throws a [StateError] when the batch was already committed, and a
  /// [TransactionMisuseError] when called inside a [Cocoon.runTransaction]
  /// body of the same database — the commit would wait forever for the
  /// transaction's own write lock. Queue through the transaction instead,
  /// or commit the batch after `runTransaction` returns.
  Future<void> commit();
}

/// The [WriteBatch] over an engine in this isolate: ops queue here and
/// commit through the database's own write transaction. This is also the
/// batch auto mode uses (its commit routes through the auto runtime, which
/// prepares big batches' encodes in the helper).
@internal
final class LocalWriteBatch implements WriteBatch {
  /// Builds a batch over [db]; applications get one from `db.batch()`.
  @internal
  LocalWriteBatch(this._db);

  final Cocoon _db;
  final List<BatchOp> _ops = [];
  var _committed = false;

  @override
  void set<T extends Object>(DocRef<T> ref, T value) {
    _queue(ref, value, BatchOpKind.set);
  }

  @override
  void update<T extends Object>(DocRef<T> ref, T value) {
    _queue(ref, value, BatchOpKind.update);
  }

  @override
  void delete(DocRef<Object> ref) {
    _checkUsable();
    _db.registry.entryFor(ref.adapter);
    _ops.add(BatchOp(BatchOpKind.delete, ref, null));
  }

  @override
  List<BatchOp> get ops => List.unmodifiable(_ops);

  @override
  Future<void> commit() async {
    _checkUsable();
    checkNotInTransaction(_db, 'WriteBatch.commit', read: false);
    _committed = true;
    if (_ops.isEmpty) {
      return;
    }
    await _db.runtime.commitBatchOps(_ops);
  }

  void _queue<T extends Object>(DocRef<T> ref, T value, BatchOpKind kind) {
    _checkUsable();
    _db.registry.entryFor(ref.adapter);
    _ops.add(BatchOp(kind, ref, value));
  }

  void _checkUsable() {
    if (_committed) {
      throw StateError('This WriteBatch was already committed');
    }
  }
}
