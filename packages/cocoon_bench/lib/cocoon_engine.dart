/// The Cocoon side of the benchmark: batched transactions for the bulk
/// import, the typed generated handles for queries, and Cocoon's knobs
/// (durability, cache size, change log) selectable per run so the tuning
/// measurements only change one setting at a time.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:math';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_bench/dataset.dart';
import 'package:cocoon_bench/engine.dart';
import 'package:cocoon_bench/models.dart';

/// How many documents one import transaction writes.
const importBatchSize = 1000;

/// The page size the monthly-totals paging and the id sampling use.
const monthlyPageSize = 500;

final class CocoonBenchEngine implements BenchEngine {
  /// Builds the engine; every knob defaults to Cocoon's own default, so the
  /// plain `CocoonBenchEngine()` runs `Durability.full`, `keepChanges: true`
  /// and the 2000-document cache.
  CocoonBenchEngine({
    this.durability = Durability.full,
    this.cacheSize = CocoonOptions.defaultCacheSize,
    this.keepChanges = true,
  });

  /// The `PRAGMA synchronous` level opens and writes run at.
  final Durability durability;

  /// The hot-document cache size opens configure, in documents.
  final int cacheSize;

  /// Whether commits append their rows to the on-disk change log.
  final bool keepChanges;

  Cocoon? _db;

  /// Opens the database with this engine's knobs.
  Future<Cocoon> _open(String baseDir) async {
    final db = await Cocoon.open(
      BenchDataset.cocoonPath(baseDir),
      collections: [accounts, txns],
      options: CocoonOptions(
        durability: durability,
        cacheSize: cacheSize,
        keepChanges: keepChanges,
      ),
    );
    _db = db;
    return db;
  }

  /// The scoped collection of one account's txns.
  CollectionRef<Txn> _txnsOf(String accountId) =>
      _db!.collection(accounts).doc(accountId).collection(txns);

  @override
  String get name => 'cocoon';

  @override
  String dbPath(String baseDir) => BenchDataset.cocoonPath(baseDir);

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
    // Accounts first, untimed: 20 rows.
    for (var i = 0; i < data.accounts.length; i++) {
      await db
          .collection(accounts)
          .doc('a${i.toString().padLeft(2, '0')}')
          .set(data.accounts[i]);
    }
    final sw = Stopwatch()..start();
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        math.min(start + importBatchSize, data.txns.length),
      );
      await db.runTransaction((tx) async {
        for (final benchTxn in batch) {
          await tx.set(
            _txnsOf(benchTxn.accountId).doc(benchTxn.id),
            benchTxn.txn,
          );
        }
      });
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> coldOpen(String baseDir, {required String accountId}) async {
    final sw = Stopwatch()..start();
    final db = await _open(baseDir);
    final first = await db
        .collection(accounts)
        .doc(accountId)
        .collection(txns)
        .orderBy(Txn$.bookedOn, descending: true)
        .limit(1)
        .get();
    sw.stop();
    if (first.docs.isEmpty) {
      throw StateError('cold open: first query answered with nothing');
    }
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> rssAfterOpen(String baseDir) async {
    _db ??= await _open(baseDir);
    return ProcessInfo.currentRss;
  }

  @override
  Future<void> open(String baseDir) async {
    _db ??= await _open(baseDir);
  }

  @override
  Future<List<String>> latest50Ids(String accountId, String baseDir) async {
    final page = await _txnsOf(
      accountId,
    ).orderBy(Txn$.bookedOn, descending: true).limit(50).get();
    return [for (final doc in page.docs) doc.id];
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
    final totals = <int, int>{};
    var scanned = 0;
    final firstDay = year * 10000 + 101;
    final lastDay = year * 10000 + 1231;
    CocoonQuery<Txn> queryFor() => _txnsOf(accountId)
        .where(Txn$.bookedOn.isGreaterThanOrEqualTo(firstDay))
        .where(Txn$.bookedOn.isLessThanOrEqualTo(lastDay))
        .orderBy(Txn$.bookedOn)
        .limit(monthlyPageSize);
    var cursor = await queryFor().get();
    while (true) {
      for (final doc in cursor.docs) {
        final bookedOn = doc.data.bookedOn;
        final month = bookedOn ~/ 100 % 100;
        totals[year * 100 + month] =
            (totals[year * 100 + month] ?? 0) + doc.data.amountMinor;
        scanned++;
      }
      final next = cursor.nextCursor;
      if (next == null) {
        break;
      }
      cursor = await queryFor().startAfter(next).get();
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
  Future<List<SampledDoc>> sampleDocs(String baseDir, int count, Random rng) =>
      reservoirSample(count, rng, () async* {
        // Pages every stored document once, in scope-index order (the id
        // tiebreaker direction), and keeps only the reservoir: the typed
        // values of one page at a time, nothing more.
        for (final accountId in benchAccountIds()) {
          CocoonQuery<Txn> pageFor() =>
              _txnsOf(accountId).query().limit(monthlyPageSize);
          var page = await pageFor().get();
          while (true) {
            for (final doc in page.docs) {
              yield (accountId: accountId, id: doc.id, value: doc.data);
            }
            final next = page.nextCursor;
            if (next == null) {
              break;
            }
            page = await pageFor().startAfter(next).get();
          }
        }
      });

  @override
  Future<(int, int)> getsById(
    List<({String accountId, String id})> ids,
    String baseDir,
  ) async {
    var hits = 0;
    final sw = Stopwatch()..start();
    for (final id in ids) {
      final snap = await _txnsOf(id.accountId).doc(id.id).get();
      if (snap != null) {
        hits++;
      }
    }
    sw.stop();
    return (sw.elapsedMilliseconds, hits);
  }

  @override
  Future<List<int>> writeUs(List<SampledDoc> docs, String baseDir) async {
    final micros = <int>[];
    for (final doc in docs) {
      final sw = Stopwatch()..start();
      await _txnsOf(doc.accountId).doc(doc.id).set(doc.value as Txn);
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
