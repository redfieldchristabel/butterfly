/// The rivals benchmark CLI. One process measures one engine for one
/// operation, so memory numbers never leak between runs:
///
/// ```sh
/// dart run bin/bench.dart --engine drift --size 100000 --op import
/// ```
///
/// Only `import` builds the typed dataset. Every other operation works from
/// the database itself (account ids are deterministic from the seed, ids and
/// values to read/write are sampled from the engine after open) or from the
/// shared NDJSON backup file (`restore`, which builds the file once when it
/// is missing — untimed). The `baseline` operation reports what a bare
/// `dart run` of this harness costs with nothing opened — subtract it from
/// the memory numbers to get the engine's own share.
///
/// Engines: `cocoon` (defaults), `cocoon-normal` (`Durability.normal`),
/// `drift`, `isar`, `objectbox`, `hive`, `sembast`.
///
/// The `rww` op (read-while-write) runs its writer as an in-process async
/// loop, one `writeOneTxn` every [rwwIntervalMs] ms, instead of a separate
/// isolate: every engine here is documented single-owner of its file
/// (Cocoon's contract, drift's background isolate, Isar/ObjectBox/Hive/
/// sembast instances), so a second isolate would mean a second instance on
/// the same file — a different workload ("two processes fighting over a
/// lock") on every engine. The cadence is identical for all engines.
///
/// The last stdout line is the JSON result; everything before it is human
/// progress. See `tool/run_all.sh` for the full matrix.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon/cocoon.dart' show Durability;
import 'package:cocoon_rivals/cocoon_engine.dart';
import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/drift_engine.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/hive_engine.dart';
import 'package:cocoon_rivals/isar_engine.dart';
import 'package:cocoon_rivals/objectbox_engine.dart';
import 'package:cocoon_rivals/sembast_engine.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

/// The read shapes a finance app runs, used by the `rss` operation.
const rssReadAccounts = 200;
const rssReadGetCount = 1000;

/// How many documents the `gets` operation reads by id.
const getsCount = 1000;

/// How many documents the `write` operation rewrites.
const writeCount = 200;

/// How many latest-50 queries the `rww` operation times.
const rwwQueries = 200;

/// The seed every database-side sample uses, so ids and values are identical
/// in every process over the same database.
const sampleSeed = 424242;

Future<void> main(List<String> args) async {
  // The cold-open measurement starts here: `dart run` pays VM + kernel load
  // before main, roughly constant for every engine.
  final processWatch = Stopwatch()..start();
  String? engineName;
  var size = 0;
  String? op;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--engine':
        engineName = args[++i];
      case '--size':
        size = int.parse(args[++i]);
      case '--op':
        op = args[++i];
      default:
        stderr.writeln('Unknown argument ${args[i]}');
        exit(2);
    }
  }
  if (op == null) {
    stderr.writeln(
      'Usage: dart run bin/bench.dart --engine <name> --size N --op '
      'baseline|env|import|open|rss|latest50|monthly|gets|write|range|'
      'yearreport|statussearch|rww|restore|verify',
    );
    exit(2);
  }

  final metrics = <String, Object?>{
    'engine': engineName,
    'size': size,
    'op': op,
  };

  // The harness floor: nothing opened, nothing built — the engine's own
  // share of every memory number below is that number minus this one.
  if (op == 'baseline') {
    metrics
      ..['engine'] = 'none'
      ..[Metrics.rssBytes] = ProcessInfo.currentRss
      ..[Metrics.peakRssBytes] = ProcessInfo.maxRss;
    _printResult(metrics);
    return;
  }

  if (engineName == null || size == 0) {
    stderr.writeln('--engine and --size are required for --op $op');
    exit(2);
  }

  if (op == 'env') {
    metrics
      ..['dart'] = Platform.version.split(' ').first
      ..['sqlite'] = raw_sqlite.sqlite3.version.libVersion
      ..['cpu'] = _cpuModel()
      ..['cores'] = Platform.numberOfProcessors
      ..['ramTotalMb'] = _totalRamMb();
    _printResult(metrics);
    return;
  }

  final BenchEngine engine = switch (engineName) {
    'cocoon' || 'cocoon-normal' => CocoonBenchEngine(
      durability: engineName == 'cocoon-normal'
          ? Durability.normal
          : Durability.full,
    ),
    'drift' => DriftBenchEngine(),
    'isar' => IsarBenchEngine(),
    'objectbox' => ObjectBoxBenchEngine(),
    'hive' => HiveBenchEngine(),
    'sembast' => SembastBenchEngine(),
    _ => throw ArgumentError.value(engineName, 'engine', 'Unknown engine'),
  };
  final baseDir =
      '${Platform.environment['TMPDIR'] ?? '/tmp'}/'
      'cocoon_rivals_${engineName}_$size';
  // The seeded rng for the read shapes' account picks; samples use their own
  // [sampleSeed] stream so these picks stay byte-identical across runs.
  final rng = Random(1337);
  final accountIds = benchAccountIds();

  try {
    switch (op) {
      case 'import':
        // The only operation that needs the typed dataset in RAM: it feeds
        // the bulk import.
        final data = BenchDataset.build(txnCount: size);
        engine.wipe(baseDir);
        Directory(baseDir).createSync(recursive: true);
        final elapsed = await engine.import(data, baseDir);
        metrics
          ..[Metrics.elapsedMs] = elapsed
          ..[Metrics.fileBytes] = engine.fileSize(baseDir)
          ..[Metrics.txns] = data.txns.length;

      case 'open':
        final engineOpenMs = await engine.coldOpen(
          baseDir,
          accountId: accountIds.first,
        );
        metrics
          ..[Metrics.openMs] = processWatch.elapsedMilliseconds
          ..['engineOpenMs'] = engineOpenMs;

      case 'rss':
        await engine.open(baseDir);
        metrics[Metrics.rssAfterOpenBytes] = await engine.rssAfterOpen(baseDir);
        // The read shapes below, then the steady state and the process peak.
        await engine.latest50Us([
          for (var i = 0; i < rssReadAccounts; i++)
            'a${rng.nextInt(20).toString().padLeft(2, '0')}',
        ], baseDir);
        await engine.monthlyTotals('a05', 2024, baseDir);
        await engine.getsById(
          _idsOf(await _sample(engine, baseDir, rssReadGetCount)),
          baseDir,
        );
        metrics
          ..[Metrics.rssAfterReadsBytes] = ProcessInfo.currentRss
          ..[Metrics.peakRssBytes] = ProcessInfo.maxRss;

      case 'latest50':
        await engine.open(baseDir);
        final micros = await engine.latest50Us([
          for (var i = 0; i < 200; i++)
            'a${rng.nextInt(20).toString().padLeft(2, '0')}',
        ], baseDir);
        final p = percentiles(micros);
        metrics
          ..[Metrics.p50Us] = p.p50Us
          ..[Metrics.p95Us] = p.p95Us
          ..[Metrics.queries] = p.count;

      case 'monthly':
        await engine.open(baseDir);
        final (elapsed, scanned, grandTotal) = await engine.monthlyTotals(
          'a05',
          2024,
          baseDir,
        );
        metrics
          ..[Metrics.elapsedMs] = elapsed
          ..[Metrics.docsScanned] = scanned
          ..[Metrics.grandTotalMinor] = grandTotal;

      case 'gets':
        await engine.open(baseDir);
        final ids = _idsOf(await _sample(engine, baseDir, getsCount));
        final (elapsed, hits) = await engine.getsById(ids, baseDir);
        _expectAllFound(hits, ids.length, op);
        metrics
          ..[Metrics.elapsedMs] = elapsed
          ..[Metrics.count] = ids.length
          ..[Metrics.found] = hits;

      case 'write':
        await engine.open(baseDir);
        final docs = await _sample(engine, baseDir, writeCount);
        final micros = await engine.writeUs(docs, baseDir);
        final p = percentiles(micros);
        metrics
          ..[Metrics.p50Us] = p.p50Us
          ..[Metrics.p95Us] = p.p95Us
          ..[Metrics.queries] = p.count;

      case 'range':
        await engine.open(baseDir);
        final sw = Stopwatch()..start();
        final ids = await engine.rangeMonthIds(baseDir);
        sw.stop();
        metrics
          ..[Metrics.elapsedMs] = sw.elapsedMilliseconds
          ..[Metrics.count] = ids.length
          ..[Metrics.pages] = (ids.length + rangePageSize - 1) ~/ rangePageSize;

      case 'verify':
        // The contract dump the at-scale correctness checks diff across
        // engines: every read shape's full output, no timing.
        await engine.open(baseDir);
        final latest = <String, List<String>>{};
        for (final account in ['a00', 'a07', 'a13', 'a19']) {
          latest[account] = await engine.latest50Ids(account, baseDir);
        }
        final (:totals, scanned: scanned) = await engine.monthlyTotalsMap(
          'a05',
          2024,
          baseDir,
        );
        final (yearMs, sums, accountsCovered) = await engine.yearReport(
          baseDir,
        );
        final rangeIds = await engine.rangeMonthIds(baseDir);
        final statusIds = await engine.statusSearchIds(baseDir);
        metrics
          ..['latest50'] = latest
          ..['monthly'] = {
            // JSON object keys are strings; the totals are keyed `yyyyMM`.
            for (final entry in totals.entries) '${entry.key}': entry.value,
          }
          ..['monthlyScanned'] = scanned
          ..['yearreport'] = sums
          ..['yearreportAccounts'] = accountsCovered
          ..['yearreportMs'] = yearMs
          ..['range'] = rangeIds
          ..['status'] = statusIds;

      case 'yearreport':
        await engine.open(baseDir);
        final (elapsed, sums, accountsCovered) = await engine.yearReport(
          baseDir,
        );
        var grandTotal = 0;
        for (final value in sums.values) {
          grandTotal += value;
        }
        metrics
          ..[Metrics.elapsedMs] = elapsed
          ..[Metrics.grandTotalMinor] = grandTotal
          ..[Metrics.accounts] = accountsCovered
          ..['months'] = sums.length;

      case 'statussearch':
        await engine.open(baseDir);
        final micros = await engine.statusSearchUs(baseDir);
        final p = percentiles(micros);
        metrics
          ..[Metrics.p50Us] = p.p50Us
          ..[Metrics.p95Us] = p.p95Us
          ..[Metrics.queries] = p.count;

      case 'rww':
        await engine.open(baseDir);
        // The writer: one new txn every [rwwIntervalMs] ms (wall clock),
        // counted; the reads run in parallel on the same event loop.
        var writes = 0;
        var writerDone = false;
        final clock = Stopwatch()..start();
        Future<void> writer() async {
          var seq = 0;
          while (!writerDone) {
            final tick = clock.elapsedMilliseconds;
            await engine.writeOneTxn(
              'a00',
              'w${seq.toString().padLeft(9, '0')}',
              seq,
            );
            writes++;
            seq++;
            final spent = clock.elapsedMilliseconds - tick;
            if (spent < rwwIntervalMs) {
              await Future<void>.delayed(
                Duration(milliseconds: rwwIntervalMs - spent),
              );
            }
          }
        }

        final writerFuture = writer();
        final micros = await engine.latest50Us([
          for (var i = 0; i < rwwQueries; i++)
            'a${rng.nextInt(20).toString().padLeft(2, '0')}',
        ], baseDir);
        writerDone = true;
        await writerFuture;
        final p = percentiles(micros);
        metrics
          ..[Metrics.p50Us] = p.p50Us
          ..[Metrics.p95Us] = p.p95Us
          ..[Metrics.queries] = p.count
          ..[Metrics.writes] = writes
          ..['intervalMs'] = rwwIntervalMs;

      case 'restore':
        // Untimed setup: the shared NDJSON backup, built once if missing.
        await ensureNdjsonBackup();
        // Restore wipes and rebuilds its own directory: the imported
        // database the read ops measure against stays untouched.
        final restoreDir = '${baseDir}_restore';
        final (elapsed, restored) = await engine.restore(restoreDir);
        _expect(restored == backupTxnCount, 'restore: $restored txns');
        metrics
          ..[Metrics.elapsedMs] = elapsed
          ..[Metrics.txns] = restored
          ..[Metrics.fileBytes] = engine.fileSize(restoreDir);

      default:
        stderr.writeln('Unknown op $op');
        exit(2);
    }
  } finally {
    await engine.close();
  }
  _printResult(metrics);
}

/// Samples [count] documents from the database itself, untimed: the ids and
/// values every non-import operation needs, without the typed dataset.
Future<List<SampledDoc>> _sample(
  BenchEngine engine,
  String baseDir,
  int count,
) => engine.sampleDocs(baseDir, count, Random(sampleSeed));

/// The (accountId, id) pairs of a sample, for the get-by-id reads.
List<({String accountId, String id})> _idsOf(List<SampledDoc> docs) => [
  for (final doc in docs) (accountId: doc.accountId, id: doc.id),
];

void _expectAllFound(int hits, int count, String op) {
  if (hits != count) {
    throw StateError('$op: found only $hits of $count documents');
  }
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

void _printResult(Map<String, Object?> metrics) {
  stdout.writeln(jsonEncode(metrics));
}

String _cpuModel() {
  try {
    for (final line in File('/proc/cpuinfo').readAsLinesSync()) {
      if (line.startsWith('model name')) {
        return line.substring(line.indexOf(':') + 2);
      }
    }
  } on Object {
    // Not Linux, or no cpuinfo: report unknown.
  }
  return 'unknown';
}

int _totalRamMb() {
  try {
    for (final line in File('/proc/meminfo').readAsLinesSync()) {
      if (line.startsWith('MemTotal:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]) ~/ 1024;
      }
    }
  } on Object {
    // Fall through to the unknown marker.
  }
  return -1;
}
