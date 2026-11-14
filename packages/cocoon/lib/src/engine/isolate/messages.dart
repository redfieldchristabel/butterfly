/// The message protocol between a database's caller isolate and its
/// background worker isolate.
///
/// Every message is plain sendable data: adapters, paths, query filters and
/// model values are sendable between isolates of the same group
/// (`Isolate.spawn`), so specs cross as built objects and only snapshots —
/// whose refs point at the caller's `Cocoon` facade — are rebuilt from
/// paths. Closures never cross. See the design doc's "Isolates" decision.
library;

import 'dart:isolate';

import '../../migration.dart';
import '../../path.dart';
import '../../schema.dart';
import '../adapter.dart';
import '../aggregate.dart';
import '../batch.dart' show BatchOpKind;
import '../bulk_writer.dart';
import '../cocoon.dart';
import 'error_envelope.dart';
import '../query.dart';

/// The caller→worker init payload, sent as the [Isolate.spawn] message.
final class WorkerInit {
  /// Builds the payload.
  const WorkerInit({
    required this.events,
    required this.path,
    required this.collections,
    required this.options,
    required this.schemaVersion,
    required this.migrations,
    required this.schemaLock,
    required this.reportCompactionFailures,
  });

  /// The port the worker answers on (ready, responses, watch events,
  /// progress).
  final SendPort events;

  /// The database file the worker opens.
  final String path;

  /// The adapters the engine stores and reads with.
  final List<CollectionAdapter<Object?>> collections;

  /// The open options (the isolate option itself is meaningless inside the
  /// worker; [CocoonOptions.onCompactionFailed] is stripped — a closure
  /// with captured state must not cross, so failures are reported as
  /// [CompactionFailedEvent]s instead).
  final CocoonOptions options;

  /// The schema version passed to `Cocoon.open`, if any.
  final int? schemaVersion;

  /// The migrations passed to `Cocoon.open`.
  final List<CocoonMigration> migrations;

  /// The schema lock passed to `Cocoon.open`, if any.
  final SchemaLock? schemaLock;

  /// Whether the worker reports compaction failures as events (it does when
  /// the app passed an [CocoonOptions.onCompactionFailed] callback).
  final bool reportCompactionFailures;
}

/// Worker→caller events: the ready handshake, responses to requests, watch
/// emissions, migration progress, compaction failures and death.
sealed class WorkerEvent {
  const WorkerEvent();
}

/// The worker opened the database; `requests` is the port to send requests
/// to, [instanceId] the database's instance id.
final class WorkerReadyEvent extends WorkerEvent {
  /// Builds the event.
  const WorkerReadyEvent(this.requests, this.instanceId);

  /// The port the worker receives requests on.
  final SendPort requests;

  /// The opened database's instance id.
  final String instanceId;
}

/// The answer to one request ([id]); exactly one per request, unless the
/// worker died first.
final class WorkerResponseEvent extends WorkerEvent {
  /// Builds the event.
  const WorkerResponseEvent(this.id, this.result, this.error);

  /// The id of the request being answered.
  final int id;

  /// The result, `null` for void operations and on error.
  final Object? result;

  /// The failure envelope, when the operation failed.
  final ErrorEnvelope? error;
}

/// Migration progress while the worker's open runs.
final class MigrationProgressEvent extends WorkerEvent {
  /// Builds the event.
  const MigrationProgressEvent(this.done, this.total);

  /// Documents processed so far.
  final int done;

  /// Documents total.
  final int total;
}

/// A post-upgrade compaction failure in the worker, delivered so the app's
/// `CocoonOptions.onCompactionFailed` callback runs on the caller.
final class CompactionFailedEvent extends WorkerEvent {
  /// Builds the event.
  const CompactionFailedEvent(this.error);

  /// The compaction error (usually a full disk).
  final Object error;
}

/// One watch emission, deduplicated by the worker's watch (query watches
/// deduplicate by canonical bytes in the worker; nothing crosses twice).
final class WatchEmissionEvent extends WorkerEvent {
  /// Builds the event.
  const WatchEmissionEvent(this.watchId, this.payload);

  /// The caller-side watch id this emission belongs to.
  final int watchId;

  /// The emission in wire shape (see the request classes); `null` for a
  /// deleted document's doc-watch emission.
  final Object? payload;
}

/// A watch stream failed while re-reading (a MissingIndexException, a
/// closed-database error, ...): the caller's stream receives this as an
/// error event and then completes.
final class WatchErrorEvent extends WorkerEvent {
  /// Builds the event.
  const WatchErrorEvent(this.watchId, this.error);

  /// The caller-side watch id this error belongs to.
  final int watchId;

  /// The failure, in envelope shape.
  final ErrorEnvelope error;
}

/// A watch stream completed (cancelled, or the database closed).
final class WatchDoneEvent extends WorkerEvent {
  /// Builds the event.
  const WatchDoneEvent(this.watchId);

  /// The watch id whose stream completed.
  final int watchId;
}

/// One request from the caller to the worker. Every field is sendable data;
/// adapters and specs are rebuilt as equal copies in the worker's own
/// registry (entries resolve by pattern).
sealed class WorkerRequest {
  const WorkerRequest(this.id);

  /// The caller's request id; echoed in the response.
  final int id;
}

/// `DocRef.get`.
final class GetDocRequest extends WorkerRequest {
  /// Builds the request.
  const GetDocRequest(super.id, this.adapter, this.path);

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The document path.
  final DocPath path;
}

/// `db.getAll(refs)`.
final class GetAllRequest extends WorkerRequest {
  /// Builds the request.
  const GetAllRequest(super.id, this.refs);

  /// One (adapter, path) per position, duplicates included.
  final List<(CollectionAdapter<Object?>, DocPath)> refs;
}

/// `DocRef.set`.
final class PutDocRequest extends WorkerRequest {
  /// Builds the request.
  const PutDocRequest(super.id, this.adapter, this.path, this.value);

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The document path.
  final DocPath path;

  /// The value to store.
  final Object? value;
}

/// `CollectionRef.add`.
final class AddDocRequest extends WorkerRequest {
  /// Builds the request.
  const AddDocRequest(super.id, this.adapter, this.collectionPath, this.value);

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The collection path to add to.
  final CollectionPath collectionPath;

  /// The value to store.
  final Object? value;
}

/// `DocRef.delete`.
final class DeleteDocRequest extends WorkerRequest {
  /// Builds the request.
  const DeleteDocRequest(super.id, this.adapter, this.path);

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The document path.
  final DocPath path;
}

/// One page of a query (or its byte signatures, when [withBytes] is set —
/// query watches deduplicate pages by the bytes).
final class RunQueryRequest extends WorkerRequest {
  /// Builds the request.
  const RunQueryRequest(
    super.id, {
    required this.adapter,
    required this.scopePath,
    required this.filters,
    required this.orders,
    required this.limit,
    required this.startAfter,
    required this.fullScan,
    required this.withBytes,
  });

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The concrete parent collection, or `null` for a collection group.
  final CollectionPath? scopePath;

  /// The query's filters.
  final List<QueryFilter> filters;

  /// The query's sort keys.
  final List<QueryOrder> orders;

  /// The page size, or `null`.
  final int? limit;

  /// The cursor, or `null` for a first page.
  final String? startAfter;

  /// Whether the index requirement is opted out.
  final bool fullScan;

  /// Whether the response carries each document's stored wire bytes.
  final bool withBytes;
}

/// `CocoonQuery.count()`.
final class RunCountRequest extends WorkerRequest {
  /// Builds the request (the same shape as [RunQueryRequest] without a
  /// cursor: aggregates ignore cursors).
  const RunCountRequest(
    super.id, {
    required this.adapter,
    required this.scopePath,
    required this.filters,
    required this.orders,
    required this.limit,
    required this.fullScan,
  });

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The concrete parent collection, or `null` for a collection group.
  final CollectionPath? scopePath;

  /// The query's filters.
  final List<QueryFilter> filters;

  /// The query's sort keys.
  final List<QueryOrder> orders;

  /// The page size (a limited aggregate runs over the first page), or
  /// `null`.
  final int? limit;

  /// Whether the index requirement is opted out.
  final bool fullScan;
}

/// `AggregateQuery.get()`.
final class RunAggregateRequest extends WorkerRequest {
  /// Builds the request.
  const RunAggregateRequest(
    super.id, {
    required this.adapter,
    required this.scopePath,
    required this.filters,
    required this.orders,
    required this.limit,
    required this.fullScan,
    required this.specs,
  });

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The concrete parent collection, or `null` for a collection group.
  final CollectionPath? scopePath;

  /// The query's filters.
  final List<QueryFilter> filters;

  /// The query's sort keys.
  final List<QueryOrder> orders;

  /// The page size, or `null`.
  final int? limit;

  /// Whether the index requirement is opted out.
  final bool fullScan;

  /// The requested aggregate functions.
  final List<AggregateFunction<Object>> specs;
}

/// `AggregateGroupQuery.get()`.
final class RunGroupAggregateRequest extends WorkerRequest {
  /// Builds the request.
  const RunGroupAggregateRequest(
    super.id, {
    required this.adapter,
    required this.scopePath,
    required this.filters,
    required this.orders,
    required this.maxGroups,
    required this.fullScan,
    required this.keys,
    required this.specs,
  });

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The concrete parent collection, or `null` for a collection group.
  final CollectionPath? scopePath;

  /// The query's filters.
  final List<QueryFilter> filters;

  /// The query's sort keys.
  final List<QueryOrder> orders;

  /// The group cap, or `null`.
  final int? maxGroups;

  /// Whether the index requirement is opted out.
  final bool fullScan;

  /// The group keys.
  final List<GroupKeySpec<Object, Object?>> keys;

  /// The requested aggregate functions.
  final List<AggregateFunction<Object>> specs;
}

/// Starts a watch in the worker. [withBytes] marks a query watch whose page
/// dedup needs byte signatures — computed in the worker, they never cross.
final class WatchRequest extends WorkerRequest {
  /// Builds the request (the watch's own caller-side id in [watchId]).
  const WatchRequest(
    super.id, {
    required this.watchId,
    required this.kind,
    required this.adapter,
    required this.scopePath,
    required this.filters,
    required this.orders,
    required this.limit,
    required this.startAfter,
    required this.fullScan,
    required this.specs,
    required this.keys,
    required this.maxGroups,
    required this.path,
  });

  /// The watch id the caller assigned (unique per database handle).
  final int watchId;

  /// `doc`, `query`, `aggregate` or `groups`.
  final String kind;

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The concrete parent collection, or `null` for a collection group.
  final CollectionPath? scopePath;

  /// The query's filters (ignored for doc watches).
  final List<QueryFilter> filters;

  /// The query's sort keys (ignored for doc watches).
  final List<QueryOrder> orders;

  /// The page size, or `null` (ignored for doc watches).
  final int? limit;

  /// The cursor, or `null` (ignored for doc watches).
  final String? startAfter;

  /// Whether the index requirement is opted out (ignored for doc watches).
  final bool fullScan;

  /// The aggregate functions (aggregate and group watches).
  final List<AggregateFunction<Object>> specs;

  /// The group keys (group watches).
  final List<GroupKeySpec<Object, Object?>> keys;

  /// The group cap (group watches), or `null`.
  final int? maxGroups;

  /// The document path (doc watches).
  final DocPath? path;
}

/// Cancels a watch: the worker unsubscribes its stream.
final class WatchCancelRequest extends WorkerRequest {
  /// Builds the request.
  const WatchCancelRequest(super.id, this.watchId);

  /// The watch id to cancel.
  final int watchId;
}

/// Opens the worker-side write transaction for a `runTransaction` body: the
/// worker holds the write lock until the body settles.
final class TxBeginRequest extends WorkerRequest {
  /// Builds the request ([txId] assigned by the caller).
  const TxBeginRequest(super.id, this.txId);

  /// The caller-side transaction id.
  final int txId;
}

/// One operation of a transaction body, tagged with its [txId]. Applied in
/// message order against the worker's open transaction.
sealed class TxOpRequest extends WorkerRequest {
  const TxOpRequest(super.id, this.txId);

  /// The transaction the op belongs to.
  final int txId;
}

/// `tx.get(ref)`.
final class TxGetRequest extends TxOpRequest {
  /// Builds the request.
  const TxGetRequest(super.id, super.txId, this.adapter, this.path);

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The document path.
  final DocPath path;
}

/// `tx.getAll(refs)`.
final class TxGetAllRequest extends TxOpRequest {
  /// Builds the request.
  const TxGetAllRequest(super.id, super.txId, this.refs);

  /// One (adapter, path) per position, duplicates included.
  final List<(CollectionAdapter<Object?>, DocPath)> refs;
}

/// `tx.set(ref, value)` (or [update]).
final class TxPutRequest extends TxOpRequest {
  /// Builds the request.
  const TxPutRequest(
    super.id,
    super.txId, {
    required this.adapter,
    required this.path,
    required this.value,
    required this.update,
  });

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The document path.
  final DocPath path;

  /// The value to store.
  final Object? value;

  /// Whether the write must replace an existing document.
  final bool update;
}

/// `tx.add(ref, value)`: the worker picks the fresh id and returns its path.
final class TxAddRequest extends TxOpRequest {
  /// Builds the request.
  const TxAddRequest(
    super.id,
    super.txId, {
    required this.adapter,
    required this.collectionPath,
    required this.value,
  });

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The collection to add into.
  final CollectionPath collectionPath;

  /// The value to store.
  final Object? value;
}

/// `tx.delete(ref)`.
final class TxDeleteRequest extends TxOpRequest {
  /// Builds the request.
  const TxDeleteRequest(super.id, super.txId, this.adapter, this.path);

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The document path.
  final DocPath path;
}

/// Ends the transaction: commit ([commit]) with the body's return value, or
/// roll back. An errored transaction was already rolled back when its op
/// failed; this is the idempotent final word.
final class TxEndRequest extends WorkerRequest {
  /// Builds the request.
  const TxEndRequest(super.id, this.txId, this.commit, this.result);

  /// The transaction to end.
  final int txId;

  /// Whether to commit (true) or roll back (false).
  final bool commit;

  /// The body's return value (sent with the commit).
  final Object? result;
}

/// Commits a `WriteBatch`'s queued ops as one transaction.
final class BatchCommitRequest extends WorkerRequest {
  /// Builds the request.
  const BatchCommitRequest(super.id, this.ops);

  /// The queued operations, in call order.
  final List<WireOp> ops;
}

/// One queued write crossing the isolate boundary (a batch or bulk-writer
/// operation): kind, adapter, document path and the value for writes.
final class WireOp {
  /// Builds the wire op.
  const WireOp(this.kind, this.adapter, this.path, this.value);

  /// The kind of write.
  final BatchOpKind kind;

  /// The collection adapter.
  final CollectionAdapter<Object?> adapter;

  /// The document path.
  final DocPath path;

  /// The value, for set and update; `null` for delete.
  final Object? value;
}

/// Opens a bulk-writer session in the worker (sent before the session's
/// first operations).
final class BulkOpenRequest extends WorkerRequest {
  /// Builds the request ([bulkId] assigned by the caller).
  const BulkOpenRequest(super.id, this.bulkId, this.options);

  /// The bulk-writer session id.
  final int bulkId;

  /// The writer's options (chunk size, deferral, change logging).
  final BulkWriterOptions options;
}

/// Feeds a chunk of queued operations into the worker's bulk writer (the
/// chunk is one message, not one message per op).
final class BulkOpsRequest extends WorkerRequest {
  /// Builds the request.
  const BulkOpsRequest(super.id, this.bulkId, this.ops);

  /// The bulk-writer session id.
  final int bulkId;

  /// The chunk's operations, in call order.
  final List<WireOp> ops;
}

/// Sets a flush goal for the worker's bulk writer: commits until at least
/// [target] operations have committed.
final class BulkFlushRequest extends WorkerRequest {
  /// Builds the request.
  const BulkFlushRequest(super.id, this.bulkId, this.target);

  /// The bulk-writer session id.
  final int bulkId;

  /// The cumulative committed count to reach.
  final int target;
}

/// Drains the worker's bulk writer and rebuilds its deferred indexes.
final class BulkCloseRequest extends WorkerRequest {
  /// Builds the request.
  const BulkCloseRequest(super.id, this.bulkId);

  /// The bulk-writer session id.
  final int bulkId;
}

/// `db.changesSince(seq, limit)`.
final class ChangesSinceRequest extends WorkerRequest {
  /// Builds the request.
  const ChangesSinceRequest(super.id, this.seq, this.limit);

  /// The seq to read from.
  final int seq;

  /// The page size.
  final int limit;
}

/// `db.earliestChangeSeq()`.
final class EarliestChangeSeqRequest extends WorkerRequest {
  /// Builds the request.
  const EarliestChangeSeqRequest(super.id);
}

/// `db.lastChangeSeq()`.
final class LastChangeSeqRequest extends WorkerRequest {
  /// Builds the request.
  const LastChangeSeqRequest(super.id);
}

/// `db.pruneChanges(upToSeq)`.
final class PruneChangesRequest extends WorkerRequest {
  /// Builds the request.
  const PruneChangesRequest(super.id, this.upToSeq);

  /// The seq floor to delete through.
  final int upToSeq;
}

/// `db.backupTo(path, overwrite)`.
final class BackupToRequest extends WorkerRequest {
  /// Builds the request.
  const BackupToRequest(super.id, this.path, this.overwrite);

  /// The backup file path.
  final String path;

  /// Whether an existing backup file may be replaced.
  final bool overwrite;
}

/// Closes the worker's engine; the worker exits after replying.
final class CloseRequest extends WorkerRequest {
  /// Builds the request.
  const CloseRequest(super.id);
}

/// Diagnostics: the worker's hot-document cache length.
final class CacheLengthRequest extends WorkerRequest {
  /// Builds the request.
  const CacheLengthRequest(super.id);
}

/// Diagnostics: the worker's registered watch count.
final class WatcherCountRequest extends WorkerRequest {
  /// Builds the request.
  const WatcherCountRequest(super.id);
}
