/// The background mode's worker isolate: hosts the whole engine for one
/// database — SQLite executor, hot-document cache, write lock, watch hub,
/// change log, batch and bulk-writer sessions — and serves the caller's
/// requests ([WorkerRequest]) over one port, streaming watch emissions and
/// migration progress back as events.
///
/// The worker is spawned by `CocoonIsolateHost.open` with the same open
/// arguments the caller would have used; the engine it opens is the
/// ordinary local engine (`Cocoon.openLocalFile`), so every engine behaviour
/// — including the DevTools inspector service extensions, which register
/// here — is exactly the caller-mode one. The worker exits when the
/// database closes or when its caller isolate dies (rolling back any open
/// transaction first).
library;

import 'dart:async';
import 'dart:developer';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../../path.dart';
import '../adapter.dart';
import '../aggregate.dart';
import '../batch.dart' show BatchOp, BatchOpKind;
import '../bulk_writer.dart';
import '../cocoon.dart';
import '../query.dart';
import '../refs.dart';
import '../runtime.dart';
import 'error_envelope.dart';
import 'messages.dart';

/// The marker a caller isolate sends through [Isolate.addOnExitListener]
/// when it dies: the worker rolls back every open transaction and exits.
const String workerCallerExitedMarker = 'cocoon:caller-exited';

/// The synthetic request id the open handshake reports failures under.
const int workerOpenFailureId = -1;

/// The worker entry point: opens the engine, then serves requests until the
/// database closes or the caller dies. Failures during the open are
/// reported as a response to request id [workerOpenFailureId] (the host's
/// open handshake waits for either).
@internal
void cocoonWorkerMain(WorkerInit init) {
  final events = init.events;
  final requestPort = ReceivePort();
  final server = _WorkerServer(events);
  requestPort.listen((message) {
    if (message == workerCallerExitedMarker) {
      server.callerDied();
      return;
    }
    unawaited(server.handle(message as WorkerRequest));
  });
  unawaited(
    () async {
      try {
        final db = await Cocoon.openLocalFile(
          init.path,
          collections: init.collections,
          options: init.options,
          schemaVersion: init.schemaVersion,
          migrations: init.migrations,
          onMigrationProgress: (done, total) {
            events.send(MigrationProgressEvent(done, total));
          },
          schemaLock: init.schemaLock,
          onCompactionFailed: init.reportCompactionFailures
              ? (error) => events.send(CompactionFailedEvent(error))
              : null,
        );
        events.send(WorkerReadyEvent(requestPort.sendPort, db.instanceId));
        await server.serve(db);
      } on Object catch (error, stackTrace) {
        // The open failed: report it to the id the host awaits and exit.
        events.send(
          WorkerResponseEvent(workerOpenFailureId, null, envelopeFrom(error, stackTrace)),
        );
      } finally {
        requestPort.close();
      }
    }(),
  );
}

/// The worker's per-database state: the engine facade, open transactions,
/// bulk-writer sessions and live watch subscriptions.
final class _WorkerServer {
  _WorkerServer(this._events);

  final SendPort _events;
  Cocoon? _db;
  bool _closed = false;
  final Completer<void> _done = Completer<void>();

  /// Open transactions by caller-side id: the transaction's write surface
  /// and the settle switch the end message flips.
  final Map<int, CocoonWriteTx> _openTxs = {};
  final Map<int, _TxSession> _txSessions = {};

  /// Live bulk writers by caller-side session id.
  final Map<int, _BulkSession> _bulkSessions = {};

  /// Live watch subscriptions by caller-side watch id.
  final Map<int, StreamSubscription<Object?>> _watches = {};

  /// Watch ids the caller cancelled; their stream completion is not
  /// reported (the caller's stream is deliberately paused, not done).
  final Set<int> _cancelledWatches = {};

  /// Runs until the database closes; the worker entry awaits this.
  Future<void> serve(Cocoon db) {
    _db = db;
    return _done.future;
  }

  /// Rolls back every open transaction and exits: the caller isolate died
  /// with transactions still open, so their write locks must not outlive
  /// it, and no further message will ever arrive.
  void callerDied() {
    for (final MapEntry(key: txId, value: session) in _txSessions.entries) {
      if (!session.settle.isCompleted) {
        session.settle.completeError(
          StateError(
            'The isolate holding this transaction exited; the transaction '
            'was rolled back',
          ),
        );
        unawaited(
          session.future.catchError((Object error, StackTrace stackTrace) {
            log(
              'Cocoon worker: transaction $txId rolled back after its '
              'caller isolate died ($error)',
              name: 'cocoon',
            );
            return null;
          }),
        );
      }
    }
    _txSessions.clear();
    _openTxs.clear();
    unawaited(_shutdown());
  }

  /// Runs one request; sends exactly one response.
  Future<void> handle(WorkerRequest request) async {
    final events = _events;
    try {
      final result = await _dispatch(request);
      events.send(WorkerResponseEvent(request.id, result, null));
    } on Object catch (error, stackTrace) {
      events.send(
        WorkerResponseEvent(request.id, null, envelopeFrom(error, stackTrace)),
      );
    }
  }

  Future<Object?> _dispatch(WorkerRequest request) async {
    final db = _db;
    switch (request) {
      case GetDocRequest(:final adapter, :final path):
        _requireOpen();
        final snapshot = await db!.getDoc<Object>(_docRef<Object>(db, adapter, path));
        return snapshot == null ? (false, null) : (true, snapshot.data);
      case GetAllRequest(:final refs):
        _requireOpen();
        final snapshots = await db!.getAll<Object>([
          for (final (adapter, path) in refs) _docRef<Object>(db, adapter, path),
        ]);
        return [
          for (final snapshot in snapshots)
            snapshot == null ? (false, null) : (true, snapshot.data),
        ];
      case PutDocRequest(:final adapter, :final path, :final value):
        _requireOpen();
        await db!.putDoc<Object>(_docRef<Object>(db, adapter, path), value!);
        return null;
      case AddDocRequest(:final adapter, :final collectionPath, :final value):
        _requireOpen();
        final ref = CollectionRef<Object>(
          db!,
          adapter as CollectionAdapter<Object>,
          collectionPath,
        );
        return (await db.addDoc<Object>(ref, value!)).path;
      case DeleteDocRequest(:final adapter, :final path):
        _requireOpen();
        await db!.deleteDoc(_docRef<Object>(db, adapter, path));
        return null;
      case RunQueryRequest(
          :final adapter,
          :final scopePath,
          :final filters,
          :final orders,
          :final limit,
          :final startAfter,
          :final fullScan,
          :final withBytes,
        ):
        _requireOpen();
        final query = _queryOf(db!, adapter, scopePath, filters, orders, limit,
            startAfter, fullScan);
        if (withBytes) {
          final (page, bytes) = await db.runQueryWithBytes<Object>(query);
          return (
            [for (final doc in page.docs) (doc.ref.path, doc.data)],
            page.nextCursor,
            bytes,
          );
        }
        final page = await db.runQuery<Object>(query);
        return (
          [for (final doc in page.docs) (doc.ref.path, doc.data)],
          page.nextCursor,
          null,
        );
      case RunCountRequest(
          :final adapter,
          :final scopePath,
          :final filters,
          :final orders,
          :final limit,
          :final fullScan,
        ):
        _requireOpen();
        final query = _queryOf(db!, adapter, scopePath, filters, orders, limit,
            null, fullScan);
        return db.runCount<Object>(query);
      case RunAggregateRequest(
          :final adapter,
          :final scopePath,
          :final filters,
          :final orders,
          :final limit,
          :final fullScan,
          :final specs,
        ):
        _requireOpen();
        final query = _queryOf(db!, adapter, scopePath, filters, orders, limit,
            null, fullScan);
        final snapshot = await db
            .runAggregate<Object>(AggregateQuery<Object>(query, specs));
        return (snapshot.values, snapshot.count);
      case RunGroupAggregateRequest(
          :final adapter,
          :final scopePath,
          :final filters,
          :final orders,
          :final maxGroups,
          :final fullScan,
          :final keys,
          :final specs,
        ):
        _requireOpen();
        final query = _queryOf(
          db!,
          adapter,
          scopePath,
          filters,
          orders,
          null,
          null,
          fullScan,
        );
        final groups = await db.runGroupAggregate<Object>(
          AggregateGroupQuery<Object>.rebuild(query, keys, maxGroups, specs),
        );
        return [
          for (final group in groups)
            (group.keyValues, group.values, group.count),
        ];
      case WatchRequest(
          :final watchId,
          :final kind,
          :final adapter,
          :final scopePath,
          :final filters,
          :final orders,
          :final limit,
          :final startAfter,
          :final fullScan,
          :final specs,
          :final keys,
          :final maxGroups,
          :final path,
        ):
        _requireOpen();
        _cancelledWatches.remove(watchId);
        final Stream<Object?> stream;
        switch (kind) {
          case 'doc':
            stream = db!.watchDoc<Object>(_docRef<Object>(db, adapter, path!));
          case 'query':
            final query = _queryOf(
              db!,
              adapter,
              scopePath,
              filters,
              orders,
              limit,
              startAfter,
              fullScan,
            );
            stream = db.watchQuery<Object>(query);
          case 'aggregate':
            final query = _queryOf(
              db!,
              adapter,
              scopePath,
              filters,
              orders,
              limit,
              null,
              fullScan,
            );
            stream = db.watchAggregate<Object>(
              AggregateQuery<Object>(query, specs),
            );
          case 'groups':
            final query = _queryOf(
              db!,
              adapter,
              scopePath,
              filters,
              orders,
              null,
              null,
              fullScan,
            );
            stream = db.watchGroupAggregate<Object>(
              AggregateGroupQuery<Object>.rebuild(query, keys, maxGroups, specs),
            );
          default:
            throw ArgumentError.value(kind, 'kind', 'Unknown watch kind');
        }
        _watches[watchId] = stream.listen(
          (Object? emission) {
            _events.send(WatchEmissionEvent(watchId, _emissionOf(kind, emission)));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_cancelledWatches.contains(watchId)) {
              return;
            }
            // A watch's read error (a MissingIndexException, say) arrives on
            // the caller's stream as an error event, then the stream stops —
            // the same shape the local watch produces.
            _events.send(
              WatchErrorEvent(watchId, envelopeFrom(error, stackTrace)),
            );
            _events.send(WatchDoneEvent(watchId));
            _watches.remove(watchId);
          },
          onDone: () {
            _watches.remove(watchId);
            if (_cancelledWatches.remove(watchId)) {
              return; // deliberate cancel: the caller's stream stays open
            }
            _events.send(WatchDoneEvent(watchId));
          },
        );
        return null;
      case WatchCancelRequest(:final watchId):
        _cancelledWatches.add(watchId);
        await _watches.remove(watchId)?.cancel();
        _cancelledWatches.remove(watchId);
        return null;
      case TxBeginRequest(:final txId):
        _requireOpen();
        final ready = Completer<void>();
        final settle = Completer<Object?>();
        final future = db!.runTransaction<Object?>((tx) async {
          _openTxs[txId] = tx.writeTx;
          ready.complete();
          return await settle.future;
        });
        _txSessions[txId] = _TxSession(future, settle);
        await ready.future;
        return null;
      case TxGetRequest(:final txId, :final adapter, :final path):
        final tx = _txOf(txId);
        final snapshot = await tx.get<Object>(
          _docRef<Object>(_db!, adapter, path),
        );
        return snapshot == null ? (false, null) : (true, snapshot.data);
      case TxGetAllRequest(:final txId, :final refs):
        final tx = _txOf(txId);
        final snapshots = await tx.getAll<Object>([
          for (final (adapter, path) in refs) _docRef<Object>(_db!, adapter, path),
        ]);
        return [
          for (final snapshot in snapshots)
            snapshot == null ? (false, null) : (true, snapshot.data),
        ];
      case TxPutRequest(
          :final txId,
          :final adapter,
          :final path,
          :final value,
          :final update,
        ):
        final tx = _txOf(txId);
        await tx.put<Object>(
          _docRef<Object>(_db!, adapter, path),
          value!,
          update: update,
        );
        return null;
      case TxAddRequest(:final txId, :final adapter, :final collectionPath, :final value):
        final tx = _txOf(txId);
        final ref = await tx.add<Object>(
          CollectionRef<Object>(
            _db!,
            adapter as CollectionAdapter<Object>,
            collectionPath,
          ),
          value!,
        );
        return ref.path;
      case TxDeleteRequest(:final txId, :final adapter, :final path):
        final tx = _txOf(txId);
        await tx.delete(_docRef<Object>(_db!, adapter, path));
        return null;
      case TxEndRequest(:final txId, :final commit, :final result):
        final session = _txSessions.remove(txId);
        _openTxs.remove(txId);
        if (session == null) {
          return null; // already ended (idempotent)
        }
        if (commit) {
          session.settle.complete(result);
          await session.future;
        } else {
          session.settle.completeError(
            StateError('The transaction body threw; rolling back'),
          );
          await session.future.catchError((Object _) => null);
        }
        return null;
      case BatchCommitRequest(:final ops):
        _requireOpen();
        await db!.runtime.commitBatchOps([
          for (final op in ops)
            BatchOp(
              op.kind,
              _docRef<Object>(db, op.adapter, op.path),
              op.value,
            ),
        ]);
        return null;
      case BulkOpenRequest(:final bulkId, :final options):
        _requireOpen();
        if (_bulkSessions.containsKey(bulkId)) {
          throw StateError('Bulk writer session $bulkId is already open');
        }
        _bulkSessions[bulkId] = _BulkSession(
          bulkId,
          LocalBulkWriter(db!, options),
        );
        return null;
      case BulkOpsRequest(:final bulkId, :final ops):
        final session = _bulkOf(bulkId);
        for (final op in ops) {
          final ref = _docRef<Object>(_db!, op.adapter, op.path);
          switch (op.kind) {
            case BatchOpKind.set:
              session.writer.set<Object>(ref, op.value!);
            case BatchOpKind.update:
              session.writer.update<Object>(ref, op.value!);
            case BatchOpKind.delete:
              session.writer.delete(ref);
          }
        }
        return null;
      case BulkFlushRequest(:final bulkId, :final target):
        final session = _bulkOf(bulkId);
        await session.writer.drainTo(target);
        return null;
      case BulkCloseRequest(:final bulkId):
        final session = _bulkOf(bulkId);
        _bulkSessions.remove(bulkId);
        await session.writer.close();
        return null;
      case ChangesSinceRequest(:final seq, :final limit):
        _requireOpen();
        return db!.changesSince(seq, limit: limit);
      case EarliestChangeSeqRequest():
        _requireOpen();
        return db!.earliestChangeSeq();
      case LastChangeSeqRequest():
        _requireOpen();
        return db!.lastChangeSeq();
      case PruneChangesRequest(:final upToSeq):
        _requireOpen();
        return db!.pruneChanges(upToSeq: upToSeq);
      case BackupToRequest(:final path, :final overwrite):
        _requireOpen();
        return db!.backupTo(path, overwrite: overwrite);
      case CacheLengthRequest():
        _requireOpen();
        return db!.runtime.debugCacheLength;
      case WatcherCountRequest():
        _requireOpen();
        return db!.runtime.debugWatcherCount;
      case CloseRequest():
        await _shutdown();
        return null;
    }
  }

  /// Closes the engine and every session, then completes the server's done
  /// future so the isolate exits.
  Future<void> _shutdown() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final database = _db;
    if (database != null) {
      await database.close();
      _db = null;
    }
    for (final subscription in _watches.values) {
      await subscription.cancel();
    }
    _watches.clear();
    _bulkSessions.clear();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  _BulkSession _bulkOf(int bulkId) {
    final session = _bulkSessions[bulkId];
    if (session == null) {
      throw StateError('This BulkWriter was already closed');
    }
    return session;
  }

  CocoonWriteTx _txOf(int txId) {
    final tx = _openTxs[txId];
    if (tx == null) {
      throw StateError('No open transaction $txId on the worker');
    }
    return tx;
  }

  void _requireOpen() {
    if (_closed || _db == null) {
      throw StateError('The database was closed');
    }
  }

  DocRef<T> _docRef<T extends Object>(
    Cocoon db,
    CollectionAdapter<Object?> adapter,
    DocPath path,
  ) => DocRef<T>(db, adapter as CollectionAdapter<T>, path);

  CocoonQuery<Object> _queryOf(
    Cocoon db,
    CollectionAdapter<Object?> adapter,
    CollectionPath? scopePath,
    List<QueryFilter> filters,
    List<QueryOrder> orders,
    int? limit,
    String? startAfter,
    bool fullScan,
  ) => CocoonQuery<Object>(
    db,
    adapter as CollectionAdapter<Object>,
    scopePath,
    filters: filters,
    orders: orders,
    limit: limit,
    startAfter: startAfter,
    fullScan: fullScan,
  );

  /// Converts a worker-side emission into its sendable wire shape.
  Object? _emissionOf(String kind, Object? emission) {
    switch (kind) {
      case 'doc':
        // A deleted document's emission is null: the payload crosses as
        // null and the caller's stream delivers a null snapshot.
        if (emission == null) {
          return null;
        }
        final snapshot = emission as DocSnapshot<Object>;
        return snapshot.data;
      case 'query':
        final page = emission as QueryPage<Object>;
        return (
          [for (final doc in page.docs) (doc.ref.path, doc.data)],
          page.nextCursor,
        );
      case 'aggregate':
        final snapshot = emission as AggregateQuerySnapshot<Object>;
        return (snapshot.values, snapshot.count);
      case 'groups':
        final groups = emission as List<AggregateGroup<Object>>;
        return [
          for (final group in groups)
            (group.keyValues, group.values, group.count),
        ];
      default:
        throw ArgumentError.value(kind, 'kind', 'Unknown watch kind');
    }
  }
}

/// One open transaction's plumbing: the runTransaction future (its result
/// and error) and the settle switch.
final class _TxSession {
  _TxSession(this.future, this.settle);

  final Future<Object?> future;
  final Completer<Object?> settle;
}

/// The worker-side handle of one bulk writer session.
final class _BulkSession {
  _BulkSession(this.id, this.writer);

  /// The caller-side session id.
  final int id;

  /// The worker's own bulk writer.
  final LocalBulkWriter writer;
}
