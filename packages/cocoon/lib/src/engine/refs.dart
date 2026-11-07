import 'package:meta/meta.dart';

import '../path.dart';
import 'adapter.dart';
import 'cache.dart';
import 'cocoon.dart';
import 'executor.dart';
import 'query.dart';

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
  Future<DocSnapshot<T>?> get() => _db.getDoc(this);

  /// Upserts the document: inserts it, or replaces the stored value when a
  /// document with this id already exists.
  Future<void> set(T value) => _db.putDoc(this, value);

  /// Deletes the document and its whole subtree (every document in
  /// subcollections below it).
  Future<void> delete() => _db.deleteDoc(this);

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
  Future<QueryPage<T>> get() => query().get();

  /// Counts every document of the collection, under the index rule.
  Future<int> count() => query().count();

  /// Adds [value] with a fresh time-ordered id and returns the new
  /// document's reference.
  Future<DocRef<T>> add(T value) => _db.addDoc(this, value);

  /// Starts a query filtered by [filter].
  CocoonQuery<T> where(QueryFilter filter) => query().where(filter);

  /// Starts a query sorted by [column]; the document id is always appended
  /// as the final tiebreaker.
  CocoonQuery<T> orderBy(
    FieldColumn<T, Object?> column, {
    bool descending = false,
  }) => query().orderBy(column, descending: descending);

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

  @override
  String toString() => 'collectionGroup(${_adapter.pattern})';
}

/// A unit of work: reads see the transaction's own writes, and either every
/// write commits or none does.
///
/// Cache updates are staged and applied only after the transaction commits,
/// so a rollback leaves both the database and the hot-document cache
/// untouched.
///
/// ```dart
/// await db.runTransaction((tx) async {
///   final snap = await tx.get(txRef);
///   await tx.set(txRef, snap!.data.copyWith(posted: true));
/// });
/// ```
final class CocoonTransaction {
  @internal
  const CocoonTransaction(this._db, this._tx, this._stage);

  final Cocoon _db;
  final CocoonTx _tx;
  final CacheStage _stage;

  /// Reads a document inside the transaction, seeing its own writes.
  Future<DocSnapshot<T>?> get<T extends Object>(DocRef<T> ref) =>
      _db.readDocInTx<T>(_tx, ref);

  /// Upserts a document inside the transaction.
  Future<void> set<T extends Object>(DocRef<T> ref, T value) =>
      _db.putDocInTx(_tx, _stage, ref, value);

  /// Adds a document with a fresh time-ordered id inside the transaction.
  Future<DocRef<T>> add<T extends Object>(CollectionRef<T> ref, T value) =>
      _db.addDocInTx<T>(_tx, _stage, ref, value);

  /// Deletes a document and its whole subtree inside the transaction.
  Future<void> delete(DocRef<Object> ref) =>
      _db.deleteDocInTx(_tx, _stage, ref);
}
