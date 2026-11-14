/// The isolate-mode option ([CocoonIsolate]), the auto mode's routing
/// thresholds and the routing rules, plus the debug counters auto mode
/// exposes.
///
/// Everything here is pure: the router is a function of the thresholds and
/// the op's size, unit-tested without a database.
library;

import 'package:meta/meta.dart';

/// Which isolate runs a database's engine: decode, encode, planning, the
/// write lock, the hot-document cache and the watch notifier.
///
/// SQLite's own work already runs off the calling isolate inside
/// `sqlite_async`; these options move the DART half of the engine work.
enum CocoonIsolate {
  /// The engine runs on the isolate that called [Cocoon.open] — the
  /// default, and the behaviour of every Cocoon version before isolate
  /// support existed. Zero message round trips; a 10k-document page read
  /// decodes on the caller.
  caller,

  /// The engine runs in ONE dedicated worker isolate per database (same
  /// isolate group, `Isolate.spawn`). The returned [Cocoon] proxies every
  /// call; snapshots, pages, aggregates and errors cross back; transactions
  /// run their user body on the caller and their engine work in the
  /// worker. Best for Flutter UIs with big pages, bulk imports, heavy
  /// aggregates or restores. Costs one round trip per operation.
  background,

  /// One engine, home on the caller (exactly [caller]: one write lock, one
  /// hot-document cache, one watch source, transactions inline), plus one
  /// helper isolate that (a) serves heavy reads from its own read-only
  /// connection and (b) does the CPU side of heavy writes (encoding
  /// documents into prepared rows for the bulk writer and big batches).
  /// Small work and transactions run inline with zero round trips.
  auto,
}

/// The size thresholds auto mode routes by. Deterministic: an operation's
/// route depends only on its a-priori size (ids, explicit limit, queued ops)
/// and these numbers — see the routing rules on [CocoonIsolate.auto].
final class CocoonAutoThresholds {
  /// Builds thresholds; the defaults come from the isolate benchmark
  /// (`docs/libraries/cocoon/isolates`): below ~200 documents the
  /// round trip to the helper costs more than decoding on the caller.
  const CocoonAutoThresholds({
    this.inlineRows = defaultInlineRows,
    this.inlineWriteOps = defaultInlineWriteOps,
  });

  /// The default [inlineRows].
  static const int defaultInlineRows = 200;

  /// The default [inlineWriteOps].
  static const int defaultInlineWriteOps = 500;

  /// Doc gets/sets/deletes always run inline. A `getAll` with at most this
  /// many ids, and a query/watch with an explicit `limit` at most this big,
  /// runs inline; anything bigger moves to the helper.
  final int inlineRows;

  /// A `batch().commit()` with at most this many queued operations runs
  /// inline (whole batch); a bigger batch's document encodes are prepared
  /// in the helper. A `bulkWriter()` always prepares in the helper.
  final int inlineWriteOps;

  /// Throws an [ArgumentError] for a negative threshold. Zero is allowed:
  /// with a zero threshold only an operation with nothing in it (an empty
  /// getAll, a limit-0 query, an empty batch) stays inline; any real work
  /// goes to the helper.
  void validate() {
    if (inlineRows < 0) {
      throw ArgumentError.value(
        inlineRows,
        'inlineRows',
        'Must not be negative',
      );
    }
    if (inlineWriteOps < 0) {
      throw ArgumentError.value(
        inlineWriteOps,
        'inlineWriteOps',
        'Must not be negative',
      );
    }
  }
}

/// Which side of auto mode runs an operation.
enum AutoRoute {
  /// Runs inline on the caller (zero message round trips).
  inline,

  /// Runs in the helper isolate.
  helper,
}

/// The auto-mode routing rules — pure functions of the thresholds and the
/// operation's a-priori size, so they can be unit-tested without a database.
/// `auto` never routes a transaction, a doc get/set/delete or a count away
/// from the caller.
@internal
abstract final class AutoRouter {
  /// `getAll` with [refCount] refs: inline up to [CocoonAutoThresholds.inlineRows].
  static AutoRoute getAll(CocoonAutoThresholds t, int refCount) =>
      refCount <= t.inlineRows ? AutoRoute.inline : AutoRoute.helper;

  /// A query (or watch's re-run) with an explicit [limit]: inline up to
  /// [CocoonAutoThresholds.inlineRows]; unbounded pages go to the helper.
  static AutoRoute query(CocoonAutoThresholds t, int? limit) =>
      limit != null && limit <= t.inlineRows
      ? AutoRoute.inline
      : AutoRoute.helper;

  /// A groupBy query capped at [maxGroups] groups (results are small per
  /// group, but an uncapped groupBy may return unbounded groups): inline up
  /// to [CocoonAutoThresholds.inlineRows], helper beyond or uncapped.
  static AutoRoute groupBy(CocoonAutoThresholds t, int? maxGroups) =>
      maxGroups != null && maxGroups <= t.inlineRows
      ? AutoRoute.inline
      : AutoRoute.helper;

  /// A `batch().commit()` with [opCount] queued operations: inline up to
  /// [CocoonAutoThresholds.inlineWriteOps].
  static AutoRoute batch(CocoonAutoThresholds t, int opCount) =>
      opCount <= t.inlineWriteOps ? AutoRoute.inline : AutoRoute.helper;

  /// A `bulkWriter()` chunk always prepares (encodes) in the helper.
  static AutoRoute bulkWriter(CocoonAutoThresholds t) => AutoRoute.helper;

  /// Aggregates always run inline: SQL does the work and the result is one
  /// small row.
  static AutoRoute aggregate(CocoonAutoThresholds t) => AutoRoute.inline;

  /// Transactions always run inline (the body is user code with captured
  /// state; every tx op runs inline, so the transaction behaves exactly
  /// like caller mode).
  static AutoRoute transaction(CocoonAutoThresholds t) => AutoRoute.inline;
}

/// The auto mode's counters since the database opened: how many operations
/// routed each way and roughly how many document bytes crossed to the
/// helper. Exposed as `db.isolateStats` (auto mode only; `null` otherwise).
///
/// `helperBytesMoved` counts the payload bytes the helper channel carried —
/// query/getAll result document bytes arriving from the helper and prepared
/// write bytes arriving back — so it approximates the isolate-copy cost
/// from the app's point of view. It does not count small control messages.
final class CocoonIsolateStats {
  CocoonIsolateStats();

  /// Operations that ran inline on the caller.
  int inlineCalls = 0;

  /// Operations served by the helper isolate.
  int helperCalls = 0;

  /// Approximate payload bytes moved over the helper channel (results in,
  /// prepared writes out).
  int helperBytesMoved = 0;

  /// A frozen copy of the counters.
  CocoonIsolateStats snapshot() => CocoonIsolateStats()
    ..inlineCalls = inlineCalls
    ..helperCalls = helperCalls
    ..helperBytesMoved = helperBytesMoved;

  @override
  String toString() =>
      'CocoonIsolateStats(inline: $inlineCalls, helper: $helperCalls, '
      'bytesMoved: $helperBytesMoved)';
}
