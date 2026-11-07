import 'dart:io';

import 'package:cocoon_bench/cocoon_engine.dart';
import 'package:cocoon_bench/dataset.dart';
import 'package:cocoon_bench/sembast_engine.dart';
import 'package:test/test.dart';

/// Correctness before speed: both engines import the same 500-txn dataset
/// and must agree on every measured read shape — the latest-50 ids per
/// account and one account's monthly totals — before the numbers in
/// RESULTS.md mean anything.
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
        await cocoon.open(data, tempDir.path);
        await sembast.open(data, tempDir.path);

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
}
