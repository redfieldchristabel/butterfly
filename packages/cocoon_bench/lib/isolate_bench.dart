/// The isolate-mode benchmark's core: seed one scope, run one operation in
/// one isolate mode, measure wall time, caller-isolate stalls and peak RSS.
///
/// One process measures ONE operation in ONE mode over the SAME seeded
/// database file, so the three modes' numbers are directly comparable: the
/// caller-isolate stall is sampled by a 1 ms periodic timer whose lateness
/// IS the event-loop gap. `bin/isolate_bench.dart` is the CLI shell.
///
/// All modes run `Durability.normal`: the question here is what moves
/// between isolates, not fsync behaviour, which is identical in all three.
library;

import 'dart:async';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_bench/dataset.dart';
import 'package:cocoon_bench/models.dart';

/// How many documents one seeded scope holds for the page/mixed operations.
const pageSeedSize = 10000;

/// How many documents the group and import operations work over.
const heavySeedSize = 100000;

/// How many documents the writes and latency operations work over.
const smallSeedSize = 1000;

/// How many times a repeatable operation runs; the reported wall time and
/// stall are the median run's.
const reps = 3;

/// How many single gets the latency operation times.
const latencyGets = 200;

/// How many single writes the writes operation runs.
const writesCount = 1000;

/// Samples the caller isolate's event loop with a 1 ms periodic timer: the
/// lateness of each firing is the event-loop stall since the previous one.
/// [stop] before reading the numbers, and always before the process exits —
/// a live timer chain would keep the VM running.
final class StallSampler {
  Timer? _timer;
  final Stopwatch _clock = Stopwatch()..start();
  double _nextDueMs = 0;
  double _longestMs = 0;
  double _totalMs = 0;
  var _over8ms = 0;

  StallSampler() {
    _schedule();
  }

  /// The longest single event-loop gap the sampler saw, in milliseconds.
  double get longestMs => _longestMs;

  /// The total blocked time (every firing's lateness beyond 0.25 ms of
  /// scheduler noise), in milliseconds.
  double get totalMs => _totalMs;

  /// How many gaps exceeded 8 ms (a dropped frame at 120 fps).
  int get over8ms => _over8ms;

  void _schedule() {
    _nextDueMs = _nowMs + 1.0;
    _timer = Timer(const Duration(milliseconds: 1), _fire);
  }

  void _fire() {
    final lateMs = _nowMs - _nextDueMs;
    if (lateMs > 0.25) {
      _totalMs += lateMs;
      if (lateMs > _longestMs) {
        _longestMs = lateMs;
      }
      if (lateMs > 8) {
        _over8ms++;
      }
    }
    _schedule();
  }

  /// Stops sampling. The counters freeze; the event loop is free to end.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  double get _nowMs => _clock.elapsedMicroseconds / 1000.0;
}

/// One measured operation's numbers.
final class OpResult {
  OpResult({
    required this.mode,
    required this.op,
    required this.wallMs,
    required this.longestStallMs,
    required this.totalStallMs,
    required this.stallsOver8ms,
    required this.extra,
  });

  final String mode;
  final String op;
  final double wallMs;
  final double longestStallMs;
  final double totalStallMs;
  final int stallsOver8ms;
  final Map<String, Object?> extra;
}

CocoonOptions _options(CocoonIsolate mode) =>
    CocoonOptions(durability: Durability.normal, isolate: mode);

/// The one scope every operation works over: account `a00`'s txns.
CollectionRef<Txn> _scope(Cocoon db) =>
    db.collection(accounts).doc('a00').collection(txns);

DocRef<Txn> _txnRef(Cocoon db, String id) => _scope(db).doc(id);

/// Seeds [size] txns into one scope at [path] with a bulk writer (the
/// import path), in caller mode — seeding is never measured. The file is
/// recreated from scratch.
Future<void> seedScope(String path, int size) async {
  final file = File(path);
  if (file.existsSync()) {
    file.deleteSync();
  }
  for (final sidecar in ['-wal', '-shm']) {
    final sidecarFile = File('$path$sidecar');
    if (sidecarFile.existsSync()) {
      sidecarFile.deleteSync();
    }
  }
  Directory(file.parent.path).createSync(recursive: true);
  final data = BenchDataset.build(txnCount: size);
  final db = await Cocoon.open(
    path,
    collections: [accounts, txns],
    options: CocoonOptions(durability: Durability.normal),
  );
  try {
    final writer = db.bulkWriter();
    for (var i = 0; i < size; i++) {
      // The dataset's Txn carries no account: the scope path is the parent,
      // so every document lands in a00's collection with its stable id.
      writer.set(_txnRef(db, data.txns[i].id), data.txns[i].txn);
    }
    await writer.close();
  } finally {
    await db.close();
  }
}

/// Runs one operation once; returns its wall time and the sampler's report.
/// The sampler is stopped before returning so its counters freeze and no
/// timer chain outlives the measurement.
Future<(double, StallSampler)> _timed(Future<void> Function() body) async {
  final sampler = StallSampler();
  final sw = Stopwatch()..start();
  try {
    await body();
  } on Object {
    sampler.stop();
    rethrow;
  }
  sw.stop();
  sampler.stop();
  return (sw.elapsedMicroseconds / 1000.0, sampler);
}

/// The median run of [runs].
(double, StallSampler) _median(List<(double, StallSampler)> runs) {
  final sorted = [...runs]..sort((a, b) => a.$1.compareTo(b.$1));
  return sorted[sorted.length ~/ 2];
}

OpResult _result(
  CocoonIsolate mode,
  String op,
  (double, StallSampler) median,
  Map<String, Object?> extra,
) => OpResult(
  mode: mode.name,
  op: op,
  wallMs: median.$1,
  longestStallMs: median.$2.longestMs,
  totalStallMs: median.$2.totalMs,
  stallsOver8ms: median.$2.over8ms,
  extra: extra,
);

/// Runs [op] (`page`, `group`, `import`, `latency`, `writes`, `mixed`) in
/// [mode] over the database seeded at [path]. The database must hold
/// [size] seeded documents; the ops read exactly what their size needs.
Future<OpResult> runIsolateOp({
  required CocoonIsolate mode,
  required String op,
  required int size,
  required String path,
}) async {
  final db = await Cocoon.open(
    path,
    collections: [accounts, txns],
    options: _options(mode),
  );
  try {
    switch (op) {
      case 'page':
        // One page read of the whole seeded scope, [reps] times; the median
        // run counts.
        final runs = <(double, StallSampler)>[];
        for (var i = 0; i < reps; i++) {
          runs.add(
            await _timed(() async {
              final page = await _scope(db).query().limit(size).get();
              if (page.docs.length != size) {
                throw StateError('page: got ${page.docs.length} docs');
              }
            }),
          );
        }
        return _result(mode, op, _median(runs), {'reps': reps, 'docs': size});
      case 'group':
        // A group-by over every row in the scope: one group per bookedOn
        // day, counting rows. SQL scans every row; the result crossing
        // isolates is the group list, not the rows.
        final dayKey = key(Txn$.bookedOn);
        final runs = <(double, StallSampler)>[];
        for (var i = 0; i < reps; i++) {
          runs.add(
            await _timed(() async {
              final groups = await _scope(
                db,
              ).groupBy([dayKey]).aggregate([count()]).get();
              if (groups.isEmpty) {
                throw StateError('group: no groups');
              }
            }),
          );
        }
        return _result(mode, op, _median(runs), {'rows': size});
      case 'import':
        // A fresh id range every rep, so each rep imports [size] new rows
        // through a bulk writer (the same path an app's bulk load takes).
        final data = BenchDataset.build(txnCount: size);
        final runs = <(double, StallSampler)>[];
        for (var i = 0; i < reps; i++) {
          final offset = i * size;
          runs.add(
            await _timed(() async {
              final writer = db.bulkWriter();
              for (var j = 0; j < size; j++) {
                writer.set(
                  _txnRef(db, 'x${(offset + j).toString().padLeft(9, '0')}'),
                  data.txns[j].txn,
                );
              }
              await writer.close();
            }),
          );
        }
        return _result(mode, op, _median(runs), {'docs': size, 'reps': reps});
      case 'latency':
        // Single get round trips against seeded documents, one by one; the
        // wall time covers all [latencyGets] gets and the stall sampler
        // runs across all of them.
        final dataset = BenchDataset.build(txnCount: size);
        final sampler = StallSampler();
        final sw = Stopwatch()..start();
        try {
          final micros = <int>[];
          for (var i = 0; i < latencyGets; i++) {
            final id = dataset.txns[i % size].id;
            final one = Stopwatch()..start();
            final snap = await _txnRef(db, id).get();
            one.stop();
            if (snap == null) {
              throw StateError('latency: $id missing');
            }
            micros.add(one.elapsedMicroseconds);
          }
          sw.stop();
          micros.sort();
          sampler.stop();
          return OpResult(
            mode: mode.name,
            op: op,
            wallMs: sw.elapsedMicroseconds / 1000.0,
            longestStallMs: sampler.longestMs,
            totalStallMs: sampler.totalMs,
            stallsOver8ms: sampler.over8ms,
            extra: {
              'p50Us': micros[micros.length ~/ 2],
              'p95Us':
                  micros[(micros.length * 95 ~/ 100).clamp(
                    0,
                    micros.length - 1,
                  )],
              'gets': latencyGets,
            },
          );
        } on Object {
          sampler.stop();
          rethrow;
        }
      case 'writes':
        final dataset = BenchDataset.build(txnCount: size);
        final runs = <(double, StallSampler)>[];
        for (var i = 0; i < reps; i++) {
          runs.add(
            await _timed(() async {
              for (var j = 0; j < writesCount; j++) {
                final benchTxn = dataset.txns[j % size];
                await _txnRef(db, benchTxn.id).set(benchTxn.txn);
              }
            }),
          );
        }
        return _result(mode, op, _median(runs), {'writes': writesCount});
      case 'mixed':
        // [writesCount] single writes with a whole-scope page read after
        // every 50th write — the interleaving a live finance app produces.
        // One long run.
        final dataset = BenchDataset.build(txnCount: size);
        final sampler = StallSampler();
        final sw = Stopwatch()..start();
        try {
          var pagesRead = 0;
          for (var j = 0; j < writesCount; j++) {
            final benchTxn = dataset.txns[j % size];
            await _txnRef(db, benchTxn.id).set(benchTxn.txn);
            if (j % 50 == 49) {
              final page = await _scope(db).query().limit(size).get();
              pagesRead++;
              if (page.docs.length != size) {
                throw StateError('mixed: page of ${page.docs.length}');
              }
            }
          }
          sw.stop();
          sampler.stop();
          return OpResult(
            mode: mode.name,
            op: op,
            wallMs: sw.elapsedMicroseconds / 1000.0,
            longestStallMs: sampler.longestMs,
            totalStallMs: sampler.totalMs,
            stallsOver8ms: sampler.over8ms,
            extra: {'writes': writesCount, 'pages': pagesRead},
          );
        } on Object {
          sampler.stop();
          rethrow;
        }
      default:
        throw StateError('unknown op $op');
    }
  } finally {
    await db.close();
  }
}
