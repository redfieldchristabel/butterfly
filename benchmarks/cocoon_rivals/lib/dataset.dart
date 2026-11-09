/// The deterministic, seeded benchmark dataset, shaped like Finance Sync:
/// twenty accounts and a five-year transaction history per account, with
/// stable ids so every engine sees byte-identical work. Copied unchanged
/// from `packages/cocoon_bench` (same `Random(42)` sequence), so the rival
/// harness measures the same data as the sembast benchmark.
///
/// Everything is derived from one `Random(42)` sequence, so every process
/// that builds a dataset of the same size builds the same one.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon_rivals/models.dart';

/// The accounts count every size uses.
const accountCount = 20;

/// The years the history spans, inclusive.
const firstYear = 2022;
const lastYear = 2026;

/// The deterministic account ids `a00`..`a19`, derivable from the seed
/// without building the dataset: read-only benchmark operations use these so
/// the harness's copy of the data never has to sit in their RAM.
List<String> benchAccountIds() => [
  for (var i = 0; i < accountCount; i++) 'a${i.toString().padLeft(2, '0')}',
];

/// One pending benchmark transaction with its stable id.
final class BenchTxn {
  const BenchTxn({required this.id, required this.accountId, required this.txn});

  final String id;

  /// The parent account id, e.g. `a07`.
  final String accountId;

  /// The typed value the engines store (Cocoon as the model, the rivals as
  /// rows/maps).
  final Txn txn;
}

/// A built dataset: accounts plus every transaction with its parent id.
final class BenchDataset {
  BenchDataset._(this.accounts, this.txns);

  /// The 20 accounts, ids `a00`..`a19`.
  final List<Account> accounts;

  /// Every transaction, in generation order (account-major).
  final List<BenchTxn> txns;

  /// The deterministic ids of every engine's database under [baseDir].
  static String cocoonPath(String baseDir) => '$baseDir/cocoon.db';

  static String sembastPath(String baseDir) => '$baseDir/sembast.db';

  static String driftPath(String baseDir) => '$baseDir/drift.db';

  static String isarPath(String baseDir) => '$baseDir/isar';

  static String objectboxPath(String baseDir) => '$baseDir/objectbox';

  static String hivePath(String baseDir) => baseDir;

  /// Builds the dataset for [txnCount] transactions.
  ///
  /// Transactions are spread account-major: `t000000000` first, round-robin
  /// over the accounts, so every account holds an equal share and a stable
  /// id maps to the same transaction in every process.
  factory BenchDataset.build({required int txnCount}) {
    final rng = Random(42);
    final accounts = <Account>[];
    for (var i = 0; i < accountCount; i++) {
      accounts.add(
        Account(
          name: 'Account ${i.toString().padLeft(2, '0')}',
          openedAt: DateTime.utc(2021, 1 + (i % 12), 1 + (i % 28), 9),
          balanceMinor: 100000 + rng.nextInt(900000),
          active: i % 7 != 3,
        ),
      );
    }
    final txns = <BenchTxn>[];
    const currencies = ['MYR', 'SGD', 'USD', 'EUR'];
    const labelPool = ['groceries', 'rent', 'fuel', 'fees', 'salary', 'gift'];
    const splitLabels = ['food', 'transport', 'utilities', 'fees'];
    for (var i = 0; i < txnCount; i++) {
      final accountId = 'a${(i % accountCount).toString().padLeft(2, '0')}';
      final year = firstYear + rng.nextInt(lastYear - firstYear + 1);
      final month = 1 + rng.nextInt(12);
      final day = 1 + rng.nextInt(28);
      final negative = rng.nextInt(10) < 4;
      final magnitude = 100 + rng.nextInt(990000);
      final status = switch (rng.nextInt(100)) {
        < 85 => TxnStatus.posted,
        < 95 => TxnStatus.pending,
        _ => TxnStatus.failed,
      };
      final memo = rng.nextInt(10) < 6 ? 'memo-${rng.nextInt(100000)}' : null;
      final labelCount = rng.nextInt(4);
      final labels = [
        for (var l = 0; l < labelCount; l++)
          labelPool[rng.nextInt(labelPool.length)],
      ];
      final splitCount = rng.nextInt(4);
      var unassigned = magnitude;
      final splits = <Split>[
        for (var s = 0; s < splitCount; s++)
          Split(
            label: splitLabels[rng.nextInt(splitLabels.length)],
            shareMinor: () {
              final share = s == splitCount - 1
                  ? unassigned
                  : unassigned ~/ (2 + s);
              unassigned -= share;
              return share;
            }(),
          ),
      ];
      final metaCount = rng.nextInt(5);
      final meta = <String, String>{
        // Insertion order is deliberately shuffled against the key order;
        // Cocoon's encoding sorts by key before writing.
        for (var m = 0; m < metaCount; m++)
          'k${rng.nextInt(8)}': 'v${rng.nextInt(1000000)}',
      };
      txns.add(
        BenchTxn(
          id: 't${i.toString().padLeft(9, '0')}',
          accountId: accountId,
          txn: Txn(
            bookedOn: year * 10000 + month * 100 + day,
            amountMinor: negative ? -magnitude : magnitude,
            currency: currencies[rng.nextInt(currencies.length)],
            status: status,
            memo: memo,
            labels: labels,
            splits: splits,
            meta: meta,
          ),
        ),
      );
    }
    return BenchDataset._(accounts, txns);
  }

  /// The transactions of one account, in generation order.
  Iterable<BenchTxn> txnsOf(String accountId) =>
      txns.where((t) => t.accountId == accountId);

  /// The plain-map form the map-shaped engines (sembast, Hive) store; the
  /// same data, their normal way.
  static Map<String, Object?> sembastMapOf(BenchTxn benchTxn) => {
    'accountId': benchTxn.accountId,
    'bookedOn': benchTxn.txn.bookedOn,
    'amountMinor': benchTxn.txn.amountMinor,
    'currency': benchTxn.txn.currency,
    'status': benchTxn.txn.status.name,
    if (benchTxn.txn.memo != null) 'memo': benchTxn.txn.memo,
    'labels': [...benchTxn.txn.labels],
    'splits': [
      for (final split in benchTxn.txn.splits)
        {'label': split.label, 'shareMinor': split.shareMinor},
    ],
    'meta': {...benchTxn.txn.meta},
  };

  /// Per-month `amountMinor` totals of one account-year, keyed `yyyyMM`.
  Map<int, int> monthlyTotalsOf(String accountId, int year) {
    final totals = <int, int>{};
    for (final benchTxn in txnsOf(accountId)) {
      final bookedOn = benchTxn.txn.bookedOn;
      if (bookedOn ~/ 10000 != year) {
        continue;
      }
      final month = bookedOn ~/ 100 % 100;
      totals[year * 100 + month] =
          (totals[year * 100 + month] ?? 0) + benchTxn.txn.amountMinor;
    }
    return totals;
  }
}

/// Rebuilds a [Txn] (and its parent account id) from one parsed NDJSON
/// backup line. Restores parse the file, not the dataset, so this is the
/// only model-shaped code the backup needs.
({String accountId, Txn txn}) txnFromBackupMap(Map<String, Object?> map) => (
  accountId: map['accountId']! as String,
  txn: Txn(
    bookedOn: map['bookedOn']! as int,
    amountMinor: map['amountMinor']! as int,
    currency: map['currency']! as String,
    status: TxnStatus.values.byName(map['status']! as String),
    memo: map['memo'] as String?,
    labels: [
      for (final label in map['labels']! as List) label as String,
    ],
    splits: [
      for (final split in map['splits']! as List)
        Split(
          label: (split as Map)['label']! as String,
          shareMinor: split['shareMinor']! as int,
        ),
    ],
    meta: {
      for (final entry in (map['meta']! as Map).entries)
        entry.key as String: entry.value as String,
    },
  ),
);

/// The NDJSON backup file every restore reads: [backupTxnCount] transactions,
/// one JSON object per line. Built once (untimed) and shared by all engines.
const backupTxnCount = 300000;

/// The shared backup file location: one file for every engine, rebuilt only
/// when missing (the dataset is deterministic, so rebuilds are identical).
String backupPath() {
  final tmp = Platform.environment['TMPDIR'] ?? '/tmp';
  return '$tmp/cocoon_rivals_backup/backup_$backupTxnCount.ndjson';
}

/// Writes the NDJSON backup to [path] when it does not exist yet. Untimed
/// setup, not part of any measurement.
///
/// Builds into a `.tmp` file and renames on success, so an interrupted build
/// (a killed process, a full disk) never leaves a half-written backup that
/// later runs would take for complete — the rename is the commit.
Future<void> ensureNdjsonBackup() async {
  final file = File(backupPath());
  if (file.existsSync() && file.lengthSync() > 0) {
    return;
  }
  file.parent.createSync(recursive: true);
  final tmp = File('${backupPath()}.tmp');
  final data = BenchDataset.build(txnCount: backupTxnCount);
  final sink = tmp.openWrite();
  try {
    for (final benchTxn in data.txns) {
      sink.writeln(jsonEncode(backupLineOf(benchTxn)));
    }
  } finally {
    // Awaited: close() returns before the buffered bytes reach the disk,
    // and an unawaited close is how a truncated backup gets read.
    await sink.close();
  }
  tmp.renameSync(file.path);
}

/// One NDJSON backup line for [benchTxn]: id, accountId, then the fields.
Map<String, Object?> backupLineOf(BenchTxn benchTxn) => {
  'id': benchTxn.id,
  'accountId': benchTxn.accountId,
  'bookedOn': benchTxn.txn.bookedOn,
  'amountMinor': benchTxn.txn.amountMinor,
  'currency': benchTxn.txn.currency,
  'status': benchTxn.txn.status.name,
  if (benchTxn.txn.memo != null) 'memo': benchTxn.txn.memo,
  'labels': [...benchTxn.txn.labels],
  'splits': [
    for (final split in benchTxn.txn.splits)
      {'label': split.label, 'shareMinor': split.shareMinor},
  ],
  'meta': {...benchTxn.txn.meta},
};
