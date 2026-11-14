/// The auto isolate mode: ONE engine, home on the caller — the write lock,
/// hot-document cache, watch notifier, change log and the transaction guard
/// are the local engine's, unchanged — plus ONE helper isolate per database
/// that never writes:
///
/// - it serves heavy reads from its own read-only SQLite connection
///   (execute + decode in the helper; the caller planned the query, so the
///   index rule and the debug scanAndWarn decision stay the caller's), and
/// - it does the CPU side of heavy writes: it encodes documents and builds
///   prepared row arguments for `bulkWriter()` chunks and big batches,
///   which the caller's single writer executes.
///
/// Routing is the deterministic [AutoRouter] rule set (thresholds from
/// [CocoonAutoThresholds]); transactions, doc gets/sets/deletes and counts
/// always run inline with zero round trips. A crashed helper degrades to
/// inline execution with one logged warning — auto never bricks the
/// database.
library;

import 'dart:async';
import 'dart:developer';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../path.dart';
import '../../cursor.dart';
import '../adapter.dart';
import '../aggregate.dart';
import '../backup.dart';
import '../batch.dart' show BatchOp, BatchOpKind, LocalWriteBatch, WriteBatch;
import '../bulk_writer.dart';
import '../changes.dart';
import '../cocoon.dart';
import '../executor.dart';
import '../local_runtime.dart';
import '../query.dart';
import '../refs.dart';
import '../runtime.dart';
import '../schema_sql.dart';
import '../sqlite_executor.dart';
import '../transaction_guard.dart';
import '../watch.dart';
import '../write_buffer.dart';
import 'error_envelope.dart';
import 'isolate_options.dart';

/// Spawns the auto mode's helper isolate and returns its link, or `null`
/// when the spawn failed (auto degrades to inline and logs why).
@internal
Future<AutoHelperLink?> spawnAutoHelper(
  String path,
  List<CollectionAdapter<Object?>> collections,
) async {
  try {
    return await AutoHelperLink.spawn(path, collections);
  } on Object catch (error, stackTrace) {
    log(
      'Cocoon auto mode: the helper isolate could not start ($error); '
      'every read and encode runs inline on the caller',
      name: 'cocoon',
      level: 900, // WARNING
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// The helper isolate entry: opens a read-only executor over the database
/// file and its own registry, then serves read-and-decode and encode
/// requests until the port closes.
@internal
void cocoonAutoHelperMain(AutoHelperInit init) {
  final events = init.events;
  unawaited(() async {
    final executor = ReadOnlySqliteExecutor(init.path);
    final registry = SchemaRegistry.build(init.collections);
    final requests = ReceivePort();
    events.send(_AutoHelperReady(requests.sendPort));
    requests.listen((message) async {
      switch (message) {
        case _AutoReadRequest(
          :final id,
          :final entryIndex,
          :final sql,
          :final args,
        ):
          try {
            final entry = registry.entries[entryIndex];
            final rows = await executor.getAll(sql, args);
            final values = <Object?>[
              // A group-by row has no `data` column: only query and
              // getAll rows carry a document to decode.
              for (final row in rows)
                if (row['data'] == null)
                  null
                else
                  entry.adapter.decode(row['data']! as Uint8List),
            ];
            events.send(AutoResponse(id, (rows, values), null));
          } on Object catch (error, stackTrace) {
            events.send(
              AutoResponse(id, null, envelopeFrom(error, stackTrace)),
            );
          }
        case _AutoPrepareRequest(:final id, :final ops):
          try {
            final prepared = <List<Object?>?>[];
            for (final (kind, entryIndex, path, value) in ops) {
              if (kind == BatchOpKind.delete) {
                prepared.add(null);
                continue;
              }
              final entry = registry.entries[entryIndex];
              final values = entry.adapter.pattern.match(path.collection.path);
              if (values == null) {
                throw ArgumentError.value(
                  path.path,
                  'ref',
                  'Not a document path of collection ${entry.adapter.pattern}',
                );
              }
              prepared.add([
                entry.adapter.encode(value!),
                for (final column in entry.fieldColumns)
                  _columnSqlOf(column, value),
                ...[for (final name in entry.paramNames) values[name]!],
                path.id,
              ]);
            }
            events.send(AutoResponse(id, prepared, null));
          } on Object catch (error, stackTrace) {
            events.send(
              AutoResponse(id, null, envelopeFrom(error, stackTrace)),
            );
          }
        default:
          break;
      }
    });
  }());
}

/// The helper-side `column.sqlOf(value)` through the registry's covariant
/// column view (the same dynamic call the inspector makes).
Object? _columnSqlOf(FieldColumn<Object?, Object?> column, Object? value) {
  final dynamic dynamicColumn = column;
  return dynamicColumn.sqlOf(value) as Object?;
}

/// The helper's init payload. Adapters travel as registry entry INDICES
/// (the helper builds its own registry from the same collections, in the
/// same order — the indices are stable on both sides and keep messages
/// small).
@internal
final class AutoHelperInit {
  const AutoHelperInit(this.events, this.path, this.collections);

  final SendPort events;
  final String path;
  final List<CollectionAdapter<Object?>> collections;
}

final class _AutoHelperReady {
  const _AutoHelperReady(this.requests);

  final SendPort requests;
}

final class _AutoHelperFailed {
  const _AutoHelperFailed(this.error);

  final ErrorEnvelope error;
}

/// A planned read for the helper: the registry entry index plus the
/// statement.
final class _AutoReadRequest {
  const _AutoReadRequest(this.id, this.entryIndex, this.sql, this.args);

  final int id;
  final int entryIndex;
  final String sql;
  final List<Object?> args;
}

/// A chunk of writes to prepare: (kind, registry entry index, path, value)
/// per position.
final class _AutoPrepareRequest {
  const _AutoPrepareRequest(this.id, this.ops);

  final int id;
  final List<(BatchOpKind, int, DocPath, Object?)> ops;
}

final class AutoResponse {
  const AutoResponse(this.id, this.result, this.error);

  final int id;
  final Object? result;
  final ErrorEnvelope? error;
}

/// The helper link on the caller side: spawn handshake, request ids and the
/// crash wiring. A dead helper never fails a user call — the runtime
/// degrades to inline execution.
@internal
final class AutoHelperLink {
  AutoHelperLink._(
    this._isolate,
    this._requests,
    this._events,
    this._subscription,
  ) {
    // The helper's error and exit listeners take a SendPort each. They are
    // fields because they must CLOSE when the link dies — an open
    // ReceivePort keeps the caller's isolate (and its host process) from
    // ever exiting.
    _helperErrors = ReceivePort();
    _isolate.addErrorListener(_helperErrors.sendPort);
    _helperErrors.listen((message) {
      _crash();
    });
    _helperExits = ReceivePort();
    _isolate.addOnExitListener(_helperExits.sendPort);
    _helperExits.listen((message) {
      _crash();
    });
  }

  static Future<AutoHelperLink> spawn(
    String path,
    List<CollectionAdapter<Object?>> collections,
  ) async {
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    AutoHelperLink? link;
    final subscription = events.listen((message) {
      switch (message) {
        case _AutoHelperReady(:final requests):
          if (!ready.isCompleted) {
            ready.complete(requests);
          }
        case _AutoHelperFailed(:final error):
          if (!ready.isCompleted) {
            ready.completeError(
              error.rebuild(),
              StackTrace.fromString(error.stackTraceText),
            );
          } else {
            link?._crash();
          }
        case AutoResponse():
          link?._respond(message);
        default:
          break;
      }
    });
    final isolate = await Isolate.spawn(
      cocoonAutoHelperMain,
      AutoHelperInit(events.sendPort, path, collections),
      debugName: 'cocoon-auto-helper',
    );
    try {
      final requests = await ready.future.timeout(const Duration(seconds: 60));
      link = AutoHelperLink._(isolate, requests, events, subscription);
      return link;
    } on Object {
      await subscription.cancel();
      events.close();
      isolate.kill(priority: Isolate.beforeNextEvent);
      rethrow;
    }
  }

  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _events;
  final StreamSubscription<Object?> _subscription;

  /// The helper's error and exit listeners; closed whenever the link dies
  /// (crash or close) so no open port keeps the caller's isolate alive.
  late final ReceivePort _helperErrors;
  late final ReceivePort _helperExits;

  var _nextId = 0;
  final Map<int, Completer<Object?>> _pending = {};
  bool _dead = false;

  /// Whether the helper is gone; the runtime routes inline from then on.
  bool get isDead => _dead;

  /// The helper isolate's handle, for the degrade tests: killing it must
  /// never fail a user call — the runtime degrades to inline.
  @visibleForTesting
  Isolate get debugHelperIsolate => _isolate;

  Future<T> request<T>(Object Function(int id) build) {
    if (_dead) {
      throw StateError('The auto helper isolate is gone');
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _requests.send(build(id));
    // The value cast, not a future cast: the pending map is heterogeneous
    // (Completer<Object?>), and a Future<Object?> is not itself a Future<T>.
    return completer.future.then((value) => value as T);
  }

  void _respond(AutoResponse response) {
    final completer = _pending.remove(response.id);
    if (completer == null) {
      return;
    }
    final error = response.error;
    if (error != null) {
      completer.completeError(
        error.rebuild(),
        StackTrace.fromString(error.stackTraceText),
      );
      return;
    }
    completer.complete(response.result);
  }

  void _crash() {
    if (_dead) {
      return;
    }
    _dead = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('The auto helper isolate is gone'));
      }
    }
    _pending.clear();
    unawaited(_subscription.cancel());
    _events.close();
    _helperErrors.close();
    _helperExits.close();
  }

  Future<void> close() async {
    if (_dead) {
      return;
    }
    _dead = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('The database was closed'));
      }
    }
    _pending.clear();
    await _subscription.cancel();
    _events.close();
    _helperErrors.close();
    _helperExits.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// The auto mode's runtime: the local engine for everything small (and for
/// every write transaction), the helper for reads above the thresholds and
/// for heavy encodes. All counters feed [isolateStats].
@internal
final class AutoCocoonRuntime implements CocoonRuntime {
  /// Builds the runtime over the engine home [_local]; [helper] may be
  /// `null` (the helper failed to spawn) — everything then runs inline.
  AutoCocoonRuntime(this._local, this._thresholds, this._helper)
    : _stats = CocoonIsolateStats();

  final LocalCocoonRuntime _local;
  final CocoonAutoThresholds _thresholds;
  AutoHelperLink? _helper;

  final CocoonIsolateStats _stats;

  /// Marks the helper dead after a crash and logs one warning.
  void _degradeHelper(Object error, StackTrace stackTrace) {
    if (_helper == null) {
      return;
    }
    _helper = null;
    log(
      'Cocoon auto mode: the helper isolate failed ($error); every read and '
      'encode now runs inline on the caller',
      name: 'cocoon',
      level: 900, // WARNING
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  late Cocoon host;

  @override
  SchemaRegistry get registry => _local.registry;

  @override
  WatchHub get watchHub => _local.watchHub;

  @override
  bool get isLocal => true;

  @override
  String get isolateModeName => host.isolateModeName;

  @override
  CocoonIsolateStats get isolateStats => _stats;

  /// The helper isolate's handle, for the degrade tests: killing it must
  /// never fail a user call — the runtime degrades to inline. `null` when
  /// the helper never spawned or already degraded.
  @visibleForTesting
  Isolate? get debugHelperIsolate => _helper?.debugHelperIsolate;

  @override
  CocoonExecutor get executor => _local.executor;

  @override
  WriteBatch createWriteBatch(Cocoon db) => LocalWriteBatch(db);

  @override
  BulkWriter createBulkWriter(Cocoon db, BulkWriterOptions options) =>
      LocalBulkWriter(db, options, _prepareChunk);

  // -- Always inline: doc ops, counts, aggregates, watches, transactions ----

  @override
  Future<DocSnapshot<T>?> getDoc<T extends Object>(DocRef<T> ref) {
    _stats.inlineCalls++;
    return _local.getDoc<T>(ref);
  }

  @override
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value) {
    _stats.inlineCalls++;
    return _local.putDoc<T>(ref, value);
  }

  @override
  Future<DocRef<T>> addDoc<T extends Object>(CollectionRef<T> ref, T value) {
    _stats.inlineCalls++;
    return _local.addDoc<T>(ref, value);
  }

  @override
  Future<void> deleteDoc(DocRef<Object> ref) {
    _stats.inlineCalls++;
    return _local.deleteDoc(ref);
  }

  @override
  Future<int> runCount<T extends Object>(CocoonQuery<T> query) {
    _stats.inlineCalls++;
    return _local.runCount<T>(query);
  }

  @override
  Future<AggregateQuerySnapshot<T>> runAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) {
    _stats.inlineCalls++;
    return _local.runAggregate<T>(aggregate);
  }

  @override
  Stream<DocSnapshot<T>?> watchDoc<T extends Object>(DocRef<T> ref) =>
      _local.watchDoc<T>(ref);

  @override
  Stream<QueryPage<T>> watchQuery<T extends Object>(CocoonQuery<T> query) =>
      _local.watchQuery<T>(query);

  @override
  Stream<AggregateQuerySnapshot<T>> watchAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) => _local.watchAggregate<T>(aggregate);

  @override
  Stream<List<AggregateGroup<T>>> watchGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) => _local.watchGroupAggregate<T>(aggregate);

  @override
  Future<R> writeTx<R>(
    Future<R> Function(CocoonWriteTx wtx) body, {
    bool logChanges = true,
    TransactionScope? txScope,
  }) => _local.writeTx<R>(body, logChanges: logChanges, txScope: txScope);

  @override
  Future<R> runTransactionBody<R>(
    Future<R> Function(CocoonWriteTx tx) body, {
    TransactionScope? txScope,
  }) => _local.runTransactionBody<R>(body, txScope: txScope);

  // -- Routed reads ---------------------------------------------------------

  @override
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  ) async {
    if (AutoRouter.getAll(_thresholds, refs.length) == AutoRoute.inline ||
        _helper == null) {
      _stats.inlineCalls++;
      return _local.getAll<T>(refs);
    }
    return _getAllViaHelper<T>(refs);
  }

  @override
  Future<QueryPage<T>> runQuery<T extends Object>(CocoonQuery<T> query) =>
      _runQueryTyped<T>(query, withBytes: false).then((r) => r.$1);

  @override
  Future<(QueryPage<T>, List<Uint8List>)> runQueryWithBytes<T extends Object>(
    CocoonQuery<T> query,
  ) => _runQueryTyped<T>(query, withBytes: true);

  Future<(QueryPage<T>, List<Uint8List>)> _runQueryTyped<T extends Object>(
    CocoonQuery<T> query, {
    required bool withBytes,
  }) async {
    final spec = query.spec;
    if (AutoRouter.query(_thresholds, spec.limit) == AutoRoute.inline ||
        _helper == null) {
      _stats.inlineCalls++;
      return _local.runQueryWithBytes<T>(query);
    }
    // Plan on the caller (the index rule and the debug scanAndWarn decision
    // are caller state), wait for deferred bulk-writer indexes, then have
    // the helper execute and decode.
    final entry = _local.registry.entryFor(spec.adapter);
    final plan = planQuery(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: spec.limit,
      cursor: spec.startAfter,
      fullScan: spec.fullScan,
      onMissingIndex: _local.acceptMissingIndexScan,
    );
    await _local.waitForBulkIndexes(plan.servingIndex);
    final (rows, values) = await _readViaHelper(entry, plan.sql, plan.args);
    final limit = spec.limit;
    var pageRows = rows;
    String? nextCursor;
    if (limit != null && rows.length > limit) {
      pageRows = rows.sublist(0, limit);
      final last = pageRows.last;
      final keys = [for (final column in plan.cursorColumns) last[column]!];
      nextCursor = CursorCodec.encode(plan.fingerprint, keys);
    }
    final docs = <DocSnapshot<T>>[
      for (var i = 0; i < pageRows.length; i++)
        _snapshotOf<T>(entry, pageRows[i], values[i]),
    ];
    final bytes = <Uint8List>[
      for (final row in pageRows) row['data']! as Uint8List,
    ];
    return (QueryPage<T>(docs, nextCursor), bytes);
  }

  @override
  Future<List<AggregateGroup<T>>> runGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) async {
    final spec = aggregate.query.spec;
    if (AutoRouter.groupBy(_thresholds, aggregate.maxGroups) ==
            AutoRoute.inline ||
        _helper == null) {
      _stats.inlineCalls++;
      return _local.runGroupAggregate<T>(aggregate);
    }
    final entry = _local.registry.entryFor(spec.adapter);
    final plan = planGroupAggregate(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: aggregate.maxGroups,
      fullScan: spec.fullScan,
      keys: aggregate.keys,
      specs: aggregate.specs,
      onMissingIndex: _local.acceptMissingIndexScan,
    );
    await _local.waitForBulkIndexes(plan.servingIndex);
    final (rows, _) = await _readViaHelper(entry, plan.sql, plan.args);
    return aggregateGroupsFromRows<T>(aggregate.keys, aggregate.specs, rows);
  }

  // -- Routed writes --------------------------------------------------------

  @override
  Future<void> commitBatchOps(List<BatchOp> ops) async {
    if (AutoRouter.batch(_thresholds, ops.length) == AutoRoute.inline ||
        _helper == null) {
      _stats.inlineCalls++;
      return _local.commitBatchOps(ops);
    }
    final prepared = await _prepareChunk(ops);
    await _local.writeTx<void>((wtx) async {
      // The local runtime's transactions are always the buffered WriteTx;
      // putPrepared is its encode-ahead path.
      final buffered = wtx as WriteTx;
      for (var i = 0; i < ops.length; i++) {
        final op = ops[i];
        switch (op.kind) {
          case BatchOpKind.set:
            final args = prepared?[i];
            if (args != null) {
              await buffered.putPrepared(
                op.ref,
                _local.registry.entryFor(op.ref.adapter),
                args.$2,
              );
            } else {
              await buffered.put(op.ref, op.value!);
            }
          case BatchOpKind.update:
            final args = prepared?[i];
            if (args != null) {
              await buffered.putPrepared(
                op.ref,
                _local.registry.entryFor(op.ref.adapter),
                args.$2,
                update: true,
              );
            } else {
              await buffered.put(op.ref, op.value!, update: true);
            }
          case BatchOpKind.delete:
            await buffered.delete(op.ref);
        }
      }
    });
  }

  /// Encodes a chunk's writes in the helper: one [PreparedWrite] per
  /// set/update position, `null` at deletes. Falls back to `null` (encode
  /// inline, as always) when the helper is gone.
  Future<List<PreparedWrite?>?> _prepareChunk(List<BatchOp> chunk) async {
    final helper = _helper;
    if (helper == null || chunk.isEmpty) {
      return null;
    }
    try {
      final prepared = await helper.request<List<List<Object?>?>>(
        (id) => _AutoPrepareRequest(id, [
          for (final op in chunk)
            (op.kind, _entryIndex(op.ref.adapter), op.ref.path, op.value),
        ]),
      );
      _stats.helperCalls++;
      var bytesMoved = 0;
      for (final args in prepared) {
        final data = args?.firstOrNull;
        if (data is Uint8List) {
          bytesMoved += data.length;
        }
      }
      _stats.helperBytesMoved += bytesMoved;
      return [
        for (var i = 0; i < chunk.length; i++)
          prepared[i] == null ? null : (chunk[i].ref, prepared[i]!),
      ];
    } on Object catch (error, stackTrace) {
      _degradeHelper(error, stackTrace);
      return null;
    }
  }

  // -- Helper plumbing ------------------------------------------------------

  /// The index of [entry] in the registry's registration order — the stable
  /// identity both sides resolve adapters by.
  int _entryIndex(CollectionAdapter<Object?> adapter) {
    final entry = _local.registry.entryFor(adapter);
    return _local.registry.entries.indexOf(entry);
  }

  /// Executes [sql] on the helper and returns its raw rows with the decoded
  /// values aligned per row. Falls back to the local engine when the helper
  /// is gone (degrade, log once, keep serving).
  Future<(List<Map<String, Object?>>, List<Object?>)> _readViaHelper(
    RegistryEntry entry,
    String sql,
    List<Object?> args,
  ) async {
    final helper = _helper;
    if (helper != null) {
      try {
        final (rows, values) = await helper
            .request<(List<Map<String, Object?>>, List<Object?>)>(
              (id) => _AutoReadRequest(
                id,
                _local.registry.entries.indexOf(entry),
                sql,
                args,
              ),
            );
        _stats.helperCalls++;
        var bytesMoved = 0;
        for (final row in rows) {
          final data = row['data'];
          if (data is Uint8List) {
            bytesMoved += data.length;
          }
        }
        _stats.helperBytesMoved += bytesMoved;
        return (rows, values);
      } on Object catch (error, stackTrace) {
        _degradeHelper(error, stackTrace);
      }
    }
    _stats.inlineCalls++;
    final rows = await _local.executor.getAll(sql, args);
    return (
      rows,
      [
        for (final row in rows)
          if (row['data'] == null)
            null
          else
            entry.adapter.decode(row['data']! as Uint8List),
      ],
    );
  }

  Future<List<DocSnapshot<T>?>> _getAllViaHelper<T extends Object>(
    List<DocRef<T>> refs,
  ) async {
    final snapshots = List<DocSnapshot<T>?>.filled(refs.length, null);
    final positionsByPath = <String, List<int>>{};
    final byTable = <RegistryEntry, List<GetAllPendingDoc>>{};
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      final entry = _local.registry.entryFor(ref.adapter);
      final key = entry.scopeKeyOf(ref.path.path);
      if (key == null) {
        throw ArgumentError.value(
          ref.path.path,
          'ref',
          'Not a document path of collection ${entry.adapter.pattern}',
        );
      }
      (positionsByPath[ref.path.path] ??= []).add(i);
      (byTable[entry] ??= []).add((
        path: ref.path.path,
        paramValues: key.paramValues,
        id: key.id,
      ));
    }
    for (final entry in byTable.keys) {
      for (final chunk in buildGetAllChunks(entry, byTable[entry]!)) {
        final (rows, values) = await _readViaHelper(
          entry,
          chunk.sql,
          chunk.args,
        );
        final valueOfPath = <String, Object?>{
          for (var i = 0; i < rows.length; i++)
            entry.pathOfKeyRow(rows[i]): values[i],
        };
        for (var i = 0; i < chunk.paths.length; i++) {
          final path = chunk.paths[i];
          final value = valueOfPath[path];
          if (value == null) {
            continue; // a missing document answers null at its position
          }
          _local.cachePut(path, value);
          // Duplicate references share one snapshot: their refs are equal
          // (a DocRef compares by path) and DocSnapshot is immutable.
          final positions = positionsByPath[path]!;
          final snapshot = DocSnapshot<T>(refs[positions.first], value as T);
          for (final position in positions) {
            snapshots[position] = snapshot;
          }
        }
      }
    }
    return snapshots;
  }

  DocSnapshot<T> _snapshotOf<T extends Object>(
    RegistryEntry entry,
    Map<String, Object?> row,
    Object? value,
  ) {
    final params = <String, String>{
      for (var i = 0; i < entry.paramNames.length; i++)
        entry.paramNames[i]: row[entry.paramSqlNames[i]]! as String,
    };
    final collectionPath = entry.adapter.pattern.resolve(params);
    final docPath = collectionPath.doc(row['id']! as String);
    return DocSnapshot<T>(
      DocRef<T>(host, entry.adapter as CollectionAdapter<T>, docPath),
      value! as T,
    );
  }

  /// The rest forwards to the engine home -----------------------------------

  @override
  Future<List<Change>> changesSince(int seq, {int limit = 1000}) =>
      _local.changesSince(seq, limit: limit);

  @override
  Future<int> earliestChangeSeq() => _local.earliestChangeSeq();

  @override
  Future<int> lastChangeSeq() => _local.lastChangeSeq();

  @override
  Future<int> pruneChanges({required int upToSeq}) =>
      _local.pruneChanges(upToSeq: upToSeq);

  @override
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonRead reader,
    DocRef<T> ref,
  ) => _local.readDocInTx<T>(reader, ref);

  @override
  Future<List<DocSnapshot<T>?>> getAllDocsInTx<T extends Object>(
    CocoonRead reader,
    List<DocRef<T>> refs,
  ) => _local.getAllDocsInTx<T>(reader, refs);

  @override
  Future<List<(String, String)>> deleteRow(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
    String id,
  ) => _local.deleteRow(tx, entry, paramValues, id);

  @override
  Future<List<(String, String)>> deleteScopePrefix(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
  ) => _local.deleteScopePrefix(tx, entry, paramValues);

  @override
  bool get keepsChanges => _local.keepsChanges;

  @override
  List<String> paramValuesInOrder(RegistryEntry entry, CollectionPath path) =>
      _local.paramValuesInOrder(entry, path);

  @override
  Future<BackupInfo> backupTo(String path, {required bool overwrite}) =>
      _local.backupTo(path, overwrite: overwrite);

  @override
  Future<void> close() async {
    final helper = _helper;
    _helper = null;
    await _local.close();
    await helper?.close();
  }

  @override
  Future<int> get debugCacheLength => _local.debugCacheLength;

  @override
  Future<int> get debugWatcherCount => _local.debugWatcherCount;

  @override
  List<MissingIndexReport> get missingIndexes => _local.missingIndexes;

  @override
  void noteBulkWriterActive() => _local.noteBulkWriterActive();

  @override
  void noteBulkWriterClosed() => _local.noteBulkWriterClosed();

  @override
  void noteIndexesDeferred(Iterable<String> indexNames) =>
      _local.noteIndexesDeferred(indexNames);

  @override
  void noteIndexesRestored(Iterable<String> indexNames) =>
      _local.noteIndexesRestored(indexNames);

  @override
  Future<void> waitForBulkIndexes(String? servingIndex) =>
      _local.waitForBulkIndexes(servingIndex);
}
