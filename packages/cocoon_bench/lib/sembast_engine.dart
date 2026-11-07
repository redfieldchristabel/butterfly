/// The sembast side of the benchmark: the same finance-shaped data as plain
/// maps in a `txns` store with an `accountId` field, sembast's normal way,
/// with its own transactions for the bulk import and sembast's defaults
/// everywhere (no tuning on either side).
library;

import 'dart:io';

import 'package:sembast/sembast_io.dart';

import 'package:cocoon_bench/dataset.dart';
import 'package:cocoon_bench/engine.dart';

/// How many records one sembast transaction writes.
const importBatchSize = 1000;

/// The `txns` store: one record per transaction, keyed by the stable id.
final _txns = stringMapStoreFactory.store('txns');

/// The `accounts` store.
final _accounts = stringMapStoreFactory.store('accounts');

final class SembastBenchEngine implements BenchEngine {
  Database? _db;

  Future<Database> _open(String baseDir) async {
    final db = await databaseFactoryIo.openDatabase(
      BenchDataset.sembastPath(baseDir),
    );
    _db = db;
    return db;
  }

  @override
  String get name => 'sembast';

  @override
  String dbPath(String baseDir) => BenchDataset.sembastPath(baseDir);

  @override
  void wipe(String baseDir) {
    final dir = Directory(baseDir);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  @override
  int fileSize(String baseDir) => fileSizeWithSidecars(dbPath(baseDir));

  @override
  Future<int> import(BenchDataset data, String baseDir) async {
    final db = await _open(baseDir);
    // Accounts first, untimed: 20 records.
    for (var i = 0; i < data.accounts.length; i++) {
      final account = data.accounts[i];
      await _accounts.record('a${i.toString().padLeft(2, '0')}').put(db, {
        'name': account.name,
        'openedAt': account.openedAt.microsecondsSinceEpoch,
        'balanceMinor': account.balanceMinor,
        'active': account.active,
      });
    }
    final sw = Stopwatch()..start();
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        start + importBatchSize > data.txns.length
            ? data.txns.length
            : start + importBatchSize,
      );
      await db.transaction((txn) async {
        for (final benchTxn in batch) {
          await _txns
              .record(benchTxn.id)
              .put(txn, BenchDataset.sembastMapOf(benchTxn));
        }
      });
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> coldOpen(BenchDataset data, String baseDir) async {
    final sw = Stopwatch()..start();
    final db = await _open(baseDir);
    final first = await _txns.find(
      db,
      finder: Finder(
        filter: Filter.equals('accountId', data.txns.first.accountId),
        sortOrders: [SortOrder('bookedOn', false)],
        limit: 1,
      ),
    );
    sw.stop();
    if (first.isEmpty) {
      throw StateError('cold open: first query answered with nothing');
    }
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> rssAfterOpen(BenchDataset data, String baseDir) async {
    await _open(baseDir);
    return ProcessInfo.currentRss;
  }

  @override
  Future<void> open(BenchDataset data, String baseDir) async {
    _db ??= await _open(baseDir);
  }

  @override
  Future<List<String>> latest50Ids(String accountId, String baseDir) async {
    final records = await _txns.find(
      _db!,
      finder: Finder(
        filter: Filter.equals('accountId', accountId),
        sortOrders: [SortOrder('bookedOn', false)],
        limit: 50,
      ),
    );
    return [for (final record in records) record.key];
  }

  @override
  Future<List<int>> latest50Us(List<String> accountIds, String baseDir) async {
    final micros = <int>[];
    for (final accountId in accountIds) {
      final sw = Stopwatch()..start();
      final ids = await latest50Ids(accountId, baseDir);
      sw.stop();
      if (ids.isEmpty) {
        throw StateError('latest50: no txns for $accountId');
      }
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<({Map<int, int> totals, int scanned})> monthlyTotalsMap(
    String accountId,
    int year,
    String baseDir,
  ) async {
    final db = _db!;
    final totals = <int, int>{};
    var scanned = 0;
    final records = await _txns.find(
      db,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('accountId', accountId),
          Filter.greaterThanOrEquals('bookedOn', year * 10000 + 101),
          Filter.lessThanOrEquals('bookedOn', year * 10000 + 1231),
        ]),
        sortOrders: [SortOrder('bookedOn')],
      ),
    );
    for (final snapshot in records) {
      final bookedOn = snapshot.value['bookedOn']! as int;
      final month = bookedOn ~/ 100 % 100;
      totals[year * 100 + month] =
          (totals[year * 100 + month] ?? 0) +
          (snapshot.value['amountMinor']! as int);
      scanned++;
    }
    return (totals: totals, scanned: scanned);
  }

  @override
  Future<(int, int, int)> monthlyTotals(
    String accountId,
    int year,
    String baseDir,
  ) async {
    final sw = Stopwatch()..start();
    final (:totals, scanned: scanned) = await monthlyTotalsMap(
      accountId,
      year,
      baseDir,
    );
    sw.stop();
    final grandTotal = totals.values.fold(0, (a, b) => a + b);
    return (sw.elapsedMilliseconds, scanned, grandTotal);
  }

  @override
  Future<(int, int)> getsById(
    List<({String accountId, String id})> ids,
    String baseDir,
  ) async {
    final db = _db!;
    var hits = 0;
    final sw = Stopwatch()..start();
    for (final id in ids) {
      final value = await _txns.record(id.id).get(db);
      if (value != null) {
        hits++;
      }
    }
    sw.stop();
    return (sw.elapsedMilliseconds, hits);
  }

  @override
  Future<List<int>> writeUs(
    List<({String accountId, String id, BenchTxn txn})> txns,
    String baseDir,
  ) async {
    final db = _db!;
    final micros = <int>[];
    for (final benchTxn in txns) {
      final sw = Stopwatch()..start();
      final map = BenchDataset.sembastMapOf(benchTxn.txn);
      await _txns.record(benchTxn.id).put(db, map);
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
