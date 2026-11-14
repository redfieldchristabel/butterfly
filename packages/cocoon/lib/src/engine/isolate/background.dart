/// The background isolate mode's caller side: the host that spawns the
/// worker ([CocoonIsolateHost.open] for [CocoonIsolate.background]), the
/// proxy runtime that turns every engine call into one message, the
/// transaction message session, the shipping bulk writer and the proxy
/// watch streams.
///
/// What stays on the caller: the public API objects (refs, queries, specs —
/// all built here), the transaction guard (the body is user code),
/// migration progress and compaction-failure callbacks, and the file-level
/// helpers ([Cocoon.restoreBackup], [Cocoon.inspectBackup]). Everything the
/// engine does — decode, encode, planning, the write lock, the
/// hot-document cache, watch re-reads and dedupe — runs in the worker.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../migration.dart';
import '../../path.dart';
import '../../schema.dart';
import '../adapter.dart';
import '../aggregate.dart';
import '../batch.dart';
import '../backup.dart';
import '../bulk_writer.dart';
import '../changes.dart';
import '../cocoon.dart';
import '../executor.dart';
import '../query.dart';
import '../refs.dart';
import '../runtime.dart';
import '../schema_sql.dart';
import '../transaction_guard.dart';
import '../watch.dart';
import 'error_envelope.dart';
import 'isolate_options.dart';
import 'messages.dart';
import 'worker.dart';

/// Spawns the worker isolate the background mode needs and wires its
/// facade. The auto mode's engine stays on the caller; the facade's
/// `openAutoOnCaller` builds it (the helper spawn lives in `auto.dart`).
@internal
abstract final class CocoonIsolateHost {
  /// Opens [path] in [options.isolate] mode. Only background reaches here:
  /// the caller mode opens directly, auto mode opens through the facade's
  /// `openAutoOnCaller`, and openWith rejects isolate modes.
  static Future<Cocoon> open(
    String path, {
    required List<CollectionAdapter<Object?>> collections,
    required CocoonOptions options,
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
  }) async {
    switch (options.isolate) {
      case CocoonIsolate.caller || CocoonIsolate.auto:
        throw StateError(
          'unreachable: the caller mode opens directly; auto mode opens '
          'through Cocoon.openAutoOnCaller',
        );
      case CocoonIsolate.background:
        break;
    }
    final registry = SchemaRegistry.build(collections);
    final link = await _WorkerLink.spawn(
      path: path,
      collections: collections,
      options: _optionsForWorker(options),
      schemaVersion: schemaVersion,
      migrations: migrations,
      schemaLock: schemaLock,
      reportCompactionFailures: options.onCompactionFailed != null,
      onMigrationProgress: onMigrationProgress,
      onCompactionFailed: options.onCompactionFailed,
    );
    final db = Cocoon.isolate(
      registry: registry,
      databasePath: path,
      schemaLock: schemaLock,
      instanceId: link.instanceId,
      isolateMode: CocoonIsolate.background,
    );
    db.runtime = BackgroundCocoonRuntime._(link, registry, link.instanceId);
    db.runtime.host = db;
    Cocoon.registerOpenPath(path);
    // No inspector attach here: the proxy's executor throws and its watch
    // hub is absent, so caller-side handlers could not serve this database.
    // The worker's local open attaches the inspector in the worker isolate
    // (see worker.dart's library doc), and the DevTools extension discovers
    // isolates that answer `ext.cocoon.listDatabases`.
    return db;
  }
}

/// The message channel to one worker isolate: spawn handshake, request ids,
/// pending responses, watch feeds and the crash wiring.
final class _WorkerLink {
  _WorkerLink._(
    this._isolate,
    this._requests,
    this._events,
    this._subscription, {
    required this.instanceId,
  }) {
    // If the CALLER dies mid-transaction, the worker rolls back. One
    // listener per worker, registered once at spawn; the response is the
    // rollback marker the worker's port recognises.
    Isolate.current.addOnExitListener(
      _requests,
      response: workerCallerExitedMarker,
    );
    // The worker's error and exit listeners take a SendPort each. They are
    // fields because they must CLOSE on teardown — an open ReceivePort
    // keeps this isolate (and its host process) from ever exiting.
    _workerErrors = ReceivePort();
    _isolate.addErrorListener(_workerErrors.sendPort);
    _workerErrors.listen((message) {
      _crash('The Cocoon worker isolate failed: $message');
    });
    _workerExits = ReceivePort();
    _isolate.addOnExitListener(_workerExits.sendPort);
    _workerExits.listen((message) {
      _crash('The Cocoon worker isolate exited unexpectedly');
    });
  }

  /// Spawns the worker and waits for its open handshake (ready, or the
  /// open failure rethrown here).
  static Future<_WorkerLink> spawn({
    required String path,
    required List<CollectionAdapter<Object?>> collections,
    required CocoonOptions options,
    required int? schemaVersion,
    required List<CocoonMigration> migrations,
    required SchemaLock? schemaLock,
    required bool reportCompactionFailures,
    required void Function(int done, int total)? onMigrationProgress,
    required void Function(Object error)? onCompactionFailed,
  }) async {
    final events = ReceivePort();
    final ready = Completer<WorkerReadyEvent>();
    final buffered = <Object>[];
    _WorkerLink? link;
    final subscription = events.listen((message) {
      switch (message) {
        case WorkerReadyEvent():
          if (!ready.isCompleted) {
            ready.complete(message);
          }
        case WorkerResponseEvent(id: workerOpenFailureId, :final error?):
          if (!ready.isCompleted) {
            ready.completeError(
              error.rebuild(),
              StackTrace.fromString(error.stackTraceText),
            );
          } else if (link != null) {
            link._respond(message);
          }
        case WorkerResponseEvent():
          if (link != null) {
            link._respond(message);
          } else {
            buffered.add(message);
          }
        case MigrationProgressEvent(:final done, :final total):
          onMigrationProgress?.call(done, total);
        case CompactionFailedEvent(:final error):
          onCompactionFailed?.call(error);
        case WatchEmissionEvent():
          if (link != null) {
            link.deliverWatch(message);
          } else {
            buffered.add(message);
          }
        case WatchErrorEvent():
          if (link != null) {
            link.deliverWatchError(message);
          } else {
            buffered.add(message);
          }
        case WatchDoneEvent():
          if (link != null) {
            link.deliverWatchDone(message);
          } else {
            buffered.add(message);
          }
        default:
          buffered.add(message as Object);
      }
    });
    final isolate = await Isolate.spawn(
      cocoonWorkerMain,
      WorkerInit(
        events: events.sendPort,
        path: path,
        collections: collections,
        options: options,
        schemaVersion: schemaVersion,
        migrations: migrations,
        schemaLock: schemaLock,
        reportCompactionFailures: reportCompactionFailures,
      ),
      debugName: 'cocoon-worker',
    );
    try {
      final event = await ready.future.timeout(const Duration(seconds: 120));
      link = _WorkerLink._(
        isolate,
        event.requests,
        events,
        subscription,
        instanceId: event.instanceId,
      );
      // Any event that raced the link assignment replays now.
      for (final pending in buffered) {
        switch (pending) {
          case WorkerResponseEvent():
            link._respond(pending);
          case WatchEmissionEvent():
            link.deliverWatch(pending);
          case WatchErrorEvent():
            link.deliverWatchError(pending);
          case WatchDoneEvent():
            link.deliverWatchDone(pending);
          default:
            break;
        }
      }
      buffered.clear();
      return link;
    } on Object {
      subscription.cancel();
      events.close();
      isolate.kill(priority: Isolate.beforeNextEvent);
      rethrow;
    }
  }

  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _events;
  final StreamSubscription<Object?> _subscription;

  /// The worker's error and exit listeners. They close on teardown: an
  /// open ReceivePort keeps this isolate's event loop — and with it the
  /// host process — alive long after the database closed.
  late final ReceivePort _workerErrors;
  late final ReceivePort _workerExits;

  /// The isolate handle, for the crash tests (see the runtime's
  /// [BackgroundCocoonRuntime.debugWorkerIsolate]).
  @visibleForTesting
  Isolate get debugIsolate => _isolate;

  /// The database's instance id, read from the worker's open.
  final String instanceId;

  var _nextRequestId = 0;
  var _nextWatchId = 0;
  var _nextTxId = 0;
  var _nextBulkId = 0;
  final Map<int, Completer<Object?>> _pending = {};
  final Map<int, _WatchProxy<dynamic>> _watchFeeds = {};
  bool _closed = false;
  Object? _crashed;

  /// Sends a request and resolves with its result; throws the rebuilt error
  /// (same type and message, worker stack trace) on failure. After close,
  /// fails like a closed local database; after a crash, fails with a
  /// [CocoonIsolateException]. The close handshake itself passes
  /// [duringClose] so it is not refused by its own flag.
  Future<T> request<T>(
    WorkerRequest Function(int id) build, {
    bool duringClose = false,
  }) {
    if (_crashed != null) {
      return Future.error(_crashed!);
    }
    if (_closed && !duringClose) {
      return Future.error(StateError('The database was closed'));
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _requests.send(build(id));
    // The value cast, not a future cast: the pending map is heterogeneous
    // (Completer<Object?>), and a Future<Object?> is not itself a Future<T>.
    return completer.future.then((value) => value as T);
  }

  void _respond(WorkerResponseEvent response) {
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

  /// The next transaction id (caller-assigned, so ops carry their owner).
  int get nextTxId => _nextTxId++;

  /// The next bulk-writer session id.
  int get nextBulkId => _nextBulkId++;

  /// Registers a proxy watch and returns its worker-side id.
  int registerWatch(_WatchProxy<dynamic> feed) {
    final id = _nextWatchId++;
    _watchFeeds[id] = feed;
    return id;
  }

  void deliverWatch(WatchEmissionEvent event) =>
      _watchFeeds[event.watchId]?.deliver(event.payload);

  void deliverWatchError(WatchErrorEvent event) {
    final feed = _watchFeeds.remove(event.watchId);
    feed?.deliverError(event.error);
  }

  void deliverWatchDone(WatchDoneEvent event) {
    final feed = _watchFeeds.remove(event.watchId);
    feed?.done();
  }

  /// Cancels the worker-side subscription (the caller's last listener went).
  void cancelWatch(int watchId) {
    if (_crashed != null || _closed) {
      _watchFeeds.remove(watchId)?.done();
      return;
    }
    unawaited(
      request<Object?>(
        (id) => WatchCancelRequest(id, watchId),
      ).catchError((Object _) => null),
    );
  }

  /// Marks the channel closed by an explicit close: pending requests fail
  /// with the closed-database error, as a closed local database does.
  Future<void> close() async {
    if (_crashed != null) {
      return;
    }
    if (_closed) {
      _failPendingWithClosed();
      return;
    }
    _closed = true;
    try {
      await request<Object?>((id) => CloseRequest(id), duringClose: true);
    } on Object {
      _isolate.kill(priority: Isolate.immediate);
      _failPendingWithClosed();
      _teardown();
      rethrow;
    }
    _isolate.kill(priority: Isolate.immediate);
    _failPendingWithClosed();
    _teardown();
  }

  void _failPendingWithClosed() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('The database was closed'));
      }
    }
    _pending.clear();
    for (final feed in _watchFeeds.values) {
      feed.done();
    }
    _watchFeeds.clear();
  }

  /// Marks the channel dead after an unexpected worker exit or error:
  /// every pending and future call fails with a [CocoonIsolateException]
  /// and the handle is unusable.
  void _crash(String message) {
    if (_crashed != null) {
      return;
    }
    final exception = CocoonIsolateException(
      typeName: 'WorkerIsolateGone',
      message: message,
      stackTraceText: '',
    );
    // After close() the handle stays a closed handle (later calls fail
    // with the closed-database StateError, not a crash) — but a close
    // still awaiting the worker's handshake must not hang when the worker
    // dies first: fail its pending request now.
    if (!_closed) {
      _crashed = exception;
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(exception);
      }
    }
    _pending.clear();
    for (final feed in _watchFeeds.values) {
      feed.done();
    }
    _watchFeeds.clear();
    _teardown();
  }

  void _teardown() {
    try {
      unawaited(_subscription.cancel());
      _events.close();
      _workerErrors.close();
      _workerExits.close();
    } on Object {
      // Already torn down.
    }
  }
}

/// One proxy watch: the caller-side broadcast controller the worker's
/// emissions feed, with its worker-side id. Work starts on the first listen
/// (a watch request reaches the worker) and stops when the last listener
/// cancels (a cancel request reaches the worker), matching the local
/// watches' lifecycle.
final class _WatchProxy<T> implements _WatchFeed {
  _WatchProxy(this._build, this._onPayload);

  final void Function(int watchId) _build;
  final T Function(Object? payload) _onPayload;

  late final StreamController<T> controller = StreamController<T>.broadcast(
    onListen: () => _build(watchId),
    onCancel: () => link?.cancelWatch(watchId),
  );

  @override
  int watchId = 0;

  @override
  _WorkerLink? link;

  /// The user-facing stream.
  Stream<T> get stream => controller.stream;

  @override
  void deliver(Object? payload) {
    if (!controller.isClosed) {
      controller.add(_onPayload(payload));
    }
  }

  @override
  void deliverError(ErrorEnvelope error) {
    if (!controller.isClosed) {
      controller.addError(
        error.rebuild(),
        StackTrace.fromString(error.stackTraceText),
      );
      controller.close();
    }
  }

  @override
  void done() {
    if (!controller.isClosed) {
      controller.close();
    }
  }
}

abstract interface class _WatchFeed {
  int watchId = 0;
  _WorkerLink? link;
  void deliver(Object? payload);
  void deliverError(ErrorEnvelope error);
  void done();
}

/// The background mode's proxy runtime: every [CocoonRuntime] call becomes
/// one message to the worker; results are rebuilt caller-side from paths
/// and values.
final class BackgroundCocoonRuntime implements CocoonRuntime {
  BackgroundCocoonRuntime._(this._link, this._registry, this._instanceId);

  final _WorkerLink _link;
  final SchemaRegistry _registry;

  // Kept for the facade's instanceId surface (the facade carries its own).
  // ignore: unused_field
  final String _instanceId;

  @override
  late Cocoon host;

  @override
  SchemaRegistry get registry => _registry;

  @override
  WatchHub get watchHub => throw StateError(
    'A background-mode database has no caller-side watch hub: watches run '
    'in the worker isolate',
  );

  @override
  bool get isLocal => false;

  @override
  String get isolateModeName => host.isolateModeName;

  @override
  CocoonIsolateStats? get isolateStats => null;

  @override
  CocoonExecutor get executor => throw StateError(
    'A background-mode database keeps its executor in the worker isolate; '
    'there is no caller-side executor to reach',
  );

  @override
  WriteBatch createWriteBatch(Cocoon db) => LocalWriteBatch(db);

  @override
  BulkWriter createBulkWriter(Cocoon db, BulkWriterOptions options) =>
      _BackgroundBulkWriter(db, _link, options);

  // -- Reads ----------------------------------------------------------------

  @override
  Future<DocSnapshot<T>?> getDoc<T extends Object>(DocRef<T> ref) async {
    final (exists, value) = await _link.request<(bool, Object?)>(
      (id) => GetDocRequest(id, ref.adapter, ref.path),
    );
    return exists ? DocSnapshot<T>(ref, value! as T) : null;
  }

  @override
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  ) async {
    final results = await _link.request<List<(bool, Object?)>>(
      (id) =>
          GetAllRequest(id, [for (final ref in refs) (ref.adapter, ref.path)]),
    );
    return [
      for (var i = 0; i < refs.length; i++)
        results[i].$1 ? DocSnapshot<T>(refs[i], results[i].$2! as T) : null,
    ];
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
    final (docs, nextCursor, bytes) = await _link
        .request<(List<(DocPath, Object?)>, String?, List<Uint8List>?)>(
          (id) => RunQueryRequest(
            id,
            adapter: spec.adapter,
            scopePath: spec.scopePath,
            filters: spec.filters,
            orders: spec.orders,
            limit: spec.limit,
            startAfter: spec.startAfter,
            fullScan: spec.fullScan,
            withBytes: withBytes,
          ),
        );
    final page = QueryPage<T>([
      for (final (path, value) in docs)
        DocSnapshot<T>(_refOf<T>(spec.adapter, path), value! as T),
    ], nextCursor);
    return (page, bytes ?? const []);
  }

  @override
  Future<int> runCount<T extends Object>(CocoonQuery<T> query) async {
    final spec = query.spec;
    return _link.request<int>(
      (id) => RunCountRequest(
        id,
        adapter: spec.adapter,
        scopePath: spec.scopePath,
        filters: spec.filters,
        orders: spec.orders,
        limit: spec.limit,
        fullScan: spec.fullScan,
      ),
    );
  }

  @override
  Future<AggregateQuerySnapshot<T>> runAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) async {
    final spec = aggregate.query.spec;
    final (values, count) = await _link.request<(List<Object?>, int)>(
      (id) => RunAggregateRequest(
        id,
        adapter: spec.adapter,
        scopePath: spec.scopePath,
        filters: spec.filters,
        orders: spec.orders,
        limit: spec.limit,
        fullScan: spec.fullScan,
        specs: aggregate.specs,
      ),
    );
    return AggregateQuerySnapshot<T>(aggregate.specs, values, count);
  }

  @override
  Future<List<AggregateGroup<T>>> runGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) async {
    final spec = aggregate.query.spec;
    // A typed local keeps the parser away from the `await f<T>(...)`
    // ambiguity this deeply nested record type would otherwise hit.
    final Future<List<(List<Object?>, List<Object?>, int)>> pending = _link
        .request(
          (id) => RunGroupAggregateRequest(
            id,
            adapter: spec.adapter,
            scopePath: spec.scopePath,
            filters: spec.filters,
            orders: spec.orders,
            maxGroups: aggregate.maxGroups,
            fullScan: spec.fullScan,
            keys: aggregate.keys,
            specs: aggregate.specs,
          ),
        );
    final groups = await pending;
    return [
      for (final (keyValues, values, count) in groups)
        AggregateGroup<T>(
          aggregate.keys,
          keyValues,
          aggregate.specs,
          values,
          count,
        ),
    ];
  }

  // -- Writes ---------------------------------------------------------------

  @override
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value) =>
      _link.request<Object?>(
        (id) => PutDocRequest(id, ref.adapter, ref.path, value),
      );

  @override
  Future<DocRef<T>> addDoc<T extends Object>(
    CollectionRef<T> ref,
    T value,
  ) async {
    final path = await _link.request<DocPath>(
      (id) => AddDocRequest(id, ref.adapter, ref.path, value),
    );
    return DocRef<T>(host, ref.adapter, path);
  }

  @override
  Future<void> deleteDoc(DocRef<Object> ref) => _link.request<Object?>(
    (id) => DeleteDocRequest(id, ref.adapter, ref.path),
  );

  @override
  Future<void> commitBatchOps(List<BatchOp> ops) => _link.request<Object?>(
    (id) => BatchCommitRequest(id, [
      for (final op in ops)
        WireOp(op.kind, op.ref.adapter, op.ref.path, op.value),
    ]),
  );

  @override
  Future<R> writeTx<R>(
    Future<R> Function(CocoonWriteTx wtx) body, {
    bool logChanges = true,
    TransactionScope? txScope,
  }) => Future.error(
    StateError(
      'A background-mode database runs its write transactions in the worker '
      'isolate: use runTransaction, batch().commit() or bulkWriter()',
    ),
  );

  @override
  Future<R> runTransactionBody<R>(
    Future<R> Function(CocoonWriteTx tx) body, {
    TransactionScope? txScope,
  }) async {
    final txId = _link.nextTxId;
    try {
      await _link.request<Object?>((id) => TxBeginRequest(id, txId));
      final proxy = _ProxyWriteTx._(_link, txId, host);
      R result;
      try {
        result = await body(proxy);
      } on Object {
        // Roll the worker transaction back, then rethrow the body's error.
        await _link
            .request<Object?>((id) => TxEndRequest(id, txId, false, null))
            .catchError((Object _) => null);
        rethrow;
      }
      // The body succeeded: commit in the worker. A commit failure rethrows.
      await _link.request<Object?>(
        (id) => TxEndRequest(id, txId, true, result),
      );
      return result;
    } finally {
      // The SQL transaction ended (commit or rollback) in the worker: end
      // the guard before the call returns, so futures and timers the body
      // created never trip it — the same rule the local runtime follows.
      txScope?.deactivate();
    }
  }

  // -- Watches --------------------------------------------------------------

  @override
  Stream<DocSnapshot<T>?> watchDoc<T extends Object>(DocRef<T> ref) {
    final proxy = _WatchProxy<DocSnapshot<T>?>(
      (watchId) {
        _link
            .request<Object?>(
              (id) => WatchRequest(
                id,
                watchId: watchId,
                kind: 'doc',
                adapter: ref.adapter,
                scopePath: null,
                filters: const [],
                orders: const [],
                limit: null,
                startAfter: null,
                fullScan: false,
                specs: const [],
                keys: const [],
                maxGroups: null,
                path: ref.path,
              ),
            )
            .catchError((Object _) => null);
      },
      (payload) {
        return payload == null ? null : DocSnapshot<T>(ref, payload as T);
      },
    );
    _register(proxy);
    return proxy.stream;
  }

  @override
  Stream<QueryPage<T>> watchQuery<T extends Object>(CocoonQuery<T> query) {
    final spec = query.spec;
    final proxy = _WatchProxy<QueryPage<T>>(
      (watchId) {
        _link
            .request<Object?>(
              (id) => WatchRequest(
                id,
                watchId: watchId,
                kind: 'query',
                adapter: spec.adapter,
                scopePath: spec.scopePath,
                filters: spec.filters,
                orders: spec.orders,
                limit: spec.limit,
                startAfter: spec.startAfter,
                fullScan: spec.fullScan,
                specs: const [],
                keys: const [],
                maxGroups: null,
                path: null,
              ),
            )
            .catchError((Object _) => null);
      },
      (payload) {
        final (docs, nextCursor) =
            payload as (List<(DocPath, Object?)>, String?);
        return QueryPage<T>([
          for (final (path, value) in docs)
            DocSnapshot<T>(_refOf<T>(spec.adapter, path), value! as T),
        ], nextCursor);
      },
    );
    _register(proxy);
    return proxy.stream;
  }

  @override
  Stream<AggregateQuerySnapshot<T>> watchAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) {
    final spec = aggregate.query.spec;
    final proxy = _WatchProxy<AggregateQuerySnapshot<T>>(
      (watchId) {
        _link
            .request<Object?>(
              (id) => WatchRequest(
                id,
                watchId: watchId,
                kind: 'aggregate',
                adapter: spec.adapter,
                scopePath: spec.scopePath,
                filters: spec.filters,
                orders: spec.orders,
                limit: spec.limit,
                startAfter: null,
                fullScan: spec.fullScan,
                specs: aggregate.specs,
                keys: const [],
                maxGroups: null,
                path: null,
              ),
            )
            .catchError((Object _) => null);
      },
      (payload) {
        final (values, count) = payload as (List<Object?>, int);
        return AggregateQuerySnapshot<T>(aggregate.specs, values, count);
      },
    );
    _register(proxy);
    return proxy.stream;
  }

  @override
  Stream<List<AggregateGroup<T>>> watchGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) {
    final spec = aggregate.query.spec;
    final proxy = _WatchProxy<List<AggregateGroup<T>>>(
      (watchId) {
        _link
            .request<Object?>(
              (id) => WatchRequest(
                id,
                watchId: watchId,
                kind: 'groups',
                adapter: spec.adapter,
                scopePath: spec.scopePath,
                filters: spec.filters,
                orders: spec.orders,
                limit: null,
                startAfter: null,
                fullScan: spec.fullScan,
                specs: aggregate.specs,
                keys: aggregate.keys,
                maxGroups: aggregate.maxGroups,
                path: null,
              ),
            )
            .catchError((Object _) => null);
      },
      (payload) {
        final groups = payload as List<(List<Object?>, List<Object?>, int)>;
        return [
          for (final (keyValues, values, count) in groups)
            AggregateGroup<T>(
              aggregate.keys,
              keyValues,
              aggregate.specs,
              values,
              count,
            ),
        ];
      },
    );
    _register(proxy);
    return proxy.stream;
  }

  void _register(_WatchProxy<dynamic> proxy) {
    proxy.watchId = _link.registerWatch(proxy);
    proxy.link = _link;
  }

  DocRef<T> _refOf<T extends Object>(
    CollectionAdapter<Object?> adapter,
    DocPath path,
  ) => DocRef<T>(host, adapter as CollectionAdapter<T>, path);

  // -- Change log, files, lifecycle -----------------------------------------

  @override
  Future<List<Change>> changesSince(int seq, {int limit = 1000}) =>
      _link.request<List<Change>>((id) => ChangesSinceRequest(id, seq, limit));

  @override
  Future<int> earliestChangeSeq() =>
      _link.request<int>((id) => EarliestChangeSeqRequest(id));

  @override
  Future<int> lastChangeSeq() =>
      _link.request<int>((id) => LastChangeSeqRequest(id));

  @override
  Future<int> pruneChanges({required int upToSeq}) =>
      _link.request<int>((id) => PruneChangesRequest(id, upToSeq));

  @override
  Future<BackupInfo> backupTo(String path, {required bool overwrite}) =>
      _link.request<BackupInfo>((id) => BackupToRequest(id, path, overwrite));

  @override
  Future<void> close() => _link.close();

  @override
  Future<int> get debugCacheLength =>
      _diagnostic<int>((id) => CacheLengthRequest(id));

  /// The worker isolate's handle, for the crash tests: killing it exercises
  /// the caller-side crash wiring (every pending and future call fails with
  /// a [CocoonIsolateException] and the handle is unusable).
  @visibleForTesting
  Isolate get debugWorkerIsolate => _link.debugIsolate;

  @override
  Future<int> get debugWatcherCount =>
      _diagnostic<int>((id) => WatcherCountRequest(id));

  /// Diagnostics cross as messages; a worker that is already gone reports 0
  /// rather than failing the read.
  Future<T> _diagnostic<T extends num>(WorkerRequest Function(int id) build) =>
      _link.request<T>(build).catchError((Object _) => 0 as T);

  @override
  List<MissingIndexReport> get missingIndexes => const [];

  // -- Bulk-writer deferred indexes: worker-side accounting ------------------

  @override
  void noteBulkWriterActive() {}

  @override
  void noteBulkWriterClosed() {}

  @override
  void noteIndexesDeferred(Iterable<String> indexNames) {}

  @override
  void noteIndexesRestored(Iterable<String> indexNames) {}

  @override
  Future<void> waitForBulkIndexes(String? servingIndex) => Future.value();

  // -- Local transaction internals: unreachable through a proxy --------------

  @override
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonRead reader,
    DocRef<T> ref,
  ) => Future.error(
    StateError(
      'Transactions run through the worker isolate in background mode',
    ),
  );

  @override
  Future<List<DocSnapshot<T>?>> getAllDocsInTx<T extends Object>(
    CocoonRead reader,
    List<DocRef<T>> refs,
  ) => Future.error(
    StateError(
      'Transactions run through the worker isolate in background mode',
    ),
  );

  @override
  Future<List<(String, String)>> deleteRow(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
    String id,
  ) => Future.error(
    StateError(
      'Transactions run through the worker isolate in background mode',
    ),
  );

  @override
  Future<List<(String, String)>> deleteScopePrefix(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
  ) => Future.error(
    StateError(
      'Transactions run through the worker isolate in background mode',
    ),
  );

  @override
  bool get keepsChanges => throw StateError(
    'A background-mode database keeps its change-log policy in the worker '
    'isolate',
  );

  @override
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
}

/// The transaction's write surface in background mode: every `tx` call is
/// one message tagged with the transaction id.
final class _ProxyWriteTx implements CocoonWriteTx {
  _ProxyWriteTx._(this._link, this._txId, this._host);

  final _WorkerLink _link;
  final int _txId;
  final Cocoon _host;

  @override
  Future<DocSnapshot<T>?> get<T extends Object>(DocRef<T> ref) async {
    final (exists, value) = await _link.request<(bool, Object?)>(
      (id) => TxGetRequest(id, _txId, ref.adapter, ref.path),
    );
    return exists ? DocSnapshot<T>(ref, value! as T) : null;
  }

  @override
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  ) async {
    final results = await _link.request<List<(bool, Object?)>>(
      (id) => TxGetAllRequest(id, _txId, [
        for (final ref in refs) (ref.adapter, ref.path),
      ]),
    );
    return [
      for (var i = 0; i < refs.length; i++)
        results[i].$1 ? DocSnapshot<T>(refs[i], results[i].$2! as T) : null,
    ];
  }

  @override
  Future<void> put<T extends Object>(
    DocRef<T> ref,
    T value, {
    bool update = false,
  }) => _link.request<Object?>(
    (id) => TxPutRequest(
      id,
      _txId,
      adapter: ref.adapter,
      path: ref.path,
      value: value,
      update: update,
    ),
  );

  @override
  Future<DocRef<T>> add<T extends Object>(CollectionRef<T> ref, T value) async {
    final path = await _link.request<DocPath>(
      (id) => TxAddRequest(
        id,
        _txId,
        adapter: ref.adapter,
        collectionPath: ref.path,
        value: value,
      ),
    );
    return DocRef<T>(_host, ref.adapter, path);
  }

  @override
  Future<void> delete(DocRef<Object> ref) => _link.request<Object?>(
    (id) => TxDeleteRequest(id, _txId, ref.adapter, ref.path),
  );

  /// Queues a write with pre-built statement arguments; the background
  /// proxy's transaction surface has none (writes are messages).
  @override
  Future<void> putPrepared(
    DocRef<Object> ref,
    RegistryEntry entry,
    List<Object?> args, {
    bool update = false,
  }) => Future.error(
    StateError(
      'A background-mode transaction prepares its writes in the worker '
      'isolate',
    ),
  );

  @override
  CocoonTx get tx => throw StateError(
    'A background-mode transaction has no caller-side SQL transaction: its '
    'operations are messages to the worker isolate',
  );
}

/// The background mode's bulk writer: operations queue on the caller and
/// ship to the worker in chunks (one message per chunk), where a real local
/// bulk writer — with its deferral rule, existence checks, change-log
/// policy and deferred-index rebuilds — commits them.
final class _BackgroundBulkWriter implements BulkWriter {
  _BackgroundBulkWriter(this._db, this._link, this._options) {
    // A chunk commit would wait forever for the transaction's own write
    // lock — the same creation-time rule the local writer enforces.
    checkNotInTransaction(_db, 'Cocoon.bulkWriter', read: false);
  }

  final Cocoon _db;
  final _WorkerLink _link;
  final BulkWriterOptions _options;

  final List<WireOp> _ops = [];
  var _shipped = 0;
  int? _sessionId;
  bool _opened = false;
  bool _closed = false;
  Object? _failure;

  @override
  void set<T extends Object>(DocRef<T> ref, T value) {
    _checkUsable();
    checkNotInTransaction(_db, 'BulkWriter.set', read: false);
    _queue(BatchOpKind.set, ref, value);
  }

  @override
  void update<T extends Object>(DocRef<T> ref, T value) {
    _checkUsable();
    checkNotInTransaction(_db, 'BulkWriter.update', read: false);
    _queue(BatchOpKind.update, ref, value);
  }

  @override
  void delete(DocRef<Object> ref) {
    _checkUsable();
    checkNotInTransaction(_db, 'BulkWriter.delete', read: false);
    _db.registry.entryFor(ref.adapter);
    _ops.add(WireOp(BatchOpKind.delete, ref.adapter, ref.path, null));
    _kick();
  }

  @override
  Future<void> flush() {
    _checkUsable();
    checkNotInTransaction(_db, 'BulkWriter.flush', read: false);
    if (_failure != null) {
      return Future.error(_failure!);
    }
    return _runTo();
  }

  @override
  Future<void> close() async {
    _checkUsable();
    checkNotInTransaction(_db, 'BulkWriter.close', read: false);
    _closed = true;
    Object? error;
    StackTrace? trace;
    if (_failure != null) {
      error = _failure;
      trace = StackTrace.current;
    } else {
      try {
        await _runTo();
      } on Object catch (e, s) {
        error ??= e;
        trace ??= s;
      }
    }
    // Whatever happened, a deferred index must not stay dropped: the worker
    // session's close rebuilds them (like the local writer's close).
    final bulkId = _sessionId;
    if (bulkId != null) {
      try {
        await _link.request<Object?>((id) => BulkCloseRequest(id, bulkId));
      } on Object catch (e, s) {
        error ??= e;
        trace ??= s;
      }
    }
    if (error != null) {
      Error.throwWithStackTrace(error, trace!);
    }
  }

  void _checkUsable() {
    if (_closed) {
      throw StateError('This BulkWriter was already closed');
    }
  }

  void _queue<T extends Object>(BatchOpKind kind, DocRef<T> ref, T value) {
    _db.registry.entryFor(ref.adapter);
    _ops.add(WireOp(kind, ref.adapter, ref.path, value));
    _kick();
  }

  /// Ships full chunks while they are available: the worker's own writer
  /// keeps committing while the caller keeps queueing.
  void _kick() {
    while (_ops.length >= _options.chunkSize) {
      _ship(_options.chunkSize);
    }
  }

  /// Ships everything still buffered, then waits until the worker committed
  /// at least that many operations (the flush goal).
  Future<void> _runTo() async {
    while (_ops.isNotEmpty) {
      _ship(
        _ops.length >= _options.chunkSize ? _options.chunkSize : _ops.length,
      );
    }
    final bulkId = _sessionId;
    if (bulkId == null) {
      return;
    }
    await _link.request<Object?>(
      (id) => BulkFlushRequest(id, bulkId, _shipped),
    );
  }

  void _ship(int take) {
    if (!_opened) {
      // The session opens with the first chunk; the open must reach the
      // worker before the operations do (one port, in-order delivery).
      _sessionId = _link.nextBulkId;
      final bulkId = _sessionId!;
      _opened = true;
      _send((id) => BulkOpenRequest(id, bulkId, _options));
    }
    final chunk = _ops.take(take).toList(growable: false);
    _ops.removeRange(0, take);
    _shipped += chunk.length;
    final bulkId = _sessionId!;
    _send((id) => BulkOpsRequest(id, bulkId, chunk));
  }

  /// Fire-and-forget ship: the ack confirms enqueue/commit progress at the
  /// next flush goal; failures surface from flush() and close().
  void _send(WorkerRequest Function(int id) build) {
    _link
        .request<Object?>(build)
        .then(
          (_) {},
          onError: (Object error) {
            _failure ??= error;
          },
        );
  }
}

/// Options for the worker with the caller's callbacks stripped: closures
/// with captured state are not guaranteed sendable, so compaction failures
/// cross as [CompactionFailedEvent]s instead (the host replays them into
/// the caller's callback).
CocoonOptions _optionsForWorker(CocoonOptions options) => CocoonOptions(
  durability: options.durability,
  cacheSize: options.cacheSize,
  keepChanges: options.keepChanges,
  changeRetention: options.changeRetention,
  pageCacheMiB: options.pageCacheMiB,
  tempStoreInMemory: options.tempStoreInMemory,
  walAutoCheckpointPages: options.walAutoCheckpointPages,
  compactAfterUpgrade: options.compactAfterUpgrade,
  onCompactionFailed: null,
  onMissingIndex: options.onMissingIndex,
  isolate: CocoonIsolate.caller,
  autoThresholds: options.autoThresholds,
);
