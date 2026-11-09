import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/cocoon_engine.dart';
import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/drift_engine.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/hive_engine.dart';
import 'package:cocoon_rivals/isar_engine.dart';
import 'package:cocoon_rivals/models.dart' as m;
import 'package:cocoon_rivals/objectbox_engine.dart';
import 'package:cocoon_rivals/sembast_engine.dart';
import 'package:test/test.dart';

/// Every engine under test, built fresh per test; [backupFile] is the small
/// NDJSON file the `restore` test feeds every engine.
List<BenchEngine> engines(String backupFile) => [
  CocoonBenchEngine(backupFile: backupFile),
  CocoonBenchEngine(durability: Durability.normal, backupFile: backupFile),
  DriftBenchEngine(backupFile: backupFile),
  IsarBenchEngine(backupFile: backupFile),
  ObjectBoxBenchEngine(backupFile: backupFile),
  HiveBenchEngine(backupFile: backupFile),
  SembastBenchEngine(backupFile: backupFile),
];

/// Each engine works in its own subdirectory of the shared temp dir, so
/// database files never collide.
String baseDirFor(BenchEngine engine, Directory tempDir) =>
    '${tempDir.path}/${engine.name}';

/// The contract order of one account's latest txns: bookedOn DESC, ties by
/// the string id DESC.
List<String> canonicalLatest(BenchDataset data, String accountId, int limit) {
  final txns = data.txnsOf(accountId).toList()
    ..sort((a, b) {
      final byDay = b.txn.bookedOn.compareTo(a.txn.bookedOn);
      return byDay != 0 ? byDay : b.id.compareTo(a.id);
    });
  return [for (final benchTxn in txns.take(limit)) benchTxn.id];
}

/// The contract order of one month's txns across all accounts: bookedOn ASC,
/// ties by the string id ASC.
List<String> canonicalRange(BenchDataset data, int month) {
  final firstDay = month * 100 + 1;
  final lastDay = month * 100 + 31;
  final txns = data.txns
      .where((t) => t.txn.bookedOn >= firstDay && t.txn.bookedOn <= lastDay)
      .toList()
    ..sort((a, b) {
      final byDay = a.txn.bookedOn.compareTo(b.txn.bookedOn);
      return byDay != 0 ? byDay : a.id.compareTo(b.id);
    });
  return [for (final benchTxn in txns) benchTxn.id];
}

/// The pending txns' ids in the latest-50 contract order.
List<String> canonicalStatus(BenchDataset data, int limit) {
  final txns = data.txns
      .where((t) => t.txn.status == m.TxnStatus.pending)
      .toList()
    ..sort((a, b) {
      final byDay = b.txn.bookedOn.compareTo(a.txn.bookedOn);
      return byDay != 0 ? byDay : b.id.compareTo(a.id);
    });
  return [for (final benchTxn in txns.take(limit)) benchTxn.id];
}

/// Per-account per-month sums of one year across every account, keyed
/// `<accountId>|<yyyyMM>` — the shape [BenchEngine.yearReport] returns.
Map<String, int> canonicalYearSums(BenchDataset data, int year) {
  final sums = <String, int>{};
  for (final benchTxn in data.txns) {
    final bookedOn = benchTxn.txn.bookedOn;
    if (bookedOn ~/ 10000 != year) {
      continue;
    }
    final month = bookedOn ~/ 100 % 100;
    final key = '${benchTxn.accountId}|${year * 100 + month}';
    sums[key] = (sums[key] ?? 0) + benchTxn.txn.amountMinor;
  }
  return sums;
}

/// Imports [data] into [engine] under [tempDir] and opens it.
Future<void> seed(
  BenchEngine engine,
  BenchDataset data,
  Directory tempDir,
) async {
  final baseDir = baseDirFor(engine, tempDir);
  engine.wipe(baseDir);
  Directory(baseDir).createSync(recursive: true);
  await engine.import(data, baseDir);
  await engine.open(baseDir);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cocoon_rivals_smoke');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    '500 txns: every engine returns identical, contract-ordered results for '
    'every workload',
    () async {
      final data = BenchDataset.build(txnCount: 500);
      final list = engines('${tempDir.path}/backup_500.ndjson');
      try {
        for (final engine in list) {
          await seed(engine, data, tempDir);
        }
        for (final engine in list) {
          final baseDir = baseDirFor(engine, tempDir);
          final reason = engine.name;

          // Latest-50 ids per account, against the dataset's canonical
          // order (bookedOn DESC, id DESC).
          for (final account in ['a00', 'a07', 'a13', 'a19']) {
            expect(
              await engine.latest50Ids(account, baseDir),
              canonicalLatest(data, account, 50),
              reason: '$reason: latest-50 ids of $account',
            );
          }

          // One account's monthly totals, against the dataset.
          final (:totals, scanned: scanned) = await engine.monthlyTotalsMap(
            'a05',
            2024,
            baseDir,
          );
          expect(totals, data.monthlyTotalsOf('a05', 2024), reason: reason);

          // The all-accounts month range, against the dataset's canonical
          // order (bookedOn ASC, id ASC).
          expect(
            await engine.rangeMonthIds(baseDir),
            canonicalRange(data, rangeMonthKey),
            reason: '$reason: range ids',
          );

          // The year report across every account, against the dataset.
          final (yearMs, sums, accountsCovered) = await engine.yearReport(
            baseDir,
          );
          expect(sums, canonicalYearSums(data, reportYear), reason: reason);
          expect(accountsCovered, 20, reason: '$reason: accounts covered');
          expect(yearMs, isNonNegative, reason: reason);

          // The status search, against the dataset's canonical order.
          expect(
            await engine.statusSearchIds(baseDir),
            canonicalStatus(data, 50),
            reason: '$reason: status ids',
          );

          // The dataset-free paths the memory measurements rely on: a
          // deterministic sample, every id found, every write-back landed,
          // and the sync writer's doc readable.
          final sample = await engine.sampleDocs(
            baseDir,
            100,
            Random(7),
          );
          expect(sample, hasLength(100), reason: reason);
          final sameSeed = await engine.sampleDocs(baseDir, 100, Random(7));
          expect(
            [for (final doc in sameSeed) doc.id],
            [for (final doc in sample) doc.id],
            reason: '$reason: same seed, same sample',
          );
          final ids = [
            for (final doc in sample) (accountId: doc.accountId, id: doc.id),
          ];
          final (elapsed, hits) = await engine.getsById(ids, baseDir);
          expect(hits, 100, reason: '$reason: sampled ids all found');
          expect(elapsed, isNonNegative, reason: reason);
          final micros = await engine.writeUs(sample, baseDir);
          expect(micros, hasLength(100), reason: reason);
          final (_, rehits) = await engine.getsById(ids, baseDir);
          expect(rehits, 100, reason: '$reason: written-back ids all found');

          await engine.writeOneTxn('a03', 'w000000001', 1);
          final (_, writerHits) = await engine.getsById(
            [(accountId: 'a03', id: 'w000000001')],
            baseDir,
          );
          expect(writerHits, 1, reason: '$reason: sync write landed');
        }

        // Cross-engine: every engine's read shapes agree with Cocoon's.
        final cocoon = list.first;
        final cocoonDir = baseDirFor(cocoon, tempDir);
        for (final engine in list.skip(1)) {
          final baseDir = baseDirFor(engine, tempDir);
          for (final account in ['a00', 'a19']) {
            expect(
              await engine.latest50Ids(account, baseDir),
              await cocoon.latest50Ids(account, cocoonDir),
              reason: '${engine.name} vs ${cocoon.name}: latest-50 $account',
            );
          }
          expect(
            await engine.rangeMonthIds(baseDir),
            await cocoon.rangeMonthIds(cocoonDir),
            reason: '${engine.name} vs ${cocoon.name}: range ids',
          );
          expect(
            await engine.statusSearchIds(baseDir),
            await cocoon.statusSearchIds(cocoonDir),
            reason: '${engine.name} vs ${cocoon.name}: status ids',
          );
        }
      } finally {
        for (final engine in list) {
          await engine.close();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    '5000 txns: the tie-heavy month range and latest-50 stay identical '
    '(equal bookedOn days are common at this size)',
    () async {
      final data = BenchDataset.build(txnCount: 5000);
      // The tie density this test relies on: same-day txns within the
      // measured month, so any engine whose tie order drifts from the
      // contract breaks the list.
      final monthTxns = canonicalRange(data, rangeMonthKey);
      var sameDayPairs = 0;
      for (var i = 1; i < monthTxns.length; i++) {
        final a = data.txns.firstWhere((t) => t.id == monthTxns[i - 1]);
        final b = data.txns.firstWhere((t) => t.id == monthTxns[i]);
        if (a.txn.bookedOn == b.txn.bookedOn) {
          sameDayPairs++;
        }
      }
      expect(sameDayPairs, greaterThan(0), reason: 'test needs bookedOn ties');

      final list = engines('${tempDir.path}/backup_5000.ndjson');
      try {
        for (final engine in list) {
          await seed(engine, data, tempDir);
        }
        final cocoon = list.first;
        final cocoonDir = baseDirFor(cocoon, tempDir);
        expect(
          await cocoon.rangeMonthIds(cocoonDir),
          monthTxns,
          reason: 'cocoon range ids against the dataset',
        );
        for (final engine in list.skip(1)) {
          final baseDir = baseDirFor(engine, tempDir);
          expect(
            await engine.rangeMonthIds(baseDir),
            monthTxns,
            reason: '${engine.name}: tie-heavy range ids',
          );
          expect(
            await engine.latest50Ids('a05', baseDir),
            await cocoon.latest50Ids('a05', cocoonDir),
            reason: '${engine.name} vs cocoon: tie-heavy latest-50',
          );
        }
      } finally {
        for (final engine in list) {
          await engine.close();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'restore: every engine rebuilds a 500-txn NDJSON backup into the same '
    'readable history',
    () async {
      final data = BenchDataset.build(txnCount: 500);
      final backupFile =
          '${tempDir.path}/backup_500.ndjson';
      final sink = File(backupFile).openWrite();
      for (final benchTxn in data.txns) {
        sink.writeln(jsonEncode(backupLineOf(benchTxn)));
      }
      await sink.close();

      final list = engines(backupFile);
      try {
        for (final engine in list) {
          final baseDir = baseDirFor(engine, tempDir);
          Directory(baseDir).createSync(recursive: true);
          final (elapsed, restored) = await engine.restore(baseDir);
          expect(restored, 500, reason: engine.name);
          expect(elapsed, isNonNegative, reason: engine.name);
          await engine.open(baseDir);
          expect(
            await engine.latest50Ids('a05', baseDir),
            canonicalLatest(data, 'a05', 50),
            reason: '${engine.name}: restored latest-50',
          );
          final (:totals, scanned: _) = await engine.monthlyTotalsMap(
            'a05',
            2024,
            baseDir,
          );
          expect(totals, data.monthlyTotalsOf('a05', 2024),
              reason: '${engine.name}: restored monthly totals');
        }
      } finally {
        for (final engine in list) {
          await engine.close();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
