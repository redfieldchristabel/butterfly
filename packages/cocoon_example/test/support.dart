/// Shared fixtures for the cocoon_example tests: realistic finance-style
/// values for every field type, and a temp-dir database lifecycle.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon_example/models.dart';

Directory? _tempDir;

/// A fresh SQLite file in a temp directory; the caller must eventually
/// [cleanUpTempDir] (the test `tearDown` does).
Future<String> tempDbPath() async {
  _tempDir ??= await Directory.systemTemp.createTemp('cocoon_example_test');
  final file = File(
    '${_tempDir!.path}/bank-${DateTime.now().microsecondsSinceEpoch}.db',
  );
  return file.path;
}

/// Removes the temp directory of the current test.
Future<void> cleanUpTempDir() async {
  final dir = _tempDir;
  _tempDir = null;
  if (dir != null) {
    await dir.delete(recursive: true);
  }
}

/// An [Account] exercising every stored type: `String`, `DateTime`, `int`,
/// `bool`, `List<String>`, an embedded [Address] (with a nested [GeoPoint])
/// and bytes.
Account accountFixture({required String name}) => Account(
  name: name,
  openedAt: DateTime.utc(2026, 1, 15, 10, 30),
  balanceMinor: -2500,
  active: true,
  tags: const ['savings', 'joint'],
  address: Address(
    city: 'Kuala Lumpur',
    postCode: '50450',
    line2: 'Unit 12',
    geo: const GeoPoint(lat: 3.14, lon: 101.68),
  ),
  avatar: Uint8List.fromList(const [1, 2, 3, 255]),
);

/// A [Txn] exercising every stored type: `int`, enum, `DateTime`, `double`,
/// nullable `String`, `List<String>` and nullable bytes.
Txn txnFixture({
  int bookedOn = 20260115,
  int amountMinor = -4299,
  String currency = 'MYR',
  TxnStatus status = TxnStatus.posted,
}) => Txn(
  bookedOn: bookedOn,
  amountMinor: amountMinor,
  currency: currency,
  status: status,
  createdAt: DateTime.utc(2026, 1, 15, 12, 0, 30, 250, 999),
  rate: 4.123456,
  memo: 'groceries',
  labels: const ['food', 'weekly'],
  receipt: Uint8List.fromList(const [9, 8, 7, 0, 255]),
);

/// A [Split] of a transaction.
Split splitFixture({required String label, required int shareMinor}) =>
    Split(label: label, shareMinor: shareMinor, note: null);
