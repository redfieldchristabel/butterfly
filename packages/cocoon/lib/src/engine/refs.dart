import 'package:meta/meta.dart';

import '../path.dart';
import 'adapter.dart';
import 'aggregate.dart';
import 'cocoon.dart';
import 'query.dart';
import 'transaction_guard.dart';
import 'write_buffer.dart';

/// A document as read from the database: its [ref], its [id] and its decoded
/// [data].
final class DocSnapshot<T extends Object> {
  @internal
  const DocSnapshot(this.ref, this.data);

  /// The reference this snapshot was read from.
  final DocRef<T> ref;

  /// The document id, unique within its collection.
  String get id => ref.id;

  /// The decoded model value.
  final T data;

  @override
  String toString() => 'DocSnapshot($id)';
}

/// A typed reference to one document: `db.collection(accounts).doc('a1')`.
///
/// Reads and writes through the reference hit the collection's adapter:
/// [get] decodes the stored wire bytes, [set] encodes and upserts, [delete]
/// removes the document and its whole subtree.
final class DocRef<T extends Object> {
  @internal
  const DocRef(this._db, this._adapter, this.path);

  final Cocoon _db;
  final CollectionAdapter<T> _adapter;

  /// The full document path, e.g. `accounts/a1/txns/t9`.
  final DocPath path;

  /// The document id, unique within its collection.
  String get id => path.id;

  /// The collection adapter the engine stores and reads this document with.
  @internal
  CollectionAdapter<T> get adapter => _adapter;

  /// A subcollection under this document, backed by [adapter].
  ///
  /// Throws an [ArgumentError] when [adapter]'s pattern is not a child of
  /// this document's collection pattern.
  CollectionRef<W> collection<W extends Object>(CollectionAdapter<W> adapter) {
    final parent = _adapter.pattern;
    if (adapter.pattern.parent != parent) {
      throw ArgumentError(
        'Collection ${adapter.pattern} is not a subcollection of $parent',
      );
    }
    return CollectionRef<W>(
      _db,
      adapter,
      path.subcollection(adapter.pattern.collectionId),
    );
  }

  /// Reads the document, or `null` when it does not exist. Reads are served
  /// from the bounded hot-document cache when possible.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.get` — calling this on
  /// the database throws a [TransactionMisuseError]: a read here can never
  /// see the transaction's own uncommitted writes.
  Future<DocSnapshot<T>?> get() {
    checkNotInTransaction(_db, 'DocRef.get', read: true);
    return _db.getDoc(this);
  }

  /// Upserts the document: inserts it, or replaces the stored value when a
  /// document with this id already exists.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.set` — calling this on
  /// the database throws a [TransactionMisuseError]: the write would wait
  /// forever for the transaction's own write lock.
  Future<void> set(T value) {
    checkNotInTransaction(_db, 'DocRef.set', read: false);
    return _db.putDoc(this, value);
  }

  /// Deletes the document and its whole subtree (every document in
  /// subcollections below it).
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.delete` — calling this
  /// on the database throws a [TransactionMisuseError]: the write would
  /// wait forever for the transaction's own write lock.
  Future<void> delete() {
    checkNotInTransaction(_db, 'DocRef.delete', read: false);
    return _db.deleteDoc(this);
  }

  /// Watches the document.
  ///
  /// The stream starts work on the first listen and stops when the last
  /// listener cancels (the watcher unregisters; re-listening restarts it).
  /// It emits the current value on listen — `null` when the document does
  /// not exist — then re-reads only when a committed transaction touched
  /// this exact path. Emissions whose canonical wire bytes equal the
  /// previous emission are skipped: byte equality is value equality, so an
  /// identical rewrite never emits and models need no `==`. A delete emits
  /// `null`. Closing the database completes the stream.
  Stream<DocSnapshot<T>?> watch() => _db.watchDoc<T>(this);

  @override
  bool operator ==(Object other) => other is DocRef && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => path.path;
}

/// A typed reference to one concrete collection, scoped to its parent when
/// it is a subcollection: `accounts` or `accounts/a1/txns`.
///
/// Queries on a scoped collection automatically filter by the parent's path
/// params; a document of another parent can never leak in.
final class CollectionRef<T extends Object> {
  @internal
  const CollectionRef(this._db, this._adapter, this.path);

  final Cocoon _db;
  final CollectionAdapter<T> _adapter;

  /// The concrete collection path, e.g. `accounts/a1/txns`.
  final CollectionPath path;

  /// The collection adapter the engine stores and reads documents with.
  @internal
  CollectionAdapter<T> get adapter => _adapter;

  /// A reference to the document [id] in this collection.
  DocRef<T> doc(String id) => DocRef<T>(_db, _adapter, path.doc(id));

  /// A query over every document of this collection, in default (id) order.
  CocoonQuery<T> query() => CocoonQuery<T>(_db, _adapter, path);

  /// Reads every document of the collection, in default (id) order.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.getAll` — calling this
  /// throws a [TransactionMisuseError]: the read can never see the
  /// transaction's own uncommitted writes.
  Future<QueryPage<T>> get() {
    checkNotInTransaction(_db, 'CollectionRef.get', read: true);
    return query().get();
  }

  /// Counts every document of the collection, under the index rule.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.getAll` (or run the
  /// count before the transaction) — calling this throws a
  /// [TransactionMisuseError]: the count can never see the transaction's
  /// own uncommitted writes.
  Future<int> count() {
    checkNotInTransaction(_db, 'CollectionRef.count', read: true);
    return query().count();
  }

  /// Adds [value] with a fresh time-ordered id and returns the new
  /// document's reference.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.add` — calling this
  /// throws a [TransactionMisuseError]: the write would wait forever for
  /// the transaction's own write lock.
  Future<DocRef<T>> add(T value) {
    checkNotInTransaction(_db, 'CollectionRef.add', read: false);
    return _db.addDoc(this, value);
  }

  /// Reads many documents of this collection by id in one trip — sugar for
  /// `db.getAll([for (final id in ids) doc(id)])` with this collection's
  /// rules: results come back in [ids] order, `null` where a document does
  /// not exist, duplicates allowed, cache-first with one statement per chunk
  /// of scope keys. See [Cocoon.getAll].
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.getAll` — calling this
  /// throws a [TransactionMisuseError]: the read can never see the
  /// transaction's own uncommitted writes.
  Future<List<DocSnapshot<T>?>> getAll(Iterable<String> ids) {
    checkNotInTransaction(_db, 'CollectionRef.getAll', read: true);
    return _db.getAll<T>([for (final id in ids) doc(id)]);
  }

  /// Starts a query filtered by [filter].
  CocoonQuery<T> where(QueryFilter filter) => query().where(filter);

  /// Starts a query sorted by [column]; the identity tiebreaker (unbound
  /// path params, then the document id) follows the last sort key.
  CocoonQuery<T> orderBy(
    FieldColumn<T, Object?> column, {
    bool descending = false,
  }) => query().orderBy(column, descending: descending);

  /// Computes aggregates over this collection's documents — sugar for
  /// `query().aggregate(specs)`; see [CocoonQuery.aggregate].
  AggregateQuery<T> aggregate(List<AggregateFunction<T>> specs) =>
      query().aggregate(specs);

  /// Starts a group-by query over this collection — sugar for
  /// `query().groupBy(keys)`; see [CocoonQuery.groupBy].
  GroupByQuery<T> groupBy(List<GroupKeySpec<T, Object?>> keys) =>
      query().groupBy(keys);

  @override
  bool operator ==(Object other) =>
      other is CollectionRef && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => path.path;
}

/// A query root over every document of [T]'s pattern, whatever parent it
/// belongs to (the collection-group query). No parent scope is applied, so
/// parent params can be filtered explicitly:
/// `db.collectionGroup(txns).where(txnAccountId.isEqualTo('a1'))`.
final class CollectionGroupRef<T extends Object> {
  @internal
  const CollectionGroupRef(this._db, this._adapter);

  final Cocoon _db;
  final CollectionAdapter<T> _adapter;

  /// A query over every document of the collection group, in default (id)
  /// order.
  CocoonQuery<T> query() => CocoonQuery<T>(_db, _adapter, null);

  /// Starts a collection-group query filtered by [filter].
  CocoonQuery<T> where(QueryFilter filter) => query().where(filter);

  /// Starts a collection-group query sorted by [column].
  CocoonQuery<T> orderBy(
    FieldColumn<T, Object?> column, {
    bool descending = false,
  }) => query().orderBy(column, descending: descending);

  /// Computes aggregates over the whole collection group — sugar for
  /// `query().aggregate(specs)`; see [CocoonQuery.aggregate].
  AggregateQuery<T> aggregate(List<AggregateFunction<T>> specs) =>
      query().aggregate(specs);

  /// Starts a group-by query over the collection group — sugar for
  /// `query().groupBy(keys)`; see [CocoonQuery.groupBy]. Group by a parent
  /// with [paramKey] to aggregate one group per parent.
  GroupByQuery<T> groupBy(List<GroupKeySpec<T, Object?>> keys) =>
      query().groupBy(keys);

  @override
  String toString() => 'collectionGroup(${_adapter.pattern})';
}

/// A unit of work: reads see the transaction's own writes, and either every
/// write commits or none does.
///
/// Cache updates are staged and applied only after the transaction commits,
/// so a rollback leaves both the database and the hot-document cache
/// untouched. Document writes buffer and flush as batched statements before
/// the commit (and before any read or delete in the same transaction), so
/// large transactions cost batched round trips instead of one per document.
///
/// ```dart
/// await db.runTransaction((tx) async {
///   final snap = await tx.get(txRef);
///   await tx.set(txRef, snap!.data.copyWith(posted: true));
/// });
/// ```
final class CocoonTransaction {
  @internal
  const CocoonTransaction(this._wtx);

  final WriteTx _wtx;

  /// Reads a document inside the transaction, seeing its own writes.
  Future<DocSnapshot<T>?> get<T extends Object>(DocRef<T> ref) =>
      _wtx.get<T>(ref);

  /// Reads many documents inside the transaction, seeing its own writes —
  /// the transaction's counterpart of [Cocoon.getAll]. Results come back in
  /// [refs] order, `null` where a document does not exist; duplicates are
  /// allowed. Reads never touch the hot-document cache, and the fetched
  /// documents are cached only after the transaction commits.
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  ) => _wtx.getAll<T>(refs);

  /// Upserts a document inside the transaction.
  Future<void> set<T extends Object>(DocRef<T> ref, T value) =>
      _wtx.put(ref, value);

  /// Adds a document with a fresh time-ordered id inside the transaction.
  Future<DocRef<T>> add<T extends Object>(CollectionRef<T> ref, T value) =>
      _wtx.add<T>(ref, value);

  /// Deletes a document and its whole subtree inside the transaction.
  Future<void> delete(DocRef<Object> ref) => _wtx.delete(ref);
}
