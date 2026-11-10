import '../id.dart';
import 'cache.dart';
import 'changes.dart';
import 'cocoon.dart';
import 'executor.dart';
import 'naming.dart';
import 'refs.dart';
import 'schema_sql.dart';

/// How many buffered rows one write transaction accumulates before it
/// flushes them to SQLite as batched statements. Bounds the buffer's memory
/// during very large transactions without adding round trips in the common
/// (small transaction) case.
const writeFlushThreshold = 2000;

/// One buffered document write: an upsert (`set`) or a replace-if-exists
/// (`update`), with its statement arguments bound.
final class BufferedWrite {
  BufferedWrite(this.entry, this.isUpdate, this.path, this.args);

  /// The collection the document belongs to (its table and statements).
  final RegistryEntry entry;

  /// Whether this write must find an existing row ([isUpdate] batch writes
  /// fail the transaction when the document is missing).
  final bool isUpdate;

  /// The full document path.
  final String path;

  /// The bound arguments in [RegistryEntry.upsertSql] /
  /// [RegistryEntry.updateSql] order.
  final List<Object?> args;
}

/// The engine's per-write-transaction state: the SQL transaction handle, the
/// staged cache updates, and the buffered document writes.
///
/// Document writes queue here instead of running one statement per document.
/// The queue flushes to SQLite as batched statements — consecutive writes of
/// the same kind on the same table become one `executeBatch`, one isolate
/// round trip instead of one per document — at these points:
///
/// - before any read inside the same transaction (read-your-writes);
/// - before a delete, so operations land in call order;
/// - every [writeFlushThreshold] queued rows;
/// - at commit, before the executor's COMMIT.
///
/// A failed flush (a batch `update` whose document is missing, or any SQL
/// error) throws out of the transaction, which rolls everything back; the
/// [CacheStage] is simply discarded, so neither the database nor the
/// hot-document cache reflects any of it.
final class WriteTx {
  /// Builds the transaction state over [tx]; [db] supplies the registry, the
  /// change-log policy and the delete helpers. With `logChanges: false` the
  /// transaction writes no change-log rows (a bulk-writer chunk opt-out);
  /// watch notifications and cache updates are unaffected.
  WriteTx(this._db, this.tx, this.stage, {bool logChanges = true})
    : _logChanges = logChanges;

  final Cocoon _db;

  /// The SQL transaction every statement of this write runs in.
  final CocoonTx tx;

  /// The cache stage this transaction's updates accumulate on, applied only
  /// after the commit succeeds.
  final CacheStage stage;

  /// Whether the flush appends change-log rows.
  final bool _logChanges;

  final List<BufferedWrite> _writes = [];
  final List<(String table, String path, ChangeOp op)> _changes = [];
  final Set<String> _writtenPaths = {};

  /// Whether document writes or change rows are still queued.
  bool get hasPending => _writes.isNotEmpty || _changes.isNotEmpty;

  /// Reads a document inside the transaction, seeing its own writes: the
  /// buffer flushes first, so the read reaches SQLite after every queued
  /// write of this transaction.
  Future<DocSnapshot<T>?> get<T extends Object>(DocRef<T> ref) async {
    await flush();
    return _db.readDocInTx<T>(tx, ref);
  }

  /// Upserts [value] at [ref] (or, with [update], replaces an existing
  /// document and fails the transaction when it does not exist).
  Future<void> put<T extends Object>(
    DocRef<T> ref,
    T value, {
    bool update = false,
  }) {
    final entry = _db.registry.entryFor(ref.adapter);
    final bytes = entry.adapter.encode(value);
    // One bound argument list serves both the upsert and the update
    // statement: `data, f_columns..., params..., id` (see
    // [RegistryEntry.upsertSql]).
    final args = <Object?>[
      bytes,
      for (final column in entry.fieldColumns) column.sqlOf(value),
      ..._db.paramValuesInOrder(entry, ref.path.collection),
      ref.path.id,
    ];
    _writes.add(BufferedWrite(entry, update, ref.path.path, args));
    // Only an upsert makes the path exist by construction; a buffered
    // `update` must still find an existing row at flush time (it fails the
    // transaction otherwise), so it must not claim existence here.
    if (!update) {
      _writtenPaths.add(ref.path.path);
    }
    _queueChange(entry.table, ref.path.path, ChangeOp.set);
    // Cache the encoded bytes, not the value: the first cache read decodes
    // them once, so what it returns is exactly what the stored bytes decode
    // to (for example, DateTime fields come back in UTC) without paying a
    // decode per write.
    stage.put(ref.path.path, EncodedDoc(bytes));
    if (_writes.length >= writeFlushThreshold) {
      return flush();
    }
    return Future.value();
  }

  /// Adds a document with a fresh time-ordered id.
  Future<DocRef<T>> add<T extends Object>(CollectionRef<T> ref, T value) {
    final docRef = ref.doc(newDocId());
    return put(docRef, value).then((_) => docRef);
  }

  /// Deletes [ref] and its whole subtree. The buffer flushes first, so
  /// queued writes land before the delete, in call order.
  ///
  /// The document's own row goes by its scope key; every child collection
  /// table loses the rows whose leading param columns match the parent's —
  /// a descendant table's first N params are exactly the deleted
  /// collection's params (the patterns share their path prefix). All in one
  /// transaction.
  Future<void> delete(DocRef<Object> ref) async {
    await flush();
    final entry = _db.registry.entryFor(ref.adapter);
    final key = entry.scopeKeyOf(ref.path.path);
    if (key == null) {
      throw ArgumentError.value(
        ref.path.path,
        'ref',
        'Not a document path of collection ${entry.adapter.pattern}',
      );
    }
    final deleted = <(String, String)>[
      ...await _db.deleteRow(tx, entry, key.paramValues, key.id),
    ];
    // A child table's leading param columns line up with the deleted
    // collection's params followed by the deleted document's own id (the
    // child pattern introduces that param right after the parent's
    // collection id): deleting an account filters its txns by
    // p_account_id = the account's id, and the splits two levels down by
    // the same prefix.
    final childKey = [...key.paramValues, key.id];
    for (final candidate in _db.registry.entries) {
      if (SchemaRegistry.descendsFrom(
        candidate.adapter.pattern,
        ref.adapter.pattern,
      )) {
        deleted.addAll(await _db.deleteScopePrefix(tx, candidate, childKey));
      }
    }
    for (final (table, path) in deleted) {
      _queueChange(table, path, ChangeOp.delete);
    }
    _writtenPaths.remove(ref.path.path);
    stage.evictSubtree(ref.path.path);
  }

  /// Writes every queued statement, in order: consecutive writes of the same
  /// kind on the same table as one `executeBatch`, then all pending
  /// change-log rows as one `executeBatch`.
  Future<void> flush() async {
    if (!hasPending) {
      return;
    }
    var i = 0;
    while (i < _writes.length) {
      final first = _writes[i];
      var j = i + 1;
      while (j < _writes.length &&
          identical(_writes[j].entry, first.entry) &&
          _writes[j].isUpdate == first.isUpdate) {
        j++;
      }
      final run = _writes.sublist(i, j);
      if (first.isUpdate) {
        await _flushUpdateRun(first.entry, run);
      } else {
        await tx.executeBatch(first.entry.upsertSql, [
          for (final write in run) write.args,
        ]);
      }
      i = j;
    }
    _writes.clear();
    final changes = _changes.toList();
    _changes.clear();
    if (!_db.keepsChanges || !_logChanges) {
      return;
    }
    final at = DateTime.now().toUtc().microsecondsSinceEpoch;
    await tx.executeBatch(
      'INSERT INTO $changesTableName (tbl, path, op, at) VALUES (?, ?, ?, ?)',
      [
        for (final (table, path, op) in changes) [table, path, op.name, at],
      ],
    );
  }

  /// A batch `update` must find an existing row: paths this buffer has
  /// written (and not deleted since) exist by construction; every other
  /// write's scope key in the run is checked against the transaction's
  /// database state, and a missing one fails the transaction before any row
  /// of the run is written.
  Future<void> _flushUpdateRun(
    RegistryEntry entry,
    List<BufferedWrite> run,
  ) async {
    final toCheck = [
      for (final write in run)
        if (!_writtenPaths.contains(write.path)) write,
    ];
    final keyColumns = entry.keyColumns;
    // Each VALUES tuple binds `paramCount + 1` values; chunk to stay inside
    // a comfortable placeholder budget.
    final keyCount = keyColumns.length;
    final chunkSize = keyCount >= _existenceVarBudget
        ? 1
        : _existenceVarBudget ~/ keyCount;
    for (var start = 0; start < toCheck.length; start += chunkSize) {
      final chunk = toCheck.sublist(
        start,
        start + chunkSize > toCheck.length ? toCheck.length : start + chunkSize,
      );
      final tuple = '(${List.filled(keyCount, '?').join(', ')})';
      final found = {
        for (final row in await tx.getAll(
          'SELECT ${keyColumns.join(', ')} FROM ${entry.table} '
          'WHERE (${keyColumns.join(', ')}) IN '
          '(VALUES ${List.filled(chunk.length, tuple).join(', ')})',
          [
            for (final write in chunk)
              ...write.args.sublist(write.args.length - keyCount),
          ],
        ))
          // Scope-key tag: the key values joined with '/', which no doc id
          // or param can contain — collision-free within one table.
          [for (final name in keyColumns) row[name]! as String].join('/'),
      };
      for (final write in chunk) {
        final tag = write.args.sublist(write.args.length - keyCount).join('/');
        if (!found.contains(tag)) {
          throw ArgumentError.value(
            write.path,
            'ref',
            'batch update: document does not exist',
          );
        }
      }
    }
    await tx.executeBatch(entry.updateSql, [
      for (final write in run) write.args,
    ]);
  }

  /// Records [op] on (table, path) for the post-commit notification and
  /// queues its change-log row (written at flush time, when the log is on).
  void _queueChange(String table, String path, ChangeOp op) {
    stage.touched(table, path, op);
    _changes.add((table, path, op));
  }

  /// Bound placeholder budget per existence-check `SELECT`; SQLite's
  /// variable limit is far higher, this only bounds the statement size.
  static const int _existenceVarBudget = 500;
}
