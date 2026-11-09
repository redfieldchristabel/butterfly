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
/// - **bigspend**: the 50 largest debits across all accounts —
///   `amountMinor ASC` (most negative first), ties by the string id `ASC`,
///   limit 50. No amount filter: with the dataset's distribution the 50
///   smallest amounts are always debits, and every engine must agree.
/// - **amount range**: every txn with `amountMinor` in the fixed band
///   `[amountBandLo, amountBandHi)` (all accounts), `amountMinor ASC`, ties
///   by id `ASC`, paged by [amountRangePageSize].
/// - **pending month**: every `pending` txn of [rangeMonthKey] (all
///   accounts), `bookedOn ASC`, ties by id `ASC`, paged by
///   [rangePageSize].
/// - **deep page**: one account's history newest-first (the latest-50
///   order), [deeppagePageCount] pages of [deeppagePageSize] documents by
///   the engine's own paging idiom — cursor where the engine has one,
///   offset where that is the idiom.
/// - **counts**: (1) `pending` txns across all accounts, (2) one account's
///   txns in [reportYear].
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
  static const page20Us = 'page20Us';
  static const queries = 'queries';
  static const docsScanned = 'docsScanned';
  static const grandTotalMinor = 'grandTotalMinor';
  static const count = 'count';
  static const found = 'found';
  static const pages = 'pages';
  static const accounts = 'accounts';
  static const writes = 'writes';
  static const txns = 'txns';

  /// The op's user+sys CPU time, in ms — the `/proc/self/stat`
  /// utime+stime delta over the op's measured section (the same section the
  /// wall-time metrics cover), so battery cost shows next to wall time.
  static const cpuMs = 'cpuMs';

  /// The bytes the process wrote to the storage layer over the op's
  /// measured section — the `/proc/self/io` `write_bytes` delta (whole
  /// process, so native and isolate threads count).
  static const diskWriteBytes = 'diskWriteBytes';

  /// Import only: [diskWriteBytes] divided by the final database file size
  /// — how many bytes land on disk per byte of database.
  static const writeAmplification = 'writeAmplification';

  /// The count shapes' p50/p95 keys (`count` op).
  static const pendingP50Us = 'pendingP50Us';
  static const pendingP95Us = 'pendingP95Us';
  static const yearP50Us = 'yearP50Us';
  static const yearP95Us = 'yearP95Us';
  static const pendingCount = 'pendingCount';
  static const yearCount = 'yearCount';
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

  /// Imports [data] — accounts first (untimed, as [import]), then every
  /// transaction through this engine's best documented bulk API, in one go
  /// instead of [importBatchSize] per commit: Cocoon `bulkWriter()` with
  /// defaults, drift one `batch` in one transaction, Isar one `writeTxn` +
  /// `putAll`, ObjectBox one `putMany`, Hive one `putAll`, sembast one
  /// transaction. The `bulkimport` op wipes its own database and runs this;
  /// the read ops keep measuring [import]'s database. Like [restore],
  /// implementations close any live instance first and leave nothing open,
  /// so a sequential in-process caller (the smoke test) reopens [import]'s
  /// database afterwards. Returns the bulk-import wall time in milliseconds.
  Future<int> bulkimport(BenchDataset data, String baseDir);

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

  /// The 50 largest debits across all accounts — `amountMinor ASC`, ties by
  /// string id `ASC`, limit 50 — [bigspendRuns] executions, timed per run.
  /// Returns the per-run durations in microseconds, in the order asked.
  Future<List<int>> bigspendUs(String baseDir);

  /// The ids the bigspend query returns, for the smoke/verify checks.
  Future<List<String>> bigspendIds(String baseDir);

  /// Pages every txn with `amountMinor` in `[amountBandLo, amountBandHi)`
  /// (all accounts) by [amountRangePageSize], `amountMinor ASC`, ties by id
  /// `ASC`, and returns every id in order.
  Future<List<String>> amountRangeIds(String baseDir);

  /// Pages every `pending` txn of [rangeMonthKey] (all accounts) by
  /// [rangePageSize], `bookedOn ASC`, ties by id `ASC`, and returns every
  /// id in order.
  Future<List<String>> pendingMonthIds(String baseDir);

  /// One account's history newest-first, [deeppagePageCount] pages of
  /// [deeppagePageSize] documents by the engine's own paging idiom, in page
  /// order: each page's ids and the page's duration in microseconds. Fewer
  /// pages when the history runs out first.
  Future<({List<List<String>> pageIds, List<int> pageUs})> deeppagePages(
    String accountId,
    String baseDir,
  );

  /// Counts the `pending` txns across all accounts, [countRuns] times:
  /// per-run durations in microseconds, in order, and the count they must
  /// all reproduce.
  Future<({List<int> us, int count})> pendingCountUs(String baseDir);

  /// Counts one account's txns in [reportYear], [countRuns] times: per-run
  /// durations in microseconds, in order, and the count they must all
  /// reproduce.
  Future<({List<int> us, int count})> yearCountUs(
    String accountId,
    String baseDir,
  );

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

/// The fixed amount band the amount-range op reads, chosen once from the
/// dataset's distribution so it returns ~1% of the rows: measured 0.96% at
/// 10k, 1.00% at 100k, 1.00% at 300k txns (the amounts are
/// ±(100..990099) minor units, 40% negative; the band sits on the credit
/// side, 16500 units wide).
const amountBandLo = 150000;

/// The exclusive upper bound of the amount band (see [amountBandLo]).
const amountBandHi = 166500;

/// The page size the amount-range op reads by.
const amountRangePageSize = 100;

/// How many times the bigspend query runs per measurement.
const bigspendRuns = 50;

/// How many pages the deep-page op walks into one account's history.
const deeppagePageCount = 20;

/// The page size the deep-page op reads by.
const deeppagePageSize = 50;

/// How many accounts the deep-page op runs over (`a00`..`a09`).
const deeppageAccounts = 10;

/// How many times each count shape runs per measurement.
const countRuns = 20;

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

/// A process-level CPU and disk-write sampler around one measured section —
/// the cost side of an operation, next to its wall time.
///
/// - `cpuMs` reads the `/proc/self/stat` utime+stime delta (user+sys CPU of
///   the whole process: main isolate, native threads, isolates), converted
///   with the clock-tick rate `getconf CLK_TCK` reports;
/// - `diskWriteBytes` reads the `/proc/self/io` `write_bytes` delta — the
///   bytes the process caused to reach the storage layer over the section,
///   native and isolate threads included. Kernels built without io
///   accounting (WSL2's microsoft-standard kernel has no
///   `CONFIG_TASK_IO_ACCOUNTING`, so `/proc/*/io` does not exist) fall back
///   to the process's cgroup v2 `io.stat` (`wbytes` summed over devices),
///   with a `sync` at both ends of the section so dirty pages are
///   attributed before reading. That number covers the whole cgroup, so it
///   is only meaningful when the benchmark runs alone in its cgroup (the
///   matrix runs one process at a time); `diskWriteSource` in `env` says
///   which source was used. With neither source, [stop] reports `null` and
///   the key is omitted rather than shown as a lying zero.
///
/// Reads are deltas, so one process may bracket several sections; peak RSS
/// is a process high-water mark and can only be read per process, which is
/// why every measurement is its own fresh `dart run` process.
final class OpCost {
  OpCost._(this._cpuTicks0, this._writeBytes0);

  final int _cpuTicks0;
  final int? _writeBytes0;

  static int? _clkTck;

  /// Whether the kernel gives us per-process io accounting
  /// (`/proc/self/io` exists). Where it doesn't, `diskWriteBytes` is
  /// omitted from every op's result.
  static bool get ioAccountingAvailable =>
      File('/proc/self/io').existsSync() || _cgroupIoStat() != null;

  /// Where `diskWriteBytes` comes from on this machine: `proc` (per
  /// process), `cgroup` (the process's cgroup v2 `io.stat`) or `none`.
  static String get diskWriteSource => File('/proc/self/io').existsSync()
      ? 'proc'
      : (_cgroupIoStat() != null ? 'cgroup' : 'none');

  /// The process's cgroup v2 `io.stat` file, or `null` when there is none.
  static File? _cgroupIoStat() {
    try {
      for (final line in File('/proc/self/cgroup').readAsLinesSync()) {
        if (line.startsWith('0::')) {
          // Without a cgroup namespace (e.g. inside Docker) the path is the
          // host's while /sys/fs/cgroup is mounted at the container's
          // sub-tree: try the longest suffix that exists.
          final parts = line
              .substring(3)
              .split('/')
              .where((part) => part.isNotEmpty)
              .toList();
          for (var i = 0; i < parts.length; i++) {
            final file = File(
              '/sys/fs/cgroup/${parts.sublist(i).join('/')}/io.stat',
            );
            if (file.existsSync()) {
              return file;
            }
          }
          return null;
        }
      }
    } on Object {
      // No cgroup v2: no fallback.
    }
    return null;
  }

  /// The kernel's clock-tick rate (`getconf CLK_TCK`), read once; 100 is
  /// the Linux default when `getconf` is unavailable.
  static int clkTck() {
    final cached = _clkTck;
    if (cached != null) {
      return cached;
    }
    var ticks = 100;
    try {
      final result = Process.runSync('getconf', ['CLK_TCK']);
      final parsed = int.tryParse(result.stdout.toString().trim());
      if (parsed != null && parsed > 0) {
        ticks = parsed;
      }
    } on Object {
      // No getconf: keep the Linux default.
    }
    return _clkTck = ticks;
  }

  /// The process's utime+stime total, in clock ticks.
  static int _cpuTicks() {
    try {
      final stat = File('/proc/self/stat').readAsStringSync();
      // Fields 1-2 (pid, comm) may contain spaces and parentheses; comm ends
      // at the LAST ')'. After it: state (field 3) first, so utime (field
      // 14) is remainder index 11 and stime (field 15) index 12.
      final fields = stat
          .substring(stat.lastIndexOf(')') + 2)
          .trim()
          .split(' ');
      return int.parse(fields[11]) + int.parse(fields[12]);
    } on Object {
      return 0;
    }
  }

  /// The process's `write_bytes` total from `/proc/self/io`, or `null` when
  /// the kernel has no io accounting.
  static int? _writeBytes() {
    try {
      for (final line in File('/proc/self/io').readAsLinesSync()) {
        if (line.startsWith('write_bytes:')) {
          return int.parse(line.substring('write_bytes:'.length).trim());
        }
      }
    } on Object {
      // No procfs io (kernel without io accounting): try the cgroup.
    }
    final ioStat = _cgroupIoStat();
    if (ioStat == null) {
      return null;
    }
    try {
      // Flush dirty pages first so writeback is attributed to the cgroup
      // before reading; outside every timed section by construction.
      Process.runSync('sync', const []);
      var total = 0;
      for (final line in ioStat.readAsLinesSync()) {
        final match = RegExp(r'wbytes=(\d+)').firstMatch(line);
        if (match != null) {
          total += int.parse(match.group(1)!);
        }
      }
      return total;
    } on Object {
      return null;
    }
  }

  /// Starts sampling; pair with [stop].
  static OpCost start() => OpCost._(_cpuTicks(), _writeBytes());

  /// Ends the section: (user+sys CPU ms, storage-layer bytes written) since
  /// [start]; the bytes are `null` where the kernel has no io accounting.
  ({int cpuMs, int? diskWriteBytes}) stop() {
    final bytes = _writeBytes();
    return (
      cpuMs: ((_cpuTicks() - _cpuTicks0) * 1000 / clkTck()).round(),
      diskWriteBytes: bytes == null || _writeBytes0 == null
          ? null
          : bytes - _writeBytes0,
    );
  }
}
