/// The benchmark CLI. One process measures one engine for one operation, so
/// memory numbers never leak between runs:
///
/// ```sh
/// dart run bin/bench.dart --engine cocoon --size 100000 --op import
/// ```
///
/// The last stdout line is the JSON result; everything before it is human
/// progress. See `tool/run_all.sh` for the full matrix.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon_bench/cocoon_engine.dart';
import 'package:cocoon_bench/dataset.dart';
import 'package:cocoon_bench/engine.dart';
import 'package:cocoon_bench/sembast_engine.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

/// The read shapes a finance app runs, used by the `rss` operation.
const rssReadAccounts = 200;
const rssReadGetCount = 1000;

Future<void> main(List<String> args) async {
  // The cold-open measurement starts here: `dart run` pays VM + kernel load
  // before main, roughly constant for both engines.
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
  if (engineName == null || size == 0 || op == null) {
    stderr.writeln(
      'Usage: dart run bin/bench.dart --engine cocoon|sembast '
      '--size N --op env|import|open|rss|latest50|monthly|gets|write',
    );
    exit(2);
  }

  final metrics = <String, Object?>{
    'engine': engineName,
    'size': size,
    'op': op,
  };

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
      ? CocoonBenchEngine()
      : SembastBenchEngine();
  final data = BenchDataset.build(txnCount: size);
  final baseDir =
      '${Platform.environment['TMPDIR'] ?? '/tmp'}/'
      'cocoon_bench_${engineName}_$size';
  final rng = Random(1337);

  try {
    switch (op) {
      case 'import':
        engine.wipe(baseDir);
        Directory(baseDir).createSync(recursive: true);
        final elapsed = await engine.import(data, baseDir);
        metrics
          ..[Metrics.elapsedMs] = elapsed
          ..[Metrics.fileBytes] = engine.fileSize(baseDir)
          ..[Metrics.txns] = data.txns.length;
      case 'open':
        final engineOpenMs = await engine.coldOpen(data, baseDir);
        metrics
          ..[Metrics.openMs] = processWatch.elapsedMilliseconds
          ..['engineOpenMs'] = engineOpenMs;
      case 'rss':
        metrics[Metrics.rssAfterOpenBytes] = await engine.rssAfterOpen(
          data,
          baseDir,
        );
        // The read shapes below, then the process peak.
        await engine.latest50Us([
          for (var i = 0; i < rssReadAccounts; i++)
            'a${rng.nextInt(20).toString().padLeft(2, '0')}',
        ], baseDir);
        await engine.monthlyTotals('a05', 2024, baseDir);
        await engine.getsById(_randomIds(data, rng, rssReadGetCount), baseDir);
        metrics[Metrics.peakRssBytes] = ProcessInfo.maxRss;
      case 'latest50':
        await engine.open(data, baseDir);
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
        await engine.open(data, baseDir);
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
        await engine.open(data, baseDir);
        final ids = _randomIds(data, rng, 1000);
        final (elapsed, hits) = await engine.getsById(ids, baseDir);
        metrics
          ..[Metrics.elapsedMs] = elapsed
          ..[Metrics.count] = ids.length
          ..[Metrics.found] = hits;
      case 'write':
        await engine.open(data, baseDir);
        final writes = [
          for (var i = 0; i < 200; i++)
            () {
              final t = data.txns[rng.nextInt(size)];
              return (accountId: t.accountId, id: t.id, txn: t);
            }(),
        ];
        final micros = await engine.writeUs(writes, baseDir);
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

/// [count] random dataset entries, as (accountId, id) pairs. One draw per
/// pair, so the id always belongs to the account it is paired with.
List<({String accountId, String id})> _randomIds(
  BenchDataset data,
  Random rng,
  int count,
) => [
  for (var i = 0; i < count; i++)
    () {
      final t = data.txns[rng.nextInt(data.txns.length)];
      return (accountId: t.accountId, id: t.id);
    }(),
];

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
