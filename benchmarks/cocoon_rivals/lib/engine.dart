/// The engine interface every rival implements, plus the measured values
/// every operation reports. Copied from `packages/cocoon_bench` and extended
/// with the all-accounts workloads (range, year report, status search,
/// read-while-write, NDJSON restore). One process runs one engine for one
/// operation — memory numbers never leak between engines.
///
/// Only the `import` operation receives the typed dataset. Every other
/// operation works from the database itself (or the shared NDJSON backup
/// file), so the harness's copy of the data never sits in the memory those
/// operations measure.
///
/// ## The read contracts every engine must satisfy
///
/// The smoke test compares these across engines before any timing counts.
///
/// - **latest-50** of one account: ids ordered by `bookedOn DESC`, ties
///   broken by the string id `DESC`. (The dataset has ~30 txns per
///   account-day at 1M, so the tie-break carries real weight; engines whose
///   query API lacks a string id get one ordered by construction.)
/// - **range month**: every txn with `bookedOn` in the month, all accounts,
///   ordered by `bookedOn ASC`, ties by id `ASC`, paged by [rangePageSize].
/// - **year report**: per-account per-month `amountMinor` sums of one year.
/// - **status search**: latest 50 `pending` txns across all accounts, same
///   order as latest-50.
library;

import 'dart:io';
import 'dart:math';

import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/models.dart' as m;

/// One measured operation over one engine at one size.
///
/// The metrics keys are operation-specific; the CLI prints them as JSON.
abstract final class Metrics {
  static const elapsedMs = 'elapsedMs';
  static const fileBytes = 'fileBytes';
  static const openMs = 'openMs';
  static const rssBytes = 'rssBytes';
  static const rssAfterOpenBytes = 'rssAfterOpenBytes';
  static const rssAfterReadsBytes = 'rssAfterReadsBytes';
  static const peakRssBytes = 'peakRssBytes';
  static const p50Us = 'p50Us';
  static const p95Us = 'p95Us';
  static const queries = 'queries';
  static const docsScanned = 'docsScanned';
  static const grandTotalMinor = 'grandTotalMinor';
  static const count = 'count';
  static const found = 'found';
  static const pages = 'pages';
  static const accounts = 'accounts';
  static const writes = 'writes';
  static const txns = 'txns';
}

/// One document the engine sampled out of its own database: its parent
/// account id, its id and its value in the engine's native form (Cocoon: the
/// typed model, sembast/Hive: the stored map, drift/Isar/ObjectBox: the row
/// object). [writeUs] writes it back unchanged.
typedef SampledDoc = ({String accountId, String id, Object? value});

/// A storage backend under benchmark: import, cold open, the read shapes of
/// a finance app (old and new), single writes, and the NDJSON restore.
abstract interface class BenchEngine {
  /// `cocoon`, `cocoon-normal`, `drift`, `isar`, `objectbox`, `hive`,
  /// `sembast`.
  String get name;

  /// The path of this engine's database file under [baseDir].
  String dbPath(String baseDir);

  /// Deletes the database files, for a fresh import run.
  void wipe(String baseDir);

  /// The size on disk of the database files after close, in bytes.
  int fileSize(String baseDir);

  /// Imports [data] — accounts first, then transactions in batches of 1000
  /// per transaction. Returns the bulk-import wall time in milliseconds.
  Future<int> import(BenchDataset data, String baseDir);

  /// Opens the database and answers one small query over [accountId].
  /// Returns the open wall time in milliseconds; the process start-to-first-
  /// query time the CLI reports adds the harness overhead measured in
  /// `bin/bench.dart`.
  Future<int> coldOpen(String baseDir, {required String accountId});

  /// The RSS right after opening (before any read), in bytes.
  Future<int> rssAfterOpen(String baseDir);

  /// Opens the database for the read/write operations below. Idempotent;
  /// required before every read and write method.
  Future<void> open(String baseDir);

  /// The ids of [accountId]'s 50 latest transactions, newest first —
  /// `bookedOn DESC`, ties by string id `DESC`.
  Future<List<String>> latest50Ids(String accountId, String baseDir);

  /// The latest-50 query over every [accountIds] entry, timed per query.
  /// Returns the per-query durations in microseconds, in the order asked.
  Future<List<int>> latest50Us(List<String> accountIds, String baseDir);

  /// One account's monthly totals for [year]: pages the account's txns and
  /// sums `amountMinor` per month in Dart. Returns the totals keyed `yyyyMM`
  /// and how many documents were read.
  Future<({Map<int, int> totals, int scanned})> monthlyTotalsMap(
    String accountId,
    int year,
    String baseDir,
  );

  /// One account's monthly totals for [year], as the CLI reports them:
  /// (elapsed ms, docs scanned, grand total minor units).
  Future<(int, int, int)> monthlyTotals(
    String accountId,
    int year,
    String baseDir,
  );

  /// A seeded, uniform-random sample of [count] documents read back from the
  /// database (reservoir sampling over every stored document, in the
  /// engine's deterministic store order). Untimed by callers: this is how
  /// the harness gets ids and values to read and write without holding the
  /// typed dataset in RAM.
  Future<List<SampledDoc>> sampleDocs(String baseDir, int count, Random rng);

  /// Gets [ids] by id, returning (elapsed ms, hits).
  Future<(int, int)> getsById(
    List<({String accountId, String id})> ids,
    String baseDir,
  );

  /// Writes every [docs] entry back — same id, same value it sampled — one
  /// `set` per document, outside any transaction. Returns the per-write
  /// durations in microseconds, in order.
  Future<List<int>> writeUs(List<SampledDoc> docs, String baseDir);

  /// Pages every txn of one month ([rangeMonthKey], all accounts) by
  /// [rangePageSize], in `bookedOn ASC`, ties by id `ASC` order, and returns
  /// every id in order. The CLI derives pages from the count.
  Future<List<String>> rangeMonthIds(String baseDir);

  /// Per-account per-month `amountMinor` sums of [reportYear] across every
  /// account. Returns (elapsed ms, sums, accounts covered); sums keyed
  /// `<accountId>|<yyyyMM>` for the smoke test.
  Future<(int, Map<String, int>, int)> yearReport(String baseDir);

  /// The latest 50 `pending` txns across all accounts — [statusRuns]
  /// executions, timed per run. Returns the per-run durations in
  /// microseconds, in the order asked.
  Future<List<int>> statusSearchUs(String baseDir);

  /// The ids the status search returns, for the smoke test.
  Future<List<String>> statusSearchIds(String baseDir);

  /// Writes one brand-new sync txn with [id] (a `w…` id) into [accountId]'s
  /// collection, outside any transaction. The read-while-write op calls this
  /// every [rwwIntervalMs] ms from an in-process async loop (see
  /// `bin/bench.dart` for why the writer is not a separate isolate).
  Future<void> writeOneTxn(String accountId, String id, int seq);

  /// Restores the shared NDJSON backup (parse included) into a wiped
  /// database, in batches of 1000. Returns (elapsed ms, txns restored).
  Future<(int, int)> restore(String baseDir);

  /// Releases the database.
  Future<void> close();
}

/// The yyyymm month the range op reads across all accounts.
const rangeMonthKey = 202406;

/// The year the year-report op aggregates across all accounts.
const reportYear = 2024;

/// The page size the all-accounts month range op reads by.
const rangePageSize = 100;

/// How many times the status search runs per measurement.
const statusRuns = 50;

/// How many documents one restore batch writes.
const restoreBatchSize = 1000;

/// How many documents one import batch writes.
const importBatchSize = 1000;

/// The page size the monthly-totals paging and the id sampling use.
const monthlyPageSize = 500;

/// How long the read-while-write writer waits between writes, in ms.
const rwwIntervalMs = 10;

/// The txn the read-while-write writer lands, one shared definition.
m.Txn syncTxnOf(int seq) => m.Txn(
  bookedOn: 20261101,
  amountMinor: 100 + seq,
  currency: 'MYR',
  status: m.TxnStatus.posted,
  memo: 'sync',
);

/// Reservoir sampling (Algorithm R) over [stream]: keeps the first [count]
/// elements, then replaces a uniformly chosen slot for each element after —
/// every [count]-subset of the stream comes out equally likely. The seeded
/// [rng] makes the sample identical in every process over the same database.
///
/// Every engine samples this way so `gets`/`write` never need the typed
/// dataset in RAM: the ids and values come from the database itself.
Future<List<SampledDoc>> reservoirSample(
  int count,
  Random rng,
  Stream<SampledDoc> Function() stream,
) async {
  final reservoir = <SampledDoc>[];
  var seen = 0;
  await for (final doc in stream()) {
    final k = seen++;
    if (k < count) {
      reservoir.add(doc);
    } else {
      final j = rng.nextInt(k + 1);
      if (j < count) {
        reservoir[j] = doc;
      }
    }
  }
  if (seen < count) {
    throw StateError('sample: database holds only $seen documents');
  }
  return reservoir;
}

/// The p50/p95 (percentile by nearest-rank over the sorted list) of
/// [micros], plus how many measurements there were.
({int p50Us, int p95Us, int count}) percentiles(List<int> micros) {
  final sorted = [...micros]..sort();
  int at(double p) {
    final index = ((sorted.length - 1) * p).round();
    return sorted[index];
  }

  return (p50Us: at(0.50), p95Us: at(0.95), count: sorted.length);
}

/// Sum of the byte sizes of [path] and every sibling journal/WAL file.
int fileSizeWithSidecars(String path) {
  var total = 0;
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    if (file.existsSync()) {
      total += file.lengthSync();
    }
  }
  return total;
}

/// Sum of the byte sizes of every file directly under [dir] (the directory
/// stores of engines like Isar, ObjectBox and Hive).
int dirSizeWithSidecars(String dir) {
  final directory = Directory(dir);
  if (!directory.existsSync()) {
    return 0;
  }
  var total = 0;
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is File) {
      total += entity.lengthSync();
    }
  }
  return total;
}
