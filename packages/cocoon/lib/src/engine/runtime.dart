/// The internal engine interface behind every [Cocoon] facade.
///
/// A `Cocoon` object is the public handle; the engine work behind it is a
/// [CocoonRuntime]. Three implementations exist:
///
/// - `LocalCocoonRuntime` — today's engine (SQLite executor, hot-document
///   cache, watch hub, change log), used for `CocoonIsolate.caller` and for
///   the engine that runs inside a background-mode worker isolate.
/// - the isolate proxy (`CocoonIsolate.background`) — forwards every call to
///   a worker isolate that runs a [LocalCocoonRuntime].
/// - the auto router (`CocoonIsolate.auto`) — wraps one [LocalCocoonRuntime]
///   (engine home on the caller) and routes heavy reads/encodes to a helper
///   isolate.
///
/// Refs, queries and watches keep building their specs on the caller side
/// and hand them to the runtime; runtimes receive specs (adapters, paths,
/// filters), never closures that capture database state.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../path.dart';
import 'aggregate.dart';
import 'backup.dart';
import 'batch.dart';
import 'bulk_writer.dart';
import 'changes.dart';
import 'cocoon.dart';
import 'executor.dart';
import 'isolate/isolate_options.dart' show CocoonIsolateStats;
import 'query.dart';
import 'refs.dart';
import 'schema_sql.dart';
import 'transaction_guard.dart';
import 'watch.dart';

/// The per-transaction write surface a [CocoonTransaction] wraps.
///
/// Implemented by the engine's buffered local transaction (`WriteTx`) and by
/// the background mode's message-per-operation proxy. Reads see the
/// transaction's own writes; writes are staged until the commit succeeds.
@internal
abstract interface class CocoonWriteTx {
  /// Reads a document inside the transaction, seeing its own writes.
  Future<DocSnapshot<T>?> get<T extends Object>(DocRef<T> ref);

  /// Reads many documents inside the transaction, seeing its own writes.
  /// Answers in [refs] order, `null` where a document does not exist;
  /// duplicates allowed.
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  );

  /// Upserts [value] at [ref] (or, with [update], replaces an existing
  /// document and fails the transaction when it does not exist).
  Future<void> put<T extends Object>(
    DocRef<T> ref,
    T value, {
    bool update = false,
  });

  /// Queues a write with pre-built statement arguments (the encode-ahead
  /// path the isolate modes' write preparation produces). Only the local
  /// buffered implementation supports it; proxies throw.
  Future<void> putPrepared(
    DocRef<Object> ref,
    RegistryEntry entry,
    List<Object?> args, {
    bool update = false,
  });

  /// Adds a document with a fresh time-ordered id.
  Future<DocRef<T>> add<T extends Object>(CollectionRef<T> ref, T value);

  /// Deletes [ref] and its whole subtree.
  Future<void> delete(DocRef<Object> ref);

  /// The raw SQL transaction the buffered writes run in: the deferral DDL
  /// and existence checks reach it directly. Only the local implementation
  /// has one; the isolate plumbing's transaction proxies throw.
  CocoonTx get tx;
}

/// The engine behind a [Cocoon] facade: see the library comment for the
/// implementations. Every member is internal; the public API stays on
/// `Cocoon`.
@internal
abstract interface class CocoonRuntime {
  /// The facade this runtime serves; set once by the facade constructor,
  /// before any engine call. Refs and snapshots the engine builds point at
  /// the host.
  abstract Cocoon host;

  /// Builds the object `db.batch()` returns: the local buffered batch on a
  /// local runtime, the shipping variant behind a background proxy.
  WriteBatch createWriteBatch(Cocoon db);

  /// Builds the object `db.bulkWriter()` returns: the local chunking writer
  /// on a local runtime (with auto mode's helper-prepared encodes), the
  /// chunk-shipping variant behind a background proxy.
  BulkWriter createBulkWriter(Cocoon db, BulkWriterOptions options);

  /// The schema registry (adapters, tables, columns, indexes) this database
  /// was opened with.
  SchemaRegistry get registry;

  /// The watch hub commits are delivered to. A background-mode proxy has no
  /// caller-side hub (watches run in the worker) — accessing it throws.
  WatchHub get watchHub;

  /// Whether this runtime runs the engine in THIS isolate (a
  /// [CocoonIsolate.caller] database, an `auto` database, or the engine
  /// inside a background worker). The DevTools inspector attaches only to
  /// local runtimes.
  bool get isLocal;

  /// The isolate mode this database runs in, for diagnostics: the
  /// [CocoonIsolate] name.
  String get isolateModeName;

  /// The auto mode's inline/helper counters, or `null` outside `auto`.
  CocoonIsolateStats? get isolateStats;

  /// The raw executor; used by the DevTools inspector for its read-only SQL
  /// and by the bulk writer's deferred-index rebuild. Only a local runtime
  /// has one; accessing it on a proxy throws.
  CocoonExecutor get executor;

  // -- Local transaction internals (used by the buffered WriteTx) -----------

  /// Reads a document inside a transaction through [reader]: never the
  /// cache, nothing cached.
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonRead reader,
    DocRef<T> ref,
  );

  /// [getAll] inside a transaction: reads through [reader], seeing the
  /// transaction's own writes, answering in [refs] order with `null` for
  /// missing documents and duplicates allowed; caches nothing.
  Future<List<DocSnapshot<T>?>> getAllDocsInTx<T extends Object>(
    CocoonRead reader,
    List<DocRef<T>> refs,
  );

  /// Deletes the one row [entry] identifies by [paramValues] + [id],
  /// returning its `(table, path)` pair per removed row.
  Future<List<(String, String)>> deleteRow(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
    String id,
  );

  /// Deletes every row of [entry]'s table under the [paramValues] subtree
  /// prefix, returning one `(table, path)` pair per removed row.
  Future<List<(String, String)>> deleteScopePrefix(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
  );

  /// Whether every commit appends its change rows to the on-disk log.
  bool get keepsChanges;

  /// The param values of [entry]'s pattern that [path] fills, in
  /// [entry.paramNames] order.
  List<String> paramValuesInOrder(RegistryEntry entry, CollectionPath path);

  /// Commits a `WriteBatch`'s queued [ops] as one write transaction (the
  /// batch's engine path; existence checks and order preserved).
  Future<void> commitBatchOps(List<BatchOp> ops);

  // -- Reads ----------------------------------------------------------------

  /// Reads one document (cache-first on a local runtime).
  Future<DocSnapshot<T>?> getDoc<T extends Object>(DocRef<T> ref);

  /// Reads many documents by ref; answers in [refs] order, `null` for
  /// missing documents, duplicates allowed.
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  );

  /// Runs one page of a query.
  Future<QueryPage<T>> runQuery<T extends Object>(CocoonQuery<T> query);

  /// Runs one page, also returning each document's stored wire bytes — the
  /// signature query watches deduplicate pages by.
  Future<(QueryPage<T>, List<Uint8List>)> runQueryWithBytes<T extends Object>(
    CocoonQuery<T> query,
  );

  /// Counts the documents matching [query].
  Future<int> runCount<T extends Object>(CocoonQuery<T> query);

  /// Runs an aggregate query.
  Future<AggregateQuerySnapshot<T>> runAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  );

  /// Runs a group-by query.
  Future<List<AggregateGroup<T>>> runGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  );

  // -- Writes ---------------------------------------------------------------

  /// Upserts one document.
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value);

  /// Adds one document with a fresh id.
  Future<DocRef<T>> addDoc<T extends Object>(CollectionRef<T> ref, T value);

  /// Deletes one document and its whole subtree.
  Future<void> deleteDoc(DocRef<Object> ref);

  /// Runs [body] inside one write transaction with a staged cache, one
  /// commit event and the change-log bookkeeping. Internal entry (batch,
  /// bulk writer, `runTransaction`); transactions always run on the
  /// database's home isolate.
  Future<R> writeTx<R>(
    Future<R> Function(CocoonWriteTx wtx) body, {
    bool logChanges = true,
    TransactionScope? txScope,
  });

  /// Runs a user `runTransaction` body: same engine path as [writeTx] on a
  /// local runtime; on a background proxy, a message session that holds the
  /// worker's write lock until the body settles. The body runs on the
  /// caller isolate in every mode.
  Future<R> runTransactionBody<R>(
    Future<R> Function(CocoonWriteTx tx) body, {
    TransactionScope? txScope,
  });

  // -- Watches --------------------------------------------------------------

  /// The live stream behind `DocRef.watch`.
  Stream<DocSnapshot<T>?> watchDoc<T extends Object>(DocRef<T> ref);

  /// The live stream behind `CocoonQuery.watch`.
  Stream<QueryPage<T>> watchQuery<T extends Object>(CocoonQuery<T> query);

  /// The live stream behind `AggregateQuery.watch`.
  Stream<AggregateQuerySnapshot<T>> watchAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  );

  /// The live stream behind `AggregateGroupQuery.watch`.
  Stream<List<AggregateGroup<T>>> watchGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  );

  // -- Change log -----------------------------------------------------------

  /// The change-log rows newer than [seq], oldest first.
  Future<List<Change>> changesSince(int seq, {int limit});

  /// The oldest change seq still readable from the log.
  Future<int> earliestChangeSeq();

  /// The highest seq ever assigned to a change.
  Future<int> lastChangeSeq();

  /// Deletes every change row with `seq <= upToSeq`.
  Future<int> pruneChanges({required int upToSeq});

  // -- Files, lifecycle, diagnostics -----------------------------------------

  /// Copies the whole database to [path] as one consistent backup
  /// (`VACUUM INTO`); the caller-side facade checked the file rules.
  Future<BackupInfo> backupTo(String path, {required bool overwrite});

  /// Closes the engine. Local: completes watch streams and fails bulk
  /// waiters. Background: stops the worker; pending calls fail with a
  /// [StateError].
  Future<void> close();

  /// The hot-document cache length (a message in background mode; resolves
  /// to 0 when the worker is gone or the handle is closed).
  Future<int> get debugCacheLength;

  /// The registered watch count (a message in background mode; resolves to
  /// 0 when the worker is gone or the handle is closed).
  Future<int> get debugWatcherCount;

  /// The missing indexes debug scanAndWarn queries have hit (local engine
  /// state; the reports are filled on the engine's home isolate).
  List<MissingIndexReport> get missingIndexes;

  // -- Bulk-writer deferred indexes (local engine accounting) ----------------

  /// Registers a live bulk writer.
  void noteBulkWriterActive();

  /// Unregisters a finished bulk writer.
  void noteBulkWriterClosed();

  /// Marks [indexNames] as dropped by a bulk writer.
  void noteIndexesDeferred(Iterable<String> indexNames);

  /// Marks [indexNames] as rebuilt, releasing the queries that waited.
  void noteIndexesRestored(Iterable<String> indexNames);

  /// Resolves when [servingIndex] is no longer deferred by a bulk writer.
  Future<void> waitForBulkIndexes(String? servingIndex);
}
