/// Subprocess fixture for `missing_index_test.dart`: exercises
/// `MissingIndexMode.scanAndWarn` in builds the `dart test` runner never
/// produces. Run it with plain `dart run` (asserts OFF — the release
/// behaviour) or with `dart run --enable-asserts` (asserts ON — the debug
/// fallback). The parent test spawns both and reads stdout/stderr.
///
/// Modes:
/// - `release`: run the missing-index query once; print `RESULT threw` when
///   the engine refused the scan (the release behaviour) or
///   `RESULT scanned:<n>` when it ran, then `REPORTS <n>`.
/// - `warn`: run the same query twice (one warning per distinct missing
///   index per process), printing `RESULT scanned:<n>` per run and
///   `REPORTS <n>`; the warning goes to real stderr and `dart:developer` log.
library;

import 'dart:io';

import 'package:cocoon/cocoon.dart';

import '../support/models.dart';

Txn txn(int bookedOn, int amountMinor) => Txn(
  bookedOn: bookedOn,
  amountMinor: amountMinor,
  rate: 1.5,
  currency: 'MYR',
  status: TxnStatus.posted,
  createdAt: DateTime.utc(2026, 1, 15, 10, 30),
);

Future<void> main(List<String> args) async {
  final mode = args.single;
  final dir = Directory.systemTemp.createTempSync('cocoon_missing_fixture');
  final db = await Cocoon.open(
    '${dir.path}/cocoon.db',
    collections: [accounts, txns, splits],
    options: const CocoonOptions(onMissingIndex: MissingIndexMode.scanAndWarn),
  );
  try {
    await db
        .collection(accounts)
        .doc('a1')
        .collection(txns)
        .doc('t1')
        .set(txn(20240101, 100));
    await db
        .collection(accounts)
        .doc('a1')
        .collection(txns)
        .doc('t2')
        .set(txn(20240102, 100));
    final query = db.collectionGroup(txns).where(txnAmountMinor.isEqualTo(100));
    for (var i = 0; i < (mode == 'warn' ? 2 : 1); i++) {
      try {
        final page = await query.get();
        print('RESULT scanned:${page.docs.length}');
      } on MissingIndexException {
        print('RESULT threw');
      }
    }
    print('REPORTS ${db.missingIndexes.length}');
  } finally {
    await db.close();
    dir.deleteSync(recursive: true);
  }
}
