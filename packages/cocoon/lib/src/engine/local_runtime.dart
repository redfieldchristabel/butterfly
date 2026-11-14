import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../cursor.dart';
import '../id.dart' show newDocId;
import '../migration.dart';
import '../path.dart';
import '../schema.dart';
import 'adapter.dart';
import 'aggregate.dart';
import 'backup.dart';
import 'batch.dart';
import 'bulk_writer.dart';
import 'cache.dart';
import 'changes.dart';
import 'cocoon.dart';
import 'executor.dart';
import 'format_migration.dart';
import 'isolate/isolate_options.dart' show CocoonIsolateStats;
import 'migrate.dart';
import 'naming.dart';
import 'query.dart';
import 'refs.dart';
import 'runtime.dart';
import 'schema_sql.dart';
import 'transaction_guard.dart';
import 'watch.dart';
import 'write_buffer.dart';

/// The engine a [Cocoon] facade runs in its own isolate: the SQLite
/// executor, the bounded hot-document cache, the watch hub, the deferred
/// bulk-writer accounting and the change-log bookkeeping — today's engine,
/// unchanged, behind the [CocoonRuntime] interface.
///
/// One runtime belongs to one [Cocoon] facade (the [host]); refs and
/// snapshots the engine builds point at that facade. A background worker
/// isolate builds its own facade + runtime pair; the caller's facade is a
/// proxy — see `isolate/background.dart`.
@internal
final class LocalCocoonRuntime implements CocoonRuntime {
  /// Builds the runtime; call [open] before handing it to a facade.
  ///
  /// [onCompactionFailed] receives post-upgrade compaction failures. In a
  /// background worker this callback is `null` and the worker reports the
  /// failure as a message instead, so a user callback never has to cross
  /// isolate boundaries.
  LocalCocoonRuntime({void Function(Object error)? onCompactionFailed})
    : _onCompactionFailed = onCompactionFailed;

  /// The facade this runtime serves; refs and snapshots point at it. Set by
  /// the facade constructor, before any engine call can run.
  @override
  late Cocoon host;

  final void Function(Object error)? _onCompactionFailed;

  CocoonExecutor? _executor;
  late SchemaRegistry _registry;
  late DocumentCache _cache;
  late bool _keepChanges;
  ChangeRetention? _changeRetention;
  MissingIndexMode _missingIndexMode = MissingIndexMode.throwError;
  bool _closed = false;

  /// The missing indexes scanAndWarn queries of this database have hit, by
  /// fix command; exposed through [missingIndexes].
  final Map<String, MissingIndexReport> _missingIndexes = {};

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

  @override
  SchemaRegistry get registry => _registry;

  @override
  WatchHub get watchHub => _watchHub;

  @override
  bool get isLocal => true;

  @override
  String get isolateModeName => host.isolateModeName;

  @override
  CocoonIsolateStats? get isolateStats => null;

  @override
  CocoonExecutor get executor {
    final executor = _executor;
    if (executor == null || _closed) {
      throw StateError('The database is closed');
    }
    return executor;
  }

  /// Runs the open transaction over [executor]: storage format, schema
  /// versions, migrations, reconcile, bulk-index recovery — then the
  /// post-upgrade compaction. Returns the database's instance id.
  Future<String> open(
    CocoonExecutor executor,
    SchemaRegistry registry, {
    required CocoonOptions options,
    required SchemaLock? schemaLock,
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    String? databasePath,
  }) async {
    _executor = executor;
    _registry = registry;
    _cache = DocumentCache(options.cacheSize);
    _keepChanges = options.keepChanges;
    _changeRetention = options.changeRetention;
    _missingIndexMode = options.onMissingIndex;
    var upgradedFormat = false;
    final instanceId = await executor.writeTransaction((tx) async {
      await Cocoon.createMetaTableIfMissing(tx);
      await Cocoon.createChangesTableIfMissing(tx);
      final instanceId = await _ensureInstanceId(tx);
      // The file's storage layout is brought up to the engine's before the
      // schema versions run: the format rebuild is shape-preserving, and
      // the migration runner and reconciler both assume the current layout.
      upgradedFormat = await _applyStorageFormat(
        tx,
        onMigrationProgress: onMigrationProgress,
        databasePath: databasePath ?? '',
      );
      if (schemaLock != null) {
        await tx.execute(
          'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
          [
            schemaLockHashMetaKey,
            queryFingerprint(jsonEncode(schemaLock.toJson())),
          ],
        );
      }
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
      return instanceId;
    });
    if (upgradedFormat && options.compactAfterUpgrade) {
      // The upgrade's dropped tables left their pages on the freelist;
      // reclaim them now, outside the open transaction, so a phone does not
      // carry the waste until its next backup. Never fails the open.
      await _compactAfterFormatUpgrade(executor);
    }
    return instanceId;
  }

  @override
  Future<void> close() {
    _closed = true;
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
    return _executor!.close();
  }

  @override
  WriteBatch createWriteBatch(Cocoon db) => LocalWriteBatch(db);

  /// [Cocoon.getAll]'s engine: cache-first, misses grouped per table and
  /// fetched with one statement per chunk of scope keys, every chunk of one
  /// call inside ONE read transaction.
  @override
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  ) async {
    if (refs.isEmpty) {
      return const [];
    }
    final snapshots = List<DocSnapshot<T>?>.filled(refs.length, null);
    final pending = <String, _PendingDoc>{};
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      final entry = _registry.entryFor(ref.adapter);
      final path = ref.path.path;
      final cached = _cache.get(path);
      if (cached != null) {
        // A write cached the encoded bytes; decode once and promote the
        // value, so what a later read sees is exactly what the stored bytes
        // decode to — the same contract as [getDoc].
        if (cached is EncodedDoc) {
          final value = entry.adapter.decode(cached.bytes) as T;
          _cache.put(path, value);
          snapshots[i] = DocSnapshot<T>(ref, value);
        } else {
          snapshots[i] = DocSnapshot<T>(ref, cached as T);
        }
        continue;
      }
      _addPendingDoc(pending, entry, path, i);
    }
    if (pending.isEmpty) {
      return snapshots;
    }
    await executor.readTransaction(
      (reader) =>
          _fillFromTables<T>(reader, pending, refs, snapshots, cachePut: true),
    );
    return snapshots;
  }

  @override
  BulkWriter createBulkWriter(Cocoon db, BulkWriterOptions options) =>
      LocalBulkWriter(db, options);

  @override
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonRead reader,
    DocRef<T> ref,
  ) => _readDoc<T>(reader, ref, cachePut: false);

  /// Copies the whole database to [path] (the facade checked the file
  /// rules); the source is this database's own file.
  @override
  Future<BackupInfo> backupTo(String path, {required bool overwrite}) =>
      BackupOperations.backupTo(
        sourcePath: host.databasePath!,
        targetPath: path,
        overwrite: overwrite,
      );

  /// The engine path behind `WriteBatch.commit`: every queued op, in call
  /// order, inside one write transaction.
  @override
  Future<void> commitBatchOps(List<BatchOp> ops) => writeTx<void>((wtx) async {
    for (final op in ops) {
      switch (op.kind) {
        case BatchOpKind.set:
          await wtx.put(op.ref, op.value!);
        case BatchOpKind.update:
          await wtx.put(op.ref, op.value!, update: true);
        case BatchOpKind.delete:
          await wtx.delete(op.ref);
      }
    }
  });

  // -- Engine internals -----------------------------------------------------

  @override
  Future<R> writeTx<R>(
    Future<R> Function(CocoonWriteTx wtx) body, {
    bool logChanges = true,
    TransactionScope? txScope,
  }) async {
    final stage = CacheStage();
    final result = await _endGuardAfter(
      txScope,
      () => executor.writeTransaction((tx) async {
        final wtx = WriteTx(host, tx, stage, logChanges: logChanges);
        final out = await body(wtx);
        await wtx.flush();
        return out;
      }),
    );
    stage.applyTo(_cache);
    final touched = stage.takeTouched();
    if (touched.isNotEmpty) {
      _watchHub.emit(CommitEvent(touched));
    }
    if (_changeRetention != null && touched.isNotEmpty) {
      await _enforceChangeRetention();
    }
    return result;
  }

  @override
  Future<R> runTransactionBody<R>(
    Future<R> Function(CocoonWriteTx tx) body, {
    TransactionScope? txScope,
  }) => writeTx<R>(body, txScope: txScope);

  /// Runs [action] and deactivates [scope] the moment it settles: the SQL
  /// transaction inside has then ended (commit OR rollback), before the
  /// cache apply, watch emit and retention that follow the commit — so
  /// futures and timers the transaction body created that run later never
  /// trip the guard.
  Future<R> _endGuardAfter<R>(
    TransactionScope? scope,
    Future<R> Function() action,
  ) async {
    try {
      return await action();
    } finally {
      scope?.deactivate();
    }
  }

  @override
  Stream<DocSnapshot<T>?> watchDoc<T extends Object>(DocRef<T> ref) {
    final table = _registry.entryFor(ref.adapter).table;
    return DocWatch<T>(host, ref, table).stream;
  }

  @override
  Stream<QueryPage<T>> watchQuery<T extends Object>(CocoonQuery<T> query) {
    final spec = query.spec;
    final table = _registry.entryFor(spec.adapter).table;
    return QueryWatch<T>(host, query, table, spec.scopePath).stream;
  }

  @override
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
    return _readDoc<T>(executor, ref, cachePut: true);
  }

  /// [Cocoon.getAll]'s engine inside a transaction: reads through [tx] —
  /// seeing the transaction's own writes exactly like [readDocInTx] — never
  /// the cache, and caches nothing (a transaction's cache updates stay
  /// staged until its commit succeeds). Answers in [refs] order, `null` for
  /// missing documents, duplicates allowed.
  @override
  Future<List<DocSnapshot<T>?>> getAllDocsInTx<T extends Object>(
    CocoonRead tx,
    List<DocRef<T>> refs,
  ) async {
    if (refs.isEmpty) {
      return const [];
    }
    final snapshots = List<DocSnapshot<T>?>.filled(refs.length, null);
    final pending = <String, _PendingDoc>{};
    for (var i = 0; i < refs.length; i++) {
      _addPendingDoc(
        pending,
        _registry.entryFor(refs[i].adapter),
        refs[i].path.path,
        i,
      );
    }
    await _fillFromTables<T>(tx, pending, refs, snapshots, cachePut: false);
    return snapshots;
  }

  @override
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value) =>
      writeTx<void>((wtx) => wtx.put(ref, value));

  @override
  Future<DocRef<T>> addDoc<T extends Object>(CollectionRef<T> ref, T value) =>
      writeTx<DocRef<T>>((wtx) => wtx.add(ref, value));

  @override
  Future<void> deleteDoc(DocRef<Object> ref) =>
      writeTx<void>((wtx) => wtx.delete(ref));

  /// Deletes the one row of [table] (via [entry]) identified by the scope
  /// key [paramValues] + [id], returning its `(table, path)` pair only when
  /// a row was actually removed. The path is derived from the deleted row's
  /// key columns.
  @override
  @internal
  Future<List<(String, String)>> deleteRow(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
    String id,
  ) async {
    final where = [
      for (var i = 0; i < entry.paramSqlNames.length; i++)
        '${entry.paramSqlNames[i]} = ?',
      'id = ?',
    ].join(' AND ');
    final returning = [...entry.paramSqlNames, 'id'].join(', ');
    final rows = await tx.getAll(
      'DELETE FROM ${entry.table} WHERE $where RETURNING $returning',
      [...paramValues, id],
    );
    return [for (final row in rows) (entry.table, entry.pathOfKeyRow(row))];
  }

  /// Deletes every row of [entry]'s table whose leading param columns match
  /// [paramValues] — the whole subtree of the document whose ancestor scope
  /// those values are — returning one `(table, path)` pair per removed row,
  /// path derived from each row's key columns.
  @override
  @internal
  Future<List<(String, String)>> deleteScopePrefix(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
  ) async {
    if (paramValues.isEmpty ||
        paramValues.length > entry.paramSqlNames.length) {
      throw ArgumentError.value(
        paramValues,
        'paramValues',
        'Not a subtree prefix of collection ${entry.adapter.pattern}',
      );
    }
    final where = [
      for (var i = 0; i < paramValues.length; i++)
        '${entry.paramSqlNames[i]} = ?',
    ].join(' AND ');
    final returning = [...entry.paramSqlNames, 'id'].join(', ');
    final rows = await tx.getAll(
      'DELETE FROM ${entry.table} WHERE $where RETURNING $returning',
      paramValues,
    );
    return [for (final row in rows) (entry.table, entry.pathOfKeyRow(row))];
  }

  /// Whether every commit appends its change rows to the on-disk log.
  @override
  @internal
  bool get keepsChanges => _keepChanges;

  @override
  List<MissingIndexReport> get missingIndexes =>
      List.unmodifiable(_missingIndexes.values);

  /// The scanAndWarn decision for a query no index serves (the engine's
  /// own decision — records the report and warns once). Exposed so the auto
  /// runtime can apply the same decision to queries it plans on the caller
  /// before shipping them to the helper isolate.
  @internal
  bool acceptMissingIndexScan(
    MissingIndexException error, {
    required String model,
    required List<String> fields,
    required String queryShape,
  }) => _acceptMissingIndexScan(
    error,
    model: model,
    fields: fields,
    queryShape: queryShape,
  );

  /// The scanAndWarn decision for a query no index serves: record the report
  /// on this database, print the message (with its `Fix:` line) once per
  /// distinct missing index per process, and run the query as a full scan.
  bool _acceptMissingIndexScan(
    MissingIndexException error, {
    required String model,
    required List<String> fields,
    required String queryShape,
  }) {
    if (_missingIndexMode != MissingIndexMode.scanAndWarn ||
        !missingIndexScanPossible) {
      return false;
    }
    final command = error.fixCommand!;
    _missingIndexes.putIfAbsent(
      command,
      () => MissingIndexReport(
        model: model,
        fields: fields,
        query: queryShape,
        fixCommand: command,
        firstSeen: DateTime.now(),
      ),
    );
    warnMissingIndexOnce(error);
    return true;
  }

  @override
  Future<QueryPage<T>> runQuery<T extends Object>(CocoonQuery<T> query) async =>
      (await runQueryWithBytes<T>(query)).$1;

  @override
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
      onMissingIndex: _acceptMissingIndexScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await executor.getAll(plan.sql, plan.args);
    final limit = spec.limit;
    var pageRows = rows;
    String? nextCursor;
    if (limit != null && rows.length > limit) {
      pageRows = rows.sublist(0, limit);
      // One cursor key per effective order, read from that order's own
      // result column (field column, param column or id) — never from a
      // de-duplicated column list, so the param tiebreakers of a
      // collection-group query carry their values too and the key count
      // always matches the sort order the next page re-uses.
      final last = pageRows.last;
      final keys = [for (final column in plan.cursorColumns) last[column]!];
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

  @override
  Future<int> runCount<T extends Object>(CocoonQuery<T> query) async {
    // Sugar for `aggregate([count()])`: the same planner, the same index
    // rule, the same one-statement execution, identical results.
    final snapshot = await runAggregate<T>(
      AggregateQuery<T>(query, [count<T>()]),
    );
    return snapshot.count;
  }

  @override
  Future<AggregateQuerySnapshot<T>> runAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) async {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planAggregate(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: spec.limit,
      fullScan: spec.fullScan,
      specs: aggregate.specs,
      onMissingIndex: _acceptMissingIndexScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await executor.getAll(plan.sql, plan.args);
    return aggregateSnapshotFromRow<T>(aggregate.specs, rows.single);
  }

  @override
  Future<List<AggregateGroup<T>>> runGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) async {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planGroupAggregate(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: aggregate.maxGroups,
      fullScan: spec.fullScan,
      keys: aggregate.keys,
      specs: aggregate.specs,
      onMissingIndex: _acceptMissingIndexScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await executor.getAll(plan.sql, plan.args);
    return aggregateGroupsFromRows<T>(aggregate.keys, aggregate.specs, rows);
  }

  @override
  Stream<AggregateQuerySnapshot<T>> watchAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    return ComputedWatch<AggregateQuerySnapshot<T>>(
      host,
      entry.table,
      spec.scopePath,
      () => runAggregate(aggregate),
      (previous, next) => previous == next,
    ).stream;
  }

  @override
  Stream<List<AggregateGroup<T>>> watchGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    return ComputedWatch<List<AggregateGroup<T>>>(
      host,
      entry.table,
      spec.scopePath,
      () => runGroupAggregate(aggregate),
      (previous, next) => _sameGroups(previous, next),
    ).stream;
  }

  static bool _sameGroups<T extends Object>(
    List<AggregateGroup<T>> previous,
    List<AggregateGroup<T>> next,
  ) {
    if (previous.length != next.length) {
      return false;
    }
    for (var i = 0; i < previous.length; i++) {
      if (previous[i] != next[i]) {
        return false;
      }
    }
    return true;
  }

  // -- Bulk-writer deferred indexes ----------------------------------------

  @override
  void noteBulkWriterActive() => _bulkWriters++;

  @override
  void noteBulkWriterClosed() => _bulkWriters--;

  @override
  void noteIndexesDeferred(Iterable<String> indexNames) {
    for (final name in indexNames) {
      _deferredIndexCounts[name] = (_deferredIndexCounts[name] ?? 0) + 1;
    }
  }

  @override
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

  @override
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

  @override
  Future<List<Change>> changesSince(int seq, {int limit = 1000}) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be at least 1');
    }
    final earliest = await earliestChangeSeq();
    if (seq + 1 < earliest) {
      throw ChangesPrunedException(requestedSeq: seq, earliestSeq: earliest);
    }
    final rows = await executor.getAll(
      'SELECT seq, tbl, path, op, at FROM $changesTableName '
      'WHERE seq > ? ORDER BY seq LIMIT ?',
      [seq, limit],
    );
    return [for (final row in rows) _changeFromRow(row)];
  }

  @override
  Future<int> earliestChangeSeq() async {
    final row = await executor.getOptional(
      'SELECT MIN(seq) AS seq FROM $changesTableName',
    );
    final min = row?['seq'] as int?;
    if (min != null) {
      return min;
    }
    return (await lastChangeSeq()) + 1;
  }

  @override
  Future<int> lastChangeSeq() async {
    final row = await executor.getOptional(
      'SELECT seq FROM sqlite_sequence WHERE name = ?',
      [changesTableName],
    );
    return (row?['seq'] as int?) ?? 0;
  }

  @override
  Future<int> pruneChanges({required int upToSeq}) async {
    if (upToSeq < 0) {
      throw ArgumentError.value(upToSeq, 'upToSeq', 'Must not be negative');
    }
    return executor.writeTransaction((tx) async {
      await tx.execute('DELETE FROM $changesTableName WHERE seq <= ?', [
        upToSeq,
      ]);
      final row = await tx.getOptional('SELECT changes() AS c');
      return row!['c']! as int;
    });
  }

  /// Applies [CocoonOptions.changeRetention] after a commit: computes the
  /// seq floor the count and age bounds imply and deletes the log's old
  /// prefix in small batches, in its own write transaction — never inside a
  /// user transaction. One call deletes at most
  /// [CocoonOptions.defaultRetentionBatchStatements] batches
  /// ([CocoonOptions.defaultRetentionBatchRows] rows each) and walks at
  /// most that many batches to find the age floor, so a large backlog
  /// shrinks over the commits that follow instead of stalling one write.
  Future<void> _enforceChangeRetention() async {
    final retention = _changeRetention!;
    final last = await lastChangeSeq();
    if (last == 0) {
      return;
    }
    var floor = 0;
    if (retention.maxChanges != null) {
      // Keep at most the newest N rows: everything at or below
      // `last - N` goes (the AUTOINCREMENT seqs of committed rows are
      // contiguous, so this is exact).
      final countFloor = last - retention.maxChanges!;
      if (countFloor > floor) {
        floor = countFloor;
      }
    }
    if (retention.maxAge != null) {
      final cutoff =
          DateTime.now().toUtc().microsecondsSinceEpoch -
          retention.maxAge!.inMicroseconds;
      // The log is append-ordered, so rows older than the cutoff are (up
      // to clock skew) a prefix; walk it in small batches and keep only
      // the verified-older part.
      final batch = CocoonOptions.defaultRetentionBatchRows;
      var low = 0;
      for (
        var walked = 0;
        walked < CocoonOptions.defaultRetentionBatchStatements;
        walked++
      ) {
        final rows = await executor.getAll(
          'SELECT seq, at FROM $changesTableName WHERE seq > ? '
          'ORDER BY seq LIMIT ?',
          [low, batch],
        );
        if (rows.isEmpty) {
          break;
        }
        var oldest = 0;
        for (final row in rows) {
          if ((row['at']! as int) >= cutoff) {
            break;
          }
          oldest = row['seq']! as int;
        }
        if (oldest > floor) {
          floor = oldest;
        }
        // `oldest == 0`: this batch already holds a row newer than the
        // cutoff. A short batch is the log's end. Either way the old
        // prefix is behind us; otherwise keep walking.
        if (oldest == 0 ||
            oldest != (rows.last['seq']! as int) ||
            rows.length < batch) {
          break;
        }
        low = oldest;
      }
    }
    if (floor <= 0) {
      return;
    }
    await executor.writeTransaction((tx) async {
      var statements = 0;
      while (statements < CocoonOptions.defaultRetentionBatchStatements) {
        final result = await tx.getAll(
          'DELETE FROM $changesTableName WHERE seq IN '
          '(SELECT seq FROM $changesTableName WHERE seq <= ? LIMIT ?) '
          'RETURNING seq',
          [floor, CocoonOptions.defaultRetentionBatchRows],
        );
        statements++;
        if (result.length < CocoonOptions.defaultRetentionBatchRows) {
          break;
        }
      }
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
      DocRef<T>(host, entry.adapter as CollectionAdapter<T>, docPath),
      value,
    );
  }

  Future<DocSnapshot<T>?> _readDoc<T extends Object>(
    CocoonRead reader,
    DocRef<T> ref, {
    required bool cachePut,
  }) async {
    final entry = _registry.entryFor(ref.adapter);
    final key = entry.scopeKeyOf(ref.path.path);
    if (key == null) {
      throw ArgumentError.value(
        ref.path.path,
        'ref',
        'Not a document path of collection ${entry.adapter.pattern}',
      );
    }
    final where = [
      for (var i = 0; i < entry.paramSqlNames.length; i++)
        '${entry.paramSqlNames[i]} = ?',
      'id = ?',
    ].join(' AND ');
    final row = await reader.getOptional(
      'SELECT data FROM ${entry.table} WHERE $where',
      [...key.paramValues, key.id],
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

  /// Records [path] (with result position [position]) as a document `getAll`
  /// still needs from SQLite: validates the path against [entry]'s pattern
  /// exactly like [_readDoc] does, and collapses duplicate references onto
  /// one fetch whose snapshot every position shares.
  void _addPendingDoc(
    Map<String, _PendingDoc> pending,
    RegistryEntry entry,
    String path,
    int position,
  ) {
    final existing = pending[path];
    if (existing != null) {
      existing.positions.add(position);
      return;
    }
    final key = entry.scopeKeyOf(path);
    if (key == null) {
      throw ArgumentError.value(
        path,
        'ref',
        'Not a document path of collection ${entry.adapter.pattern}',
      );
    }
    pending[path] = _PendingDoc(entry, path, key)..positions.add(position);
  }

  /// Fetches every [pending] document from [reader] and fills [snapshots]:
  /// documents grouped per table, one statement per chunk of
  /// [Cocoon.getAllChunkKeys] scope keys — a 1,000-id call costs one round
  /// trip per table per chunk instead of one per document. The caller runs
  /// all of a call's statements inside one read transaction, so the chunks
  /// answer from one snapshot. Rows decode per document and, with
  /// [cachePut], populate the hot-document cache exactly like [_readDoc].
  Future<void> _fillFromTables<T extends Object>(
    CocoonRead reader,
    Map<String, _PendingDoc> pending,
    List<DocRef<T>> refs,
    List<DocSnapshot<T>?> snapshots, {
    required bool cachePut,
  }) async {
    final byTable = <RegistryEntry, List<_PendingDoc>>{};
    for (final doc in pending.values) {
      (byTable[doc.entry] ??= []).add(doc);
    }
    for (final entry in byTable.keys) {
      final docs = byTable[entry]!;
      for (final chunk in buildGetAllChunks(
        entry,
        [
          for (final doc in docs)
            (
              path: doc.path,
              paramValues: doc.key.paramValues,
              id: doc.key.id,
            ),
        ],
      )) {
        final rows = await reader.getAll(chunk.sql, chunk.args);
        final rowOfPath = {
          for (final row in rows) entry.pathOfKeyRow(row): row,
        };
        for (var i = 0; i < chunk.paths.length; i++) {
          final path = chunk.paths[i];
          final row = rowOfPath[path];
          if (row == null) {
            continue; // a missing document answers null at its position
          }
          final value = entry.adapter.decode(row['data']! as Uint8List) as T;
          if (cachePut) {
            _cache.put(path, value);
          }
          // Duplicate references share one snapshot: their refs are equal
          // (a DocRef compares by path) and DocSnapshot is immutable.
          final positions = pending[path]!.positions;
          final snapshot = DocSnapshot<T>(refs[positions.first], value);
          for (final position in positions) {
            snapshots[position] = snapshot;
          }
        }
      }
    }
  }

  @override
  @internal
  List<String> paramValuesInOrder(RegistryEntry entry, CollectionPath path) {
    final values = entry.adapter.pattern.match(path.path);
    if (values == null) {
      throw ArgumentError.value(
        path.path,
        'path',
        'Not a collection path of ${entry.adapter.pattern}',
      );
    }
    return [for (final name in entry.paramNames) values[name]!];
  }

  // -- Schema reconciliation ------------------------------------------------

  /// Compares the file's storage format version with [storageFormatVersion]
  /// and rebuilds an older file table by table (see [FormatMigrator]).
  ///
  /// A file written by a NEWER storage format refuses to open with a
  /// [StorageFormatTooNewException]. A fresh database has no format row
  /// yet; the rebuild finds no tables carrying the old layout and just
  /// stamps the current version.
  ///
  /// Returns whether this open actually converted an older layout (as
  /// opposed to a fresh create or an already-current file): only that open
  /// considers the post-upgrade compaction.
  static Future<bool> _applyStorageFormat(
    CocoonTx tx, {
    required void Function(int done, int total)? onMigrationProgress,
    required String databasePath,
  }) async {
    final row = await tx.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      [formatVersionMetaKey],
    );
    final stored = row == null
        ? 0
        : switch (int.tryParse(row['value']! as String)) {
            final int version? => version,
            null => throw StateError(
              'The database\'s $metaTableName row '
              '"$formatVersionMetaKey" does not parse as an integer: '
              '${row['value']}',
            ),
          };
    if (stored > storageFormatVersion) {
      throw StorageFormatTooNewException(
        path: databasePath,
        formatVersion: stored,
        maxSupported: storageFormatVersion,
      );
    }
    if (stored == storageFormatVersion) {
      return false;
    }
    final rebuilt = await FormatMigrator.migrateInTx(
      tx,
      onProgress: onMigrationProgress,
    );
    // An older format row means a real upgrade; rebuilt tables also cover
    // files that predate the format row itself.
    return rebuilt > 0 || stored > 0;
  }

  /// Reclaims the freelist pages a storage-format upgrade left behind, once,
  /// after the open transaction committed.
  ///
  /// Runs `VACUUM` only when more than a fifth of the file sits on the
  /// freelist. Every failure is caught and reported through
  /// [onCompactionFailed] — a full disk (VACUUM needs about the file size in
  /// free space) must not fail the open; the file stays as the upgrade made
  /// it and the next `backupTo` compacts instead.
  Future<void> _compactAfterFormatUpgrade(
    CocoonExecutor executor,
  ) async {
    // The freelist share above which the post-upgrade compaction runs: the
    // check is `freelist * denominator > pages`, so the default (5) compacts
    // when MORE than a fifth of the file is reclaimable.
    const compactFreelistDenominator = 5;
    try {
      final freeRow = await executor.getOptional('PRAGMA freelist_count');
      final pagesRow = await executor.getOptional('PRAGMA page_count');
      final free = freeRow?['freelist_count'] as int? ?? 0;
      final pages = pagesRow?['page_count'] as int? ?? 0;
      if (pages <= 0 || free * compactFreelistDenominator <= pages) {
        return;
      }
      await executor.execute('VACUUM');
    } on Object catch (error) {
      // A full disk (VACUUM needs about the file size in free space) must
      // not fail the open; reported through CocoonOptions.onCompactionFailed
      // by the wiring that built this runtime.
      _onCompactionFailed?.call(error);
    }
  }

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

  /// Returns the database's instance id, creating one (a fresh
  /// [newDocId]) when the file predates instance ids, inside the open
  /// transaction so creation is atomic with the rest of the open.
  static Future<String> _ensureInstanceId(CocoonTx tx) async {
    final row = await tx.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      [instanceIdMetaKey],
    );
    final stored = row?['value'];
    if (stored is String && stored.isNotEmpty) {
      return stored;
    }
    final id = newDocId();
    await tx.execute(
      'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
      [instanceIdMetaKey, id],
    );
    return id;
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
        'WHERE ${[...entry.paramSqlNames, 'id'].map((name) => '$name = ?').join(' AND ')}';
    var lastRowId = 0;
    while (true) {
      final rows = await tx.getAll(
        'SELECT rowid, ${[...entry.paramSqlNames, 'id', 'data'].join(', ')} '
        'FROM ${entry.table} WHERE rowid > ? ORDER BY rowid '
        'LIMIT $backfillBatchSize',
        [lastRowId],
      );
      if (rows.isEmpty) {
        break;
      }
      final updates = <List<Object?>>[];
      for (final row in rows) {
        final value = entry.adapter.decode(row['data'] as Uint8List);
        updates.add([
          for (final field in addedFields) field.sqlOf(value),
          for (final name in entry.paramSqlNames) row[name]! as String,
          row['id']! as String,
        ]);
        lastRowId = row['rowid']! as int;
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

  @override
  Future<int> get debugCacheLength async => _cache.length;

  /// Puts a decoded value into the hot-document cache (the auto runtime's
  /// helper-routed reads populate the cache exactly like [_readDoc]).
  @internal
  void cachePut(String path, Object value) => _cache.put(path, value);

  @override
  Future<int> get debugWatcherCount async => _watchHub.length;
}

/// One document a `getAll` call still needs from SQLite: its registry entry,
/// its path (the cache key and identity) and the result positions sharing
/// it.
final class _PendingDoc {
  _PendingDoc(this.entry, this.path, this.key);

  final RegistryEntry entry;
  final String path;
  final ({List<String> paramValues, String id}) key;
  final List<int> positions = [];
}

/// One pending document in the shared `getAll` chunk plan: its path and its
/// scope-key values.
typedef GetAllPendingDoc = ({
  String path,
  List<String> paramValues,
  String id,
});

/// One chunk of a `getAll` plan: the statement, its bound arguments and the
/// document paths the chunk answers (in chunk order). Built once and shared
/// by the local engine and the auto mode's helper routing, so the statement
/// shape can never drift between them.
@internal
typedef GetAllChunk = ({
  RegistryEntry entry,
  String sql,
  List<Object?> args,
  List<String> paths,
});

/// Groups [docs] by table and chunks each group into one statement per
/// [chunkKeys] scope keys: a root collection keys by id alone
/// (`id IN (...)`), a subcollection by the full scope key with row values
/// (`(p_params, id) IN (VALUES ...)`).
@internal
List<GetAllChunk> buildGetAllChunks(
  RegistryEntry entry,
  List<GetAllPendingDoc> docs, {
  int chunkKeys = Cocoon.getAllChunkKeys,
}) {
  final keyColumns = entry.keyColumns;
  final keyCount = keyColumns.length;
  final chunks = <GetAllChunk>[];
  for (var start = 0; start < docs.length; start += chunkKeys) {
    final chunk = docs.sublist(
      start,
      start + chunkKeys > docs.length ? docs.length : start + chunkKeys,
    );
    final args = <Object?>[];
    for (final doc in chunk) {
      args.addAll(doc.paramValues);
      args.add(doc.id);
    }
    final String sql;
    if (keyCount == 1) {
      sql =
          'SELECT id, data FROM ${entry.table} '
          'WHERE id IN (${List.filled(chunk.length, '?').join(', ')})';
    } else {
      final tuple = '(${List.filled(keyCount, '?').join(', ')})';
      sql =
          'SELECT ${keyColumns.join(', ')}, data FROM ${entry.table} '
          'WHERE (${keyColumns.join(', ')}) IN (VALUES '
          '${List.filled(chunk.length, tuple).join(', ')})';
    }
    chunks.add((
      entry: entry,
      sql: sql,
      args: args,
      paths: [for (final doc in chunk) doc.path],
    ));
  }
  return chunks;
}
