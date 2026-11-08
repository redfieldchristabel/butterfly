import 'dart:io';
import 'dart:math';

import 'package:cocoon_bench/cocoon_engine.dart';
import 'package:cocoon_bench/dataset.dart';
import 'package:cocoon_bench/sembast_engine.dart';
import 'package:test/test.dart';

/// Correctness before speed: both engines import the same 500-txn dataset
/// and must agree on every measured read shape — the latest-50 ids per
/// account and one account's monthly totals — before the numbers in
/// RESULTS.md mean anything. The dataset-free operations (`sampleDocs`,
/// `getsById`, `writeUs`) are checked too: they are how the harness measures
/// without the dataset in RAM, so their ids must exist and their write-backs
/// must land.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cocoon_bench_smoke');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    '500 txns: both engines return the same latest-50 ids and monthly totals',
    () async {
      final data = BenchDataset.build(txnCount: 500);
      final cocoon = CocoonBenchEngine();
      final sembast = SembastBenchEngine();
      try {
        await cocoon.import(data, tempDir.path);
        await sembast.import(data, tempDir.path);
        await cocoon.open(tempDir.path);
        await sembast.open(tempDir.path);

        // Latest-50 ids, newest first. Cocoon appends the id tiebreaker in
        // the direction of the last sort key (DESC here).
        for (final account in ['a00', 'a07', 'a13', 'a19']) {
          final cocoonIds = await cocoon.latest50Ids(account, tempDir.path);
          final sembastIds = await sembast.latest50Ids(account, tempDir.path);
          expect(cocoonIds, sembastIds, reason: 'latest-50 ids of $account');
          final expected = data.txnsOf(account).toList()
            ..sort((a, b) {
              final byDay = b.txn.bookedOn.compareTo(a.txn.bookedOn);
              return byDay != 0 ? byDay : b.id.compareTo(a.id);
            });
          expect(cocoonIds, [
            for (final benchTxn in expected) benchTxn.id,
          ], reason: 'latest-50 order of $account against the dataset');
        }

        // Monthly totals per account-year, against both engines and the
        // dataset itself.
        for (final year in [2022, 2023, 2024, 2025, 2026]) {
          final cocoonResult = await cocoon.monthlyTotalsMap(
            'a05',
            year,
            tempDir.path,
          );
          final sembastResult = await sembast.monthlyTotalsMap(
            'a05',
            year,
            tempDir.path,
          );
          final expected = data.monthlyTotalsOf('a05', year);
          expect(
            cocoonResult.totals,
            expected,
            reason: 'cocoon monthly totals $year',
          );
          expect(
            sembastResult.totals,
            expected,
            reason: 'sembast monthly totals $year',
          );
          expect(cocoonResult.scanned, sembastResult.scanned);
        }

        // Every account-year agrees too, not just a05.
        for (var i = 0; i < 20; i++) {
          final account = 'a${i.toString().padLeft(2, '0')}';
          for (final year in [2022, 2026]) {
            final cocoonResult = await cocoon.monthlyTotalsMap(
              account,
              year,
              tempDir.path,
            );
            final sembastResult = await sembast.monthlyTotalsMap(
              account,
              year,
              tempDir.path,
            );
            expect(
              cocoonResult.totals,
              sembastResult.totals,
              reason: '$account $year monthly totals',
            );
          }
        }
      } finally {
        await cocoon.close();
        await sembast.close();
      }
    },
  );

  test('sampleDocs draws the asked-for count, deterministically, and every id '
      'gets found', () async {
    final data = BenchDataset.build(txnCount: 500);
    final cocoon = CocoonBenchEngine();
    final sembast = SembastBenchEngine();
    try {
      await cocoon.import(data, tempDir.path);
      await sembast.import(data, tempDir.path);
      await cocoon.open(tempDir.path);
      await sembast.open(tempDir.path);

      for (final engine in [cocoon, sembast]) {
        final sample = await engine.sampleDocs(tempDir.path, 100, Random(7));
        expect(sample, hasLength(100), reason: engine.name);

        // Same seed, same sample — the harness relies on this to compare
        // runs; re-sampling with a fresh seeded rng must agree.
        final sameSeed = await engine.sampleDocs(tempDir.path, 100, Random(7));
        expect(
          [for (final doc in sameSeed) doc.id],
          [for (final doc in sample) doc.id],
          reason: '${engine.name}: same seed, same sample',
        );

        // Every sampled id exists: a get by id finds it.
        final ids = [
          for (final doc in sample) (accountId: doc.accountId, id: doc.id),
        ];
        final (elapsed, hits) = await engine.getsById(ids, tempDir.path);
        expect(hits, 100, reason: '${engine.name}: sampled ids all found');
        expect(elapsed, isNonNegative);
      }
    } finally {
      await cocoon.close();
      await sembast.close();
    }
  });

  test(
    'sampleDocs feeds writeUs: each write lands and the reads still hit',
    () async {
      final data = BenchDataset.build(txnCount: 500);
      final cocoon = CocoonBenchEngine();
      final sembast = SembastBenchEngine();
      try {
        await cocoon.import(data, tempDir.path);
        await sembast.import(data, tempDir.path);
        await cocoon.open(tempDir.path);
        await sembast.open(tempDir.path);

        for (final engine in [cocoon, sembast]) {
          final docs = await engine.sampleDocs(tempDir.path, 50, Random(9));
          final micros = await engine.writeUs(docs, tempDir.path);
          expect(micros, hasLength(50), reason: engine.name);
          expect(micros.every((m) => m >= 0), isTrue, reason: engine.name);

          // The rewrite is a genuine write of the doc's own value, so the
          // database still answers every id.
          final ids = [
            for (final doc in docs) (accountId: doc.accountId, id: doc.id),
          ];
          final (_, hits) = await engine.getsById(ids, tempDir.path);
          expect(
            hits,
            50,
            reason: '${engine.name}: written-back ids all found',
          );
        }
      } finally {
        await cocoon.close();
        await sembast.close();
      }
    },
  );

  test(
    'sampleDocs throws when asked for more than the database holds',
    () async {
      final data = BenchDataset.build(txnCount: 100);
      final cocoon = CocoonBenchEngine();
      try {
        await cocoon.import(data, tempDir.path);
        await cocoon.open(tempDir.path);
        await expectLater(
          cocoon.sampleDocs(tempDir.path, 101, Random(1)),
          throwsStateError,
        );
      } finally {
        await cocoon.close();
      }
    },
  );
}
