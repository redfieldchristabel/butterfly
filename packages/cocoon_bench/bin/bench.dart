/// The benchmark CLI. One process measures one engine for one operation, so
/// memory numbers never leak between runs:
///
/// ```sh
/// dart run bin/bench.dart --engine cocoon --size 100000 --op import
/// ```
///
/// Only `import` builds the typed dataset. Every other operation works from
/// the database itself (account ids are deterministic from the seed, ids and
/// values to read/write are sampled from the engine after open), so the
/// memory those operations measure is the engine's, not the harness's. The
/// `baseline` operation reports what a bare `dart run` of this harness costs
/// with nothing opened — subtract it from the memory numbers to get the
/// engine's own share.
///
/// Cocoon's tuning knobs are selectable without touching the defaults the
/// other runs use:
///
/// ```sh
/// dart run bin/bench.dart --engine cocoon --size 100000 --op write --durability normal
/// dart run bin/bench.dart --engine cocoon --size 100000 --op gets2 --cache-size 20000
/// ```
///
/// The last stdout line is the JSON result; everything before it is human
/// progress. See `tool/run_all.sh` for the full matrix.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon/cocoon.dart' show CocoonOptions, Durability;
import 'package:cocoon_bench/cocoon_engine.dart';
import 'package:cocoon_bench/dataset.dart';
import 'package:cocoon_bench/engine.dart';
import 'package:cocoon_bench/sembast_engine.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

/// The read shapes a finance app runs, used by the `rss` operation.
const rssReadAccounts = 200;
const rssReadGetCount = 1000;

/// How many documents the `gets` and `gets2` operations read by id.
const getsCount = 1000;

/// How many documents the `write` operation rewrites.
const writeCount = 200;

/// The seed every database-side sample uses, so ids and values are identical
/// in every process over the same database.
const sampleSeed = 424242;

Future<void> main(List<String> args) async {
  // The cold-open measurement starts here: `dart run` pays VM + kernel load
  // before main, roughly constant for both engines.
  final processWatch = Stopwatch()..start();
  String? engineName;
  var size = 0;
  String? op;
  var durability = Durability.full;
  var keepChanges = true;
  var cacheSize = CocoonOptions.defaultCacheSize;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--engine':
        engineName = args[++i];
      case '--size':
        size = int.parse(args[++i]);
      case '--op':
        op = args[++i];
      case '--durability':
        switch (args[++i]) {
          case 'full':
            durability = Durability.full;
          case 'normal':
            durability = Durability.normal;
          default:
            stderr.writeln('Unknown durability ${args[i]}');
            exit(2);
        }
      case '--keep-changes':
        final value = args[++i];
        if (value != 'true' && value != 'false') {
          stderr.writeln('--keep-changes wants true or false, got $value');
          exit(2);
        }
        keepChanges = value == 'true';
      case '--cache-size':
        cacheSize = int.parse(args[++i]);
      default:
        stderr.writeln('Unknown argument ${args[i]}');
        exit(2);
    }
  }
  if (op == null) {
    stderr.writeln(
      'Usage: dart run bin/bench.dart [--engine cocoon|sembast --size N] '
      '--op baseline|env|import|open|rss|latest50|monthly|gets|gets2|write '
      '[--durability full|normal] [--keep-changes true|false] '
      '[--cache-size N]',
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
  if (engineName != 'cocoon' &&
      (durability != Durability.full ||
          !keepChanges ||
          cacheSize != CocoonOptions.defaultCacheSize)) {
    stderr.writeln(
      '--durability/--keep-changes/--cache-size are Cocoon knobs; '
      'use --engine cocoon',
    );
    exit(2);
  }
  // Echo the knobs so the result file says what it measured.
  if (durability != Durability.full) {
    metrics['durability'] = durability.name;
  }
  if (!keepChanges) {
    metrics['keepChanges'] = keepChanges;
  }
  if (cacheSize != CocoonOptions.defaultCacheSize) {
    metrics['cacheSize'] = cacheSize;
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

  final BenchEngine engine = engineName == 'cocoon'
      ? CocoonBenchEngine(
          durability: durability,
          keepChanges: keepChanges,
          cacheSize: cacheSize,
        )
      : SembastBenchEngine();
  final baseDir =
      '${Platform.environment['TMPDIR'] ?? '/tmp'}/'
      'cocoon_bench_${engineName}_$size';
  // The seeded rng for the read shapes' account picks; samples use their own
  // [sampleSeed] stream so these picks stay byte-identical to earlier runs.
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
      case 'gets2':
        // The cache-size experiment: the same 1,000 random ids read twice in
        // one process — cold against an empty cache, warm from it — with the
        // RSS after each, so the RAM/speed trade shows up side by side.
        await engine.open(baseDir);
        final ids = _idsOf(await _sample(engine, baseDir, getsCount));
        final (coldMs, hits) = await engine.getsById(ids, baseDir);
        _expectAllFound(hits, ids.length, op);
        final rssAfterCold = ProcessInfo.currentRss;
        final (warmMs, warmHits) = await engine.getsById(ids, baseDir);
        _expectAllFound(warmHits, ids.length, op);
        metrics
          ..[Metrics.coldMs] = coldMs
          ..[Metrics.warmMs] = warmMs
          ..[Metrics.rssAfterColdBytes] = rssAfterCold
          ..[Metrics.rssAfterWarmBytes] = ProcessInfo.currentRss
          ..[Metrics.count] = ids.length
          ..[Metrics.found] = hits
          ..[Metrics.peakRssBytes] = ProcessInfo.maxRss;
      case 'write':
        await engine.open(baseDir);
        final docs = await _sample(engine, baseDir, writeCount);
        final micros = await engine.writeUs(docs, baseDir);
        final p = percentiles(micros);
        metrics
          ..[Metrics.p50Us] = p.p50Us
          ..[Metrics.p95Us] = p.p95Us
          ..[Metrics.queries] = p.count;
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
