import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sqlite_async/sqlite_async.dart'
    show SqliteDatabase, SqliteOptions, SqliteSynchronous;
import '../cursor.dart';
import '../inspector/service.dart';
import '../migration.dart';
import '../path.dart';
import '../schema.dart';
import 'adapter.dart';
import 'batch.dart';
import 'bulk_writer.dart';
import 'cache.dart';
import 'changes.dart';
import 'executor.dart';
import 'migrate.dart';
import 'naming.dart';
import 'query.dart';
import 'refs.dart';
import 'schema_sql.dart';
import 'sqlite_executor.dart';
import 'watch.dart';
import 'write_buffer.dart';

/// How eagerly commits hit the disk.
enum Durability {
  /// `PRAGMA synchronous = FULL`: every commit waits for the OS to flush.
  /// Slowest, nothing is lost on power loss. The default.
  full,

  /// `PRAGMA synchronous = NORMAL`: safe with WAL (commits are durable
  /// against application crashes, may lose the last transactions on power
  /// loss), and much faster for write-heavy workloads.
  normal,
}

/// Options for opening a [Cocoon] database.
final class CocoonOptions {
  /// Builds options; the defaults are safe for money-style data.
  const CocoonOptions({
    this.durability = Durability.full,
    this.cacheSize = defaultCacheSize,
    this.keepChanges = true,
    this.pageCacheMiB = defaultPageCacheMiB,
    this.tempStoreInMemory = true,
    this.walAutoCheckpointPages = defaultWalAutoCheckpointPages,
  });

  /// The default hot-document cache size.
  static const int defaultCacheSize = 2000;

  /// The default SQLite page-cache budget ([pageCacheMiB]).
  static const int defaultPageCacheMiB = 64;

  /// The default WAL auto-checkpoint interval ([walAutoCheckpointPages]).
  static const int defaultWalAutoCheckpointPages = 8000;

  /// The `PRAGMA synchronous` level commits run at.
  final Durability durability;

  /// The bounded hot-document cache size, in documents. `0` disables the
  /// cache; reads then always hit SQLite.
  final int cacheSize;

  /// Whether every commit appends its change rows to the on-disk change log
  /// that [Cocoon.changesSince] reads.
  ///
  /// `true` (the default) keeps the log. `false` skips writing the rows —
  /// the log stays empty — while in-process watch notifications are
  /// unaffected; pick it when only `watch()` streams are needed.
  final bool keepChanges;

  /// The SQLite page-cache budget in MiB, applied as
  /// `PRAGMA cache_size = -<MiB * 1024>` on the write connection. Reader
  /// connections keep SQLite's default (2 MiB each), so the extra memory is
  /// paid once, not once per pooled reader.
  ///
  /// SQLite's own 2 MiB default keeps only the hottest B-tree pages resident
  /// once a database outgrows it; a bigger cache is what keeps bulk imports
  /// into a multi-index table from degrading superlinearly (measured: 63 s
  /// -> 36 s for a 1M-document import with this default and
  /// [tempStoreInMemory], see `benchmarks/cocoon_rivals/IMPORT.md`). Values
  /// `<= 0` leave SQLite's default in place.
  final int pageCacheMiB;

  /// Whether temp B-trees (sorting, spilling index builds) stay in memory
  /// (`PRAGMA temp_store = MEMORY`) instead of spilling through temp
  /// storage, on the write connection (readers keep the default).
  ///
  /// Measured together with [pageCacheMiB] for the 1M import above. Turn it
  /// off only on devices where the extra resident memory hurts more than
  /// write throughput.
  final bool tempStoreInMemory;

  /// How many WAL pages accumulate before SQLite checkpoints them back into
  /// the database file (`PRAGMA wal_autocheckpoint`), applied on every
  /// writable connection the database opens.
  ///
  /// SQLite's default, 1000 pages (~4 MiB), checkpoints after nearly every
  /// commit of a bulk import into a multi-index table — the checkpoint cost
  /// grows with the database size and dominates a 1M-document import.
  /// Raising the interval to 8000 pages (32 MiB) halved that import (measured:
  /// 45.6 s -> ~19-24 s through the raw probe, see
  /// `benchmarks/cocoon_rivals/IMPORT.md`) while keeping the WAL bounded —
  /// unlike disabling checkpointing altogether, which grows the WAL without
  /// bound (4.2 GB measured) and was rejected. The WAL file therefore
  /// transiently holds up to ~32 MiB during heavy writes; crash safety is
  /// unchanged (the WAL is durable; checkpointing only moves pages into the
  /// database file, and a larger interval only costs some of that work at
  /// open after a crash). Values `<= 0` keep SQLite's default.
  final int walAutoCheckpointPages;
}

/// A typed, disk-backed, Firestore-style local database on SQLite.
///
/// Open it with the adapters of every collection the app stores, then work
/// through typed references:
///
/// ```dart
/// final db = await Cocoon.open(file, collections: [accounts, txns, splits]);
/// final a1 = db.collection(accounts).doc('a1');
/// await a1.set(Account(name: 'Acme', active: true));
/// final txRef = await a1.collection(txns).add(Txn(...));
/// final snap = await txRef.get();
/// await a1.delete(); // removes a1 and its whole subtree
/// ```
///
/// One `Cocoon` instance must own its database file: do not open the same
/// file from two instances (or processes) at once — the hot-document cache
/// and SQLite's write lock both assume a single writer.
final class Cocoon {
  Cocoon._(
    this._executor,
    this._registry,
    this._cache,
    this._keepChanges, {
    this.databasePath,
    this.schemaLock,
  });

  final CocoonExecutor _executor;
  final SchemaRegistry _registry;
  final DocumentCache _cache;
  final bool _keepChanges;
  final WatchHub _watchHub = WatchHub();

  /// Secondary indexes currently dropped by running bulk writers, as
  /// name -> active-writer count; queries whose plan needs one of them wait
  /// until the count reaches zero.
  final Map<String, int> _deferredIndexCounts = {};

  /// Live bulk writers (for the deferred-index accounting).
  var _bulkWriters = 0;

  /// Queries waiting for deferred indexes to come back.
  final List<({Set<String> needed, Completer<void> completer})> _bulkWaiters =
      [];

  /// The file path the database was opened from, or `null` when it was
  /// opened over a custom executor via [openWith]. Surfaced by the DevTools
  /// inspector's database list.
  @internal
  final String? databasePath;

  /// The schema lock the app handed to [open], or `null`. When present, the
  /// DevTools inspector's schema view can also show pinned field numbers
  /// and reserved numbers; without it, only what the engine knows.
  @internal
  final SchemaLock? schemaLock;

  /// Opens (or creates) the database at [path] and reconciles the schema
  /// with [collections] inside one write transaction.
  ///
  /// The parent directory of [path] must exist. Throws an [ArgumentError]
  /// when the adapters are invalid (duplicate models, unknown index fields,
  /// a subcollection whose parent collection has no adapter, ...).
  ///
  /// With [schemaVersion] (the generated `cocoonSchemaVersion`) the open
  /// also tracks the schema version in `_cocoon_meta`: a fresh database just
  /// stores it, an older one runs every step of [migrations] with a greater
  /// version once, in order, in the same transaction, and a database written
  /// by a NEWER version refuses to open with a [SchemaTooNewException].
  /// [onMigrationProgress] reports `(documents processed, documents total)`
  /// per batch while the steps run. See the README's "Schema migrations".
  ///
  /// With [schemaLock] (the parsed `cocoon.lock.json`) the DevTools
  /// inspector's schema view can also show pinned field numbers and
  /// reserved numbers; without it, it shows only what the engine knows.
  static Future<Cocoon> open(
    String path, {
    required List<CollectionAdapter<Object?>> collections,
    CocoonOptions options = const CocoonOptions(),
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
  }) async {
    final executor = SqliteExecutor(
      SqliteDatabase.withFactory(
        CocoonSqliteOpenFactory(
          path: path,
          sqliteOptions: SqliteOptions(
            synchronous: _synchronousOf(options.durability),
            // sqlite_async's dev-mode timeline tracing costs a TimelineTask
            // plus an arguments map per executed statement (measured: ~5 s
            // of a 100k-document import, see
            // benchmarks/cocoon_rivals/IMPORT.md). Cocoon's DevTools
            // integration does not use those events, so the engine opens
            // its connections with them off.
            profileQueries: false,
          ),
          pageCacheKib: options.pageCacheMiB <= 0
              ? 0
              : options.pageCacheMiB * 1024,
          tempStoreInMemory: options.tempStoreInMemory,
          walAutoCheckpointPages: options.walAutoCheckpointPages,
        ),
      ),
    );
    try {
      return await openWith(
        executor,
        collections: collections,
        options: options,
        schemaVersion: schemaVersion,
        migrations: migrations,
        onMigrationProgress: onMigrationProgress,
        schemaLock: schemaLock,
        databasePath: path,
      );
    } on Object {
      await executor.close();
      rethrow;
    }
  }

  /// Opens over an existing [executor]; used by tests to spy on statements.
  ///
  /// Same schema-version handling as [open]: see its [schemaVersion],
  /// [migrations] and [onMigrationProgress] documentation. [schemaLock] and
  /// [databasePath] are only surfaced to the DevTools inspector.
  @visibleForTesting
  static Future<Cocoon> openWith(
    CocoonExecutor executor, {
    required List<CollectionAdapter<Object?>> collections,
    CocoonOptions options = const CocoonOptions(),
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
    String? databasePath,
  }) async {
    final registry = SchemaRegistry.build(collections);
    await executor.writeTransaction((tx) async {
      await _createMetaTableIfMissing(tx);
      await _createChangesTableIfMissing(tx);
      final migratedTables = await _applySchemaVersion(
        tx,
        registry,
        schemaVersion: schemaVersion,
        migrations: migrations,
        keepChanges: options.keepChanges,
        onMigrationProgress: onMigrationProgress,
      );
      await _reconcile(tx, registry, forceTables: migratedTables);
      // A crashed bulk writer leaves its deferred indexes recorded in
      // `_cocoon_bulk`; rebuild them before the app sees the database.
      await _recoverBulkIndexes(tx, registry);
    });
    final db = Cocoon._(
      executor,
      registry,
      DocumentCache(options.cacheSize),
      options.keepChanges,
      databasePath: databasePath,
      schemaLock: schemaLock,
    );
    CocoonInspectorService.attach(db);
    return db;
  }

  /// Closes the database. Every watch stream this instance created
  /// completes; using references of a closed database throws. A query still
  /// waiting for a bulk writer's deferred indexes fails with a [StateError].
  Future<void> close() {
    CocoonInspectorService.detach(this);
    _watchHub.close();
    for (final waiter in _bulkWaiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(
          StateError(
            'The database was closed while this query waited for a '
            'BulkWriter to finish',
          ),
        );
      }
    }
    _bulkWaiters.clear();
    return _executor.close();
  }

  /// Starts a Firestore-style BulkWriter: queue `set`/`update`/`delete`
  /// synchronously, and the writer commits them in chunks of
  /// [BulkWriterOptions.chunkSize] rows — one write transaction per chunk,
  /// atomic per chunk, not atomic as a whole. `await bulk.close()` flushes
  /// the rest, rebuilds the deferred secondary indexes and resolves when
  /// everything is durable. See [BulkWriter] — this is the bulk-load path
  /// for imports far larger than [batch].
  BulkWriter bulkWriter([
    BulkWriterOptions options = const BulkWriterOptions(),
  ]) => BulkWriter(this, options);

  /// The root collection backed by a top-level [adapter].
  ///
  /// Throws an [ArgumentError] for a subcollection adapter; use
  /// `doc(...).collection(...)` for those.
  CollectionRef<V> collection<V extends Object>(CollectionAdapter<V> adapter) {
    final pattern = adapter.pattern;
    if (!pattern.isTopLevel) {
      throw ArgumentError.value(
        pattern.pattern,
        'adapter',
        'Only top-level collections can be used here; use '
            'doc(...).collection(...) for subcollections',
      );
    }
    _registry.entryFor(adapter);
    return CollectionRef<V>(this, adapter, pattern.resolve(const {}));
  }

  /// Starts a Firestore-style batch: queue `set`/`update`/`delete` calls
  /// synchronously, then `await batch.commit()` to run them all inside one
  /// write transaction. See [WriteBatch] — this is the bulk-write path.
  WriteBatch batch() => WriteBatch(this);

  /// Every document of [adapter]'s pattern, whatever parent it belongs to.
  CollectionGroupRef<V> collectionGroup<V extends Object>(
    CollectionAdapter<V> adapter,
  ) {
    _registry.entryFor(adapter);
    return CollectionGroupRef<V>(this, adapter);
  }

  /// Runs [body] inside one write transaction: reads see the transaction's
  /// own writes, and an exception rolls everything back — including the
  /// hot-document cache, which is only updated after a successful commit.
  Future<R> runTransaction<R>(Future<R> Function(CocoonTransaction tx) body) =>
      writeTx<R>((wtx) => body(CocoonTransaction(wtx)));

  /// How many documents the hot-document cache currently holds.
  @visibleForTesting
  int get debugCacheLength => _cache.length;

  /// How many watch streams are currently registered (listening).
  @visibleForTesting
  int get debugWatcherCount => _watchHub.length;

  /// The hub every live watch registers with.
  @internal
  WatchHub get watchHub => _watchHub;

  /// The schema registry (adapters, tables, columns, indexes) behind this
  /// database; read by the DevTools inspector.
  @internal
  SchemaRegistry get registry => _registry;

  /// The raw executor; used by the DevTools inspector for its read-only
  /// SQL (`EXPLAIN QUERY PLAN`, `PRAGMA table_info`, `sqlite_master`).
  @internal
  CocoonExecutor get executor => _executor;

  // -- Engine internals ----------------------------------------------------

  /// Runs [body] in one write transaction, applying its staged cache updates
  /// only after the commit succeeds, then delivers one commit event with the
  /// touched paths to the watch hub. Rolled-back transactions report nothing.
  ///
  /// Document writes buffer in the transaction's [WriteTx] and flush as
  /// batched statements before the COMMIT (and before any read or delete in
  /// the same transaction, and every [writeFlushThreshold] rows).
  @internal
  Future<R> writeTx<R>(Future<R> Function(WriteTx wtx) body) async {
    final stage = CacheStage();
    final result = await _executor.writeTransaction((tx) async {
      final wtx = WriteTx(this, tx, stage);
      final out = await body(wtx);
      await wtx.flush();
      return out;
    });
    stage.applyTo(_cache);
    final touched = stage.takeTouched();
    if (touched.isNotEmpty) {
      _watchHub.emit(CommitEvent(touched));
    }
    return result;
  }

  /// The live stream behind [DocRef.watch].
  @internal
  Stream<DocSnapshot<T>?> watchDoc<T extends Object>(DocRef<T> ref) {
    final table = _registry.entryFor(ref.adapter).table;
    return DocWatch<T>(this, ref, table).stream;
  }

  /// The live stream behind [CocoonQuery.watch].
  @internal
  Stream<QueryPage<T>> watchQuery<T extends Object>(CocoonQuery<T> query) {
    final spec = query.spec;
    final table = _registry.entryFor(spec.adapter).table;
    return QueryWatch<T>(this, query, table, spec.scopePath).stream;
  }

  @internal
  Future<DocSnapshot<T>?> getDoc<T extends Object>(DocRef<T> ref) async {
    final entry = _registry.entryFor(ref.adapter);
    final cached = _cache.get(ref.path.path);
    if (cached != null) {
      // A write cached the encoded bytes; decode once and promote the value,
      // so the decoded object a later read sees is exactly what the stored
      // bytes decode to.
      if (cached is EncodedDoc) {
        final value = entry.adapter.decode(cached.bytes) as T;
        _cache.put(ref.path.path, value);
        return DocSnapshot<T>(ref, value);
      }
      return DocSnapshot<T>(ref, cached as T);
    }
    return _readDoc<T>(_executor, ref, cachePut: true);
  }

  @internal
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonTx tx,
    DocRef<T> ref,
  ) => _readDoc<T>(tx, ref, cachePut: false);

  @internal
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value) =>
      writeTx<void>((wtx) => wtx.put(ref, value));

  @internal
  Future<DocRef<T>> addDoc<T extends Object>(CollectionRef<T> ref, T value) =>
      writeTx<DocRef<T>>((wtx) => wtx.add(ref, value));

  @internal
  Future<void> deleteDoc(DocRef<Object> ref) =>
      writeTx<void>((wtx) => wtx.delete(ref));

  /// Deletes the document at [path] from [table], returning its `(table,
  /// path)` pair only when a row was actually removed.
  @internal
  Future<List<(String, String)>> deleteReturning(
    CocoonTx tx,
    String table,
    String path,
  ) async {
    final rows = await tx.getAll(
      'DELETE FROM $table WHERE path = ? RETURNING path',
      [path],
    );
    return [for (final row in rows) (table, row['path']! as String)];
  }

  /// Deletes the half-open subtree range from [table], returning one
  /// `(table, path)` pair per removed document.
  @internal
  Future<List<(String, String)>> deleteSubtree(
    CocoonTx tx,
    String table,
    String from,
    String to,
  ) async {
    final rows = await tx.getAll(
      'DELETE FROM $table WHERE path >= ? AND path < ? RETURNING path',
      [from, to],
    );
    return [for (final row in rows) (table, row['path']! as String)];
  }

  /// Whether every commit appends its change rows to the on-disk log.
  @internal
  bool get keepsChanges => _keepChanges;

  @internal
  Future<QueryPage<T>> runQuery<T extends Object>(CocoonQuery<T> query) async =>
      (await runQueryWithBytes<T>(query)).$1;

  /// Runs [query], also returning each document's stored wire bytes in page
  /// order — the signature query watches deduplicate pages by.
  ///
  /// A query whose plan needs an index a bulk writer currently has deferred
  /// waits until the writer rebuilds it, then runs.
  @internal
  Future<(QueryPage<T>, List<Uint8List>)> runQueryWithBytes<T extends Object>(
    CocoonQuery<T> query,
  ) async {
    final spec = query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planQuery(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: spec.limit,
      cursor: spec.startAfter,
      fullScan: spec.fullScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await _executor.getAll(plan.sql, plan.args);
    final limit = spec.limit;
    var pageRows = rows;
    String? nextCursor;
    if (limit != null && rows.length > limit) {
      pageRows = rows.sublist(0, limit);
      // Cursor keys follow the effective order: the sort-key SQL values and
      // the document id last, as the tiebreaker.
      final last = pageRows.last;
      final keys = [
        for (final column in plan.cursorColumns) last[column]!,
        last['id']!,
      ];
      nextCursor = CursorCodec.encode(plan.fingerprint, keys);
    }
    final docs = <DocSnapshot<T>>[
      for (final row in pageRows) _snapshotFromRow<T>(entry, row),
    ];
    final bytes = <Uint8List>[
      for (final row in pageRows) row['data']! as Uint8List,
    ];
    return (QueryPage<T>(docs, nextCursor), bytes);
  }

  @internal
  Future<int> runCount<T extends Object>(CocoonQuery<T> query) async {
    final spec = query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planQuery(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: null,
      cursor: null,
      fullScan: spec.fullScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await _executor.getAll(plan.countSql, plan.countArgs);
    return rows.first['c']! as int;
  }

  // -- Bulk-writer deferred indexes ----------------------------------------

  /// Registers a live bulk writer (for the deferred-index accounting).
  @internal
  void noteBulkWriterActive() => _bulkWriters++;

  /// Unregisters a finished bulk writer.
  @internal
  void noteBulkWriterClosed() => _bulkWriters--;

  /// Marks [indexNames] as dropped by a bulk writer: queries whose plan
  /// needs one of them wait until they are rebuilt.
  @internal
  void noteIndexesDeferred(Iterable<String> indexNames) {
    for (final name in indexNames) {
      _deferredIndexCounts[name] = (_deferredIndexCounts[name] ?? 0) + 1;
    }
  }

  /// Marks [indexNames] as rebuilt by a bulk writer's close, releasing the
  /// queries that waited for them.
  @internal
  void noteIndexesRestored(Iterable<String> indexNames) {
    for (final name in indexNames) {
      final count = _deferredIndexCounts[name];
      if (count == null) {
        continue;
      }
      if (count <= 1) {
        _deferredIndexCounts.remove(name);
      } else {
        _deferredIndexCounts[name] = count - 1;
      }
    }
    _serveBulkWaiters();
  }

  /// Resolves when [servingIndex] is no longer deferred by a bulk writer
  /// (immediately when it never was). Queries call this between planning
  /// and execution.
  @internal
  Future<void> waitForBulkIndexes(String? servingIndex) {
    if (servingIndex == null ||
        !_deferredIndexCounts.containsKey(servingIndex)) {
      return Future.value();
    }
    final needed = {servingIndex};
    final completer = Completer<void>();
    _bulkWaiters.add((needed: needed, completer: completer));
    // The last writer may have restored between the check and the add.
    if (!_deferredIndexCounts.containsKey(servingIndex)) {
      _serveBulkWaiters();
    }
    return completer.future;
  }

  void _serveBulkWaiters() {
    if (_bulkWaiters.isEmpty) {
      return;
    }
    for (final waiter in List.of(_bulkWaiters)) {
      if (!waiter.needed.any(_deferredIndexCounts.containsKey)) {
        _bulkWaiters.remove(waiter);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete();
        }
      }
    }
  }

  // -- Change log -----------------------------------------------------------

  /// Returns the change-log rows newer than [seq], oldest first.
  ///
  /// Every committed write appends one row per touched document — including
  /// one row per cascaded delete — in the same transaction as the write.
  /// Returns at most [limit] rows; keep calling with the last row's
  /// [Change.seq] until the list comes back empty. With
  /// `CocoonOptions.keepChanges` disabled the log is never written and this
  /// always returns an empty list.
  Future<List<Change>> changesSince(int seq, {int limit = 1000}) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be at least 1');
    }
    final rows = await _executor.getAll(
      'SELECT seq, tbl, path, op, at FROM $changesTableName '
      'WHERE seq > ? ORDER BY seq LIMIT ?',
      [seq, limit],
    );
    return [for (final row in rows) _changeFromRow(row)];
  }

  /// The highest seq ever assigned to a change, or `0` when nothing was
  /// logged yet.
  ///
  /// It never goes backwards: pruning removes rows but keeps the head, so a
  /// sync outbox can compare its own watermark against it at any time.
  Future<int> lastChangeSeq() async {
    final row = await _executor.getOptional(
      'SELECT seq FROM sqlite_sequence WHERE name = ?',
      [changesTableName],
    );
    return (row?['seq'] as int?) ?? 0;
  }

  /// Deletes every change row with `seq <= upToSeq`.
  ///
  /// Call it once changes are durably processed elsewhere (synced, audited);
  /// the log would otherwise grow forever.
  Future<void> pruneChanges({required int upToSeq}) {
    return _executor.writeTransaction((tx) async {
      await tx.execute('DELETE FROM $changesTableName WHERE seq <= ?', [
        upToSeq,
      ]);
    });
  }

  Change _changeFromRow(Map<String, Object?> row) {
    final table = row['tbl']! as String;
    final op = row['op']! as String;
    return Change(
      seq: row['seq']! as int,
      collection: _modelOfTable(table),
      path: row['path']! as String,
      op: switch (op) {
        'set' => ChangeOp.set,
        'delete' => ChangeOp.delete,
        _ => throw StateError('Unknown change op "$op" in the change log'),
      },
      at: DateTime.fromMicrosecondsSinceEpoch(row['at']! as int, isUtc: true),
    );
  }

  /// The model name of a registered SQL [table], or the table name itself
  /// for a table without a registered adapter (defensive; the log only ever
  /// holds rows for registered collections).
  String _modelOfTable(String table) {
    for (final entry in _registry.entries) {
      if (entry.table == table) {
        return entry.adapter.model;
      }
    }
    return table;
  }

  DocSnapshot<T> _snapshotFromRow<T extends Object>(
    RegistryEntry entry,
    Map<String, Object?> row,
  ) {
    final params = <String, String>{
      for (var i = 0; i < entry.paramNames.length; i++)
        entry.paramNames[i]: row[entry.paramSqlNames[i]]! as String,
    };
    final collectionPath = entry.adapter.pattern.resolve(params);
    final docPath = collectionPath.doc(row['id']! as String);
    final value = entry.adapter.decode(row['data'] as Uint8List) as T;
    return DocSnapshot<T>(
      DocRef<T>(this, entry.adapter as CollectionAdapter<T>, docPath),
      value,
    );
  }

  Future<DocSnapshot<T>?> _readDoc<T extends Object>(
    CocoonRead reader,
    DocRef<T> ref, {
    required bool cachePut,
  }) async {
    final entry = _registry.entryFor(ref.adapter);
    final row = await reader.getOptional(
      'SELECT data FROM ${entry.table} WHERE path = ?',
      [ref.path.path],
    );
    if (row == null) {
      return null;
    }
    final value = entry.adapter.decode(row['data'] as Uint8List) as T;
    if (cachePut) {
      _cache.put(ref.path.path, value);
    }
    return DocSnapshot<T>(ref, value);
  }

  @internal
  List<String> paramValuesInOrder(RegistryEntry entry, CollectionPath path) {
    final patternSegments = entry.adapter.pattern.pattern.split('/');
    final pathSegments = path.path.split('/');
    return [
      for (var i = 1; i < patternSegments.length; i += 2) pathSegments[i],
    ];
  }

  // -- Schema reconciliation ----------------------------------------------

  /// Compares the stored schema version with [schemaVersion] and applies
  /// every pending [CocoonMigration] (see [runSchemaMigrationsInTx]); then
  /// stores the current version. Returns the migrated tables, which the
  /// reconciler must rebuild even when their shape hash matches.
  ///
  /// A `null` [schemaVersion] (databases opened without version tracking)
  /// does nothing.
  static Future<Set<String>> _applySchemaVersion(
    CocoonTx tx,
    SchemaRegistry registry, {
    required int? schemaVersion,
    required List<CocoonMigration> migrations,
    required bool keepChanges,
    void Function(int done, int total)? onMigrationProgress,
  }) async {
    if (schemaVersion == null) {
      return const {};
    }
    final row = await tx.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      [schemaVersionMetaKey],
    );
    final stored = row == null ? 0 : int.parse(row['value']! as String);
    if (stored > schemaVersion) {
      throw SchemaTooNewException(stored, schemaVersion);
    }
    if (stored == schemaVersion) {
      return const {};
    }
    final pending = [
      for (final migration in migrations)
        if (migration.version > stored) migration,
    ]..sort((a, b) => a.version.compareTo(b.version));
    final migratedTables = pending.isEmpty
        ? const <String>{}
        : await runSchemaMigrationsInTx(
            tx: tx,
            registry: registry,
            pending: pending,
            keepChanges: keepChanges,
            onProgress: onMigrationProgress,
          );
    await tx.execute(
      'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
      [schemaVersionMetaKey, '$schemaVersion'],
    );
    return migratedTables;
  }

  static Future<void> _reconcile(
    CocoonTx tx,
    SchemaRegistry registry, {
    Set<String> forceTables = const {},
  }) async {
    for (final entry in registry.entries) {
      final stored = await tx.getOptional(
        'SELECT value FROM $metaTableName WHERE key = ?',
        ['shape:${entry.table}'],
      );
      final tableExists =
          await tx.getOptional(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            'AND name = ?',
            [entry.table],
          ) !=
          null;
      if (!forceTables.contains(entry.table) &&
          tableExists &&
          stored != null &&
          stored['value'] == entry.shapeHash) {
        // Shape unchanged: no DDL beyond the two reads above.
        continue;
      }
      if (!tableExists) {
        await tx.execute(
          createTableSql(entry.table, entry.paramSqlNames, entry.columnDdls),
        );
        await tx.execute(createScopeIndexSql(entry.table, entry.paramSqlNames));
        for (final index in entry.indexes) {
          await tx.execute(createIndexSql(entry.table, index));
        }
      } else {
        await _reconcileTable(tx, entry);
      }
      await tx.execute(
        'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
        ['shape:${entry.table}', entry.shapeHash],
      );
    }
  }

  static Future<void> _createMetaTableIfMissing(CocoonTx tx) async {
    final exists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [metaTableName],
    );
    if (exists == null) {
      await tx.execute(createMetaTableSql());
    }
  }

  static Future<void> _createChangesTableIfMissing(CocoonTx tx) async {
    final exists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [changesTableName],
    );
    if (exists == null) {
      await tx.execute(createChangesTableSql());
    }
  }

  /// Rebuilds the secondary indexes a crashed [BulkWriter] left deferred and
  /// clears the meta rows, in the open transaction.
  ///
  /// The writer records every dropped index in `_cocoon_bulk` (with the DDL
  /// that recreates it) in the same transaction that drops it, so rows left
  /// behind mean the load never finished: without this step the database
  /// would open with missing indexes — and, the shape hash being unchanged,
  /// the reconciler would not recreate them. A recorded index is only
  /// rebuilt when the current schema still declares it and its table still
  /// exists, so a schema change between the crash and the reopen is
  /// respected. Replay is idempotent (`CREATE ... IF NOT EXISTS`): when the
  /// reconciler already recreated the index, the replay is a no-op.
  static Future<void> _recoverBulkIndexes(
    CocoonTx tx,
    SchemaRegistry registry,
  ) async {
    final bulkTableExists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [bulkTableName],
    );
    if (bulkTableExists == null) {
      return;
    }
    final rows = await tx.getAll(
      'SELECT tbl, index_name, sql FROM $bulkTableName',
    );
    if (rows.isEmpty) {
      return;
    }
    final byTable = {for (final entry in registry.entries) entry.table: entry};
    for (final row in rows) {
      final table = row['tbl']! as String;
      final name = row['index_name']! as String;
      final entry = byTable[table];
      if (entry == null) {
        continue;
      }
      if (!entry.indexes.any((index) => index.name == name)) {
        continue;
      }
      final tableExists =
          await tx.getOptional(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            'AND name = ?',
            [table],
          ) !=
          null;
      if (!tableExists) {
        continue;
      }
      await tx.execute(row['sql']! as String);
    }
    await tx.execute('DELETE FROM $bulkTableName');
  }

  static Future<void> _reconcileTable(CocoonTx tx, RegistryEntry entry) async {
    final existingColumns = await _columnNames(tx, entry.table);
    final declaredColumns = {
      for (final column in entry.columnDdls) column.name,
    };
    final columnsToAdd = [
      for (final column in entry.columnDdls)
        if (!existingColumns.contains(column.name)) column,
    ];
    final columnsToDrop = [
      for (final name in existingColumns)
        if (name.startsWith('f_') && !declaredColumns.contains(name)) name,
    ];
    final existingIndexes = await _cocoonIndexNames(tx, entry.table);
    final expectedIndexNames = {
      entry.scopeIndex.name,
      for (final index in entry.indexes) index.name,
    };

    // Dropped columns must lose their indexes first, and any index that is
    // no longer declared goes away with the shape change.
    if (columnsToDrop.isNotEmpty) {
      for (final name in existingIndexes) {
        await tx.execute('DROP INDEX IF EXISTS "$name"');
      }
    } else {
      for (final name in existingIndexes) {
        if (!expectedIndexNames.contains(name)) {
          await tx.execute('DROP INDEX IF EXISTS "$name"');
        }
      }
    }

    // New field columns are added, then backfilled from the stored
    // documents, in batches, before the indexes that use them are created.
    for (final column in columnsToAdd) {
      await tx.execute(alterAddColumnSql(entry.table, column));
    }
    if (columnsToAdd.isNotEmpty) {
      await _backfillColumns(tx, entry, columnsToAdd);
    }

    for (final name in columnsToDrop) {
      await tx.execute('ALTER TABLE ${entry.table} DROP COLUMN "$name"');
    }

    await tx.execute(createScopeIndexSql(entry.table, entry.paramSqlNames));
    for (final index in entry.indexes) {
      await tx.execute(createIndexSql(entry.table, index));
    }
  }

  static Future<void> _backfillColumns(
    CocoonTx tx,
    RegistryEntry entry,
    List<ColumnDdl> columns,
  ) async {
    final addedFields = <FieldColumn<Object?, Object?>>[
      for (final column in columns)
        entry.fieldColumns[entry.columnDdls.indexOf(column)],
    ];
    final updateSql =
        'UPDATE ${entry.table} SET '
        '${addedFields.map((field) => '${fieldColumnName(field.name)} = ?').join(', ')} '
        'WHERE path = ?';
    var lastPath = '';
    while (true) {
      final rows = await tx.getAll(
        'SELECT path, data FROM ${entry.table} '
        'WHERE path > ? ORDER BY path LIMIT $backfillBatchSize',
        [lastPath],
      );
      if (rows.isEmpty) {
        break;
      }
      final updates = <List<Object?>>[];
      for (final row in rows) {
        final path = row['path']! as String;
        final value = entry.adapter.decode(row['data'] as Uint8List);
        updates.add([
          for (final field in addedFields) field.sqlOf(value),
          path,
        ]);
        lastPath = path;
      }
      await tx.executeBatch(updateSql, updates);
      if (rows.length < backfillBatchSize) {
        break;
      }
    }
  }

  /// Rows decoded per backfill batch.
  static const int backfillBatchSize = 500;

  static Future<Set<String>> _columnNames(CocoonTx tx, String table) async {
    final rows = await tx.getAll('PRAGMA table_info($table)');
    return {for (final row in rows) row['name']! as String};
  }

  static Future<List<String>> _cocoonIndexNames(
    CocoonTx tx,
    String table,
  ) async {
    final rows = await tx.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
      [table],
    );
    final prefix = 'cx_${table}_';
    return [
      for (final row in rows)
        if ((row['name']! as String).startsWith(prefix)) row['name']! as String,
    ];
  }

  static SqliteSynchronous _synchronousOf(Durability durability) =>
      switch (durability) {
        Durability.full => SqliteSynchronous.full,
        Durability.normal => SqliteSynchronous.normal,
      };
}
