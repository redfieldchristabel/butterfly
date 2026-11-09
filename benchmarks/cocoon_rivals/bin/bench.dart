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
/// Besides each op's own results, every op reports the cost metrics
/// `peakRssBytes`, `cpuMs` and `diskWriteBytes` (see `lib/harness.dart` for
/// exactly what each covers), and `import` adds
/// `writeAmplification = diskWriteBytes / fileBytes`.
///
/// The last stdout line is the JSON result; everything before it is human
/// progress. See `tool/run_all.sh` for the full matrix.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon/cocoon.dart' show Durability;
import 'package:cocoon_rivals/cocoon_engine.dart';
import 'package:cocoon_rivals/dataset.dart'
    show backupTxnCount, benchAccountIds;
import 'package:cocoon_rivals/drift_engine.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/harness.dart';
import 'package:cocoon_rivals/hive_engine.dart';
import 'package:cocoon_rivals/isar_engine.dart';
import 'package:cocoon_rivals/objectbox_engine.dart';
import 'package:cocoon_rivals/sembast_engine.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

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
      '${benchOps.join('|')} (or `--op baseline|env` without an engine)',
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
      ..['ramTotalMb'] = _totalRamMb()
      ..['diskWriteSource'] = OpCost.diskWriteSource;
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
    await runOp(
      engine: engine,
      op: op,
      size: size,
      baseDir: baseDir,
      metrics: metrics,
      rng: rng,
      accountIds: accountIds,
    );
    // The cold-open number spans process start to first query; only this
    // function can see the process start.
    if (op == 'open') {
      metrics[Metrics.openMs] = processWatch.elapsedMilliseconds;
    }
    // The restore op measures against the shared full-size backup; a
    // partial restore means a truncated backup file.
    if (op == 'restore' &&
        metrics[Metrics.txns] != null &&
        metrics[Metrics.txns] != backupTxnCount) {
      throw StateError(
        'restore: ${metrics[Metrics.txns]} txns, expected $backupTxnCount',
      );
    }
  } finally {
    await engine.close();
  }
  _printResult(metrics);
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
