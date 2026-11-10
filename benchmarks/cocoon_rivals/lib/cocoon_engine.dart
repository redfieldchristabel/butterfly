/// The Cocoon side of the benchmark: batched transactions for the bulk
/// import, the typed generated handles for queries, and Cocoon's knobs
/// (durability) selectable per run. Ported from `packages/cocoon_bench` and
/// extended with the all-accounts workloads, which run as collection-group
/// queries over the `['bookedOn']` and `['status', 'bookedOn']` indexes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:math';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/models.dart';

final class CocoonBenchEngine implements BenchEngine {
  /// Builds the engine; [durability] is the only knob the rivals benchmark
  /// varies (`cocoon` runs Cocoon's defaults, `cocoon-normal` runs
  /// `Durability.normal`). [backupFile] overrides the NDJSON file `restore`
  /// reads (the tests point it at a small backup).
  CocoonBenchEngine({this.durability = Durability.full, String? backupFile})
    : _backupFile = backupFile;

  /// The `PRAGMA synchronous` level opens and writes run at.
  final Durability durability;

  /// The NDJSON file `restore` reads, or the shared one when null.
  final String? _backupFile;

  Cocoon? _db;

  /// Opens the database with this engine's knobs.
  Future<Cocoon> _open(String baseDir) async {
    final db = await Cocoon.open(
      BenchDataset.cocoonPath(baseDir),
      collections: [accounts, txns],
      options: CocoonOptions(durability: durability),
    );
    _db = db;
    return db;
  }

  /// The scoped collection of one account's txns.
  CollectionRef<Txn> _txnsOf(String accountId) =>
      _db!.collection(accounts).doc(accountId).collection(txns);

  @override
  String get name =>
      durability == Durability.normal ? 'cocoon-normal' : 'cocoon';

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
    // The bulk path: `db.batch()` queues every set synchronously and commits
    // them all inside one write transaction per 1000 rows — the same shape
    // as drift's `db.batch` in this benchmark.
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        math.min(start + importBatchSize, data.txns.length),
      );
      final write = db.batch();
      for (final benchTxn in batch) {
        write.set(_txnsOf(benchTxn.accountId).doc(benchTxn.id), benchTxn.txn);
      }
      await write.commit();
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> bulkimport(BenchDataset data, String baseDir) async {
    // Sequential in-process ops (the smoke test's metrics loop) close the
    // live instance first, and the bulk load leaves nothing open, like
    // `restore`: the read ops keep measuring `import`'s database.
    await _db?.close();
    _db = null;
    final db = await _open(baseDir);
    // Accounts first, untimed: 20 rows, as `import` does.
    for (var i = 0; i < data.accounts.length; i++) {
      await db
          .collection(accounts)
          .doc('a${i.toString().padLeft(2, '0')}')
          .set(data.accounts[i]);
    }
    final sw = Stopwatch()..start();
    // Cocoon's best documented bulk API: the BulkWriter queues every set
    // synchronously, commits in chunks (its measured default), defers the
    // secondary indexes until close, and resolves when everything is
    // durable — one atomic chunk at a time, not one transaction overall.
    final bulk = db.bulkWriter();
    for (final benchTxn in data.txns) {
      bulk.set(_txnsOf(benchTxn.accountId).doc(benchTxn.id), benchTxn.txn);
    }
    await bulk.close();
    sw.stop();
    await db.close();
    _db = null;
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
    // The aggregates step: one `GROUP BY` statement per account-year —
    // `bucket(bookedOn, width: 100)` floors `yyyymmdd` into `yyyymm00`
    // bands, so a group is a month, and SQLite sums the mirrored column.
    // Before this, the op paged every matching document (9,874 reads at
    // 1M) and added `amountMinor` up in Dart.
    final firstDay = year * 10000 + 101;
    final lastDay = year * 10000 + 1231;
    final monthKey = bucket(Txn$.bookedOn, width: 100);
    final groups = await _txnsOf(accountId)
        .where(Txn$.bookedOn.isGreaterThanOrEqualTo(firstDay))
        .where(Txn$.bookedOn.isLessThanOrEqualTo(lastDay))
        .groupBy([monthKey])
        .aggregate([sum(Txn$.amountMinor)])
        .get();
    final totals = <int, int>{
      for (final group in groups)
        group.key(monthKey) ~/ 100: group.getSum(Txn$.amountMinor),
    };
    return (totals: totals, scanned: groups.length);
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
  Future<List<String>> rangeMonthIds(String baseDir) async {
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    CocoonQuery<Txn> pageFor() => _db!
        .collectionGroup(txns)
        .where(Txn$.bookedOn.isGreaterThanOrEqualTo(firstDay))
        .where(Txn$.bookedOn.isLessThanOrEqualTo(lastDay))
        .orderBy(Txn$.bookedOn)
        .limit(rangePageSize);
    final ids = <String>[];
    var cursor = await pageFor().get();
    while (true) {
      ids.addAll([for (final doc in cursor.docs) doc.id]);
      final next = cursor.nextCursor;
      if (next == null) {
        break;
      }
      cursor = await pageFor().startAfter(next).get();
    }
    if (ids.isEmpty) {
      throw StateError('range: month $rangeMonthKey matched nothing');
    }
    return ids;
  }

  @override
  Future<(int, Map<String, int>, int)> yearReport(String baseDir) async {
    // The aggregates step: one groupBy statement per account (the same
    // shape as [monthlyTotalsMap]); 20 statements instead of paging the
    // whole year's 200k txns through the document API.
    final sums = <String, int>{};
    var accountsCovered = 0;
    final sw = Stopwatch()..start();
    final monthKey = bucket(Txn$.bookedOn, width: 100);
    for (final accountId in benchAccountIds()) {
      final firstDay = reportYear * 10000 + 101;
      final lastDay = reportYear * 10000 + 1231;
      final groups = await _txnsOf(accountId)
          .where(Txn$.bookedOn.isGreaterThanOrEqualTo(firstDay))
          .where(Txn$.bookedOn.isLessThanOrEqualTo(lastDay))
          .groupBy([monthKey])
          .aggregate([sum(Txn$.amountMinor)])
          .get();
      if (groups.isNotEmpty) {
        accountsCovered++;
      }
      for (final group in groups) {
        sums['$accountId|${group.key(monthKey) ~/ 100}'] = group.getSum(
          Txn$.amountMinor,
        );
      }
    }
    sw.stop();
    return (sw.elapsedMilliseconds, sums, accountsCovered);
  }

  @override
  Future<List<int>> statusSearchUs(String baseDir) async {
    final micros = <int>[];
    for (var i = 0; i < statusRuns; i++) {
      final sw = Stopwatch()..start();
      final ids = await statusSearchIds(baseDir);
      sw.stop();
      if (ids.isEmpty) {
        throw StateError('status search answered with nothing');
      }
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<List<String>> statusSearchIds(String baseDir) async {
    final page = await _db!
        .collectionGroup(txns)
        .where(Txn$.status.isEqualTo(TxnStatus.pending))
        .orderBy(Txn$.bookedOn, descending: true)
        .limit(50)
        .get();
    return [for (final doc in page.docs) doc.id];
  }

  @override
  Future<List<int>> bigspendUs(String baseDir) async {
    final micros = <int>[];
    for (var i = 0; i < bigspendRuns; i++) {
      final sw = Stopwatch()..start();
      final ids = await bigspendIds(baseDir);
      sw.stop();
      if (ids.isEmpty) {
        throw StateError('bigspend answered with nothing');
      }
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<List<String>> bigspendIds(String baseDir) async {
    // The `['amountMinor']` index walk across the collection group, most
    // negative first; the engine appends the id as the final (ascending)
    // tiebreaker. Ordering alone, no filter: the dataset's 50 smallest
    // amounts are always debits.
    final page = await _db!
        .collectionGroup(txns)
        .orderBy(Txn$.amountMinor)
        .limit(50)
        .get();
    return [for (final doc in page.docs) doc.id];
  }

  @override
  Future<List<String>> amountRangeIds(String baseDir) async {
    // The amount index serves the range + its own ascending order; pages
    // continue by Cocoon's keyset cursor (this engine's idiom).
    CocoonQuery<Txn> pageFor() => _db!
        .collectionGroup(txns)
        .where(Txn$.amountMinor.isGreaterThanOrEqualTo(amountBandLo))
        .where(Txn$.amountMinor.isLessThan(amountBandHi))
        .orderBy(Txn$.amountMinor)
        .limit(amountRangePageSize);
    final ids = <String>[];
    var cursor = await pageFor().get();
    while (true) {
      ids.addAll([for (final doc in cursor.docs) doc.id]);
      final next = cursor.nextCursor;
      if (next == null) {
        break;
      }
      cursor = await pageFor().startAfter(next).get();
    }
    // An empty band is a legal answer (the smoke test runs at 500 txns,
    // where it is often empty); the verify dump diffs emptiness loudly.
    return ids;
  }

  @override
  Future<List<String>> pendingMonthIds(String baseDir) async {
    // Equality (status) + range (bookedOn) + its own ascending order: the
    // `(status, bookedOn)` index serves the whole shape; keyset cursors
    // page it.
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    CocoonQuery<Txn> pageFor() => _db!
        .collectionGroup(txns)
        .where(Txn$.status.isEqualTo(TxnStatus.pending))
        .where(Txn$.bookedOn.isGreaterThanOrEqualTo(firstDay))
        .where(Txn$.bookedOn.isLessThanOrEqualTo(lastDay))
        .orderBy(Txn$.bookedOn)
        .limit(rangePageSize);
    final ids = <String>[];
    var cursor = await pageFor().get();
    while (true) {
      ids.addAll([for (final doc in cursor.docs) doc.id]);
      final next = cursor.nextCursor;
      if (next == null) {
        break;
      }
      cursor = await pageFor().startAfter(next).get();
    }
    // An empty month is a legal answer at the smoke test's 500 txns.
    return ids;
  }

  @override
  Future<({List<List<String>> pageIds, List<int> pageUs})> deeppagePages(
    String accountId,
    String baseDir,
  ) async {
    // Cursor paging (this engine's idiom): page 1 is the latest-50 query,
    // every next page starts after the previous page's cursor.
    final pageIds = <List<String>>[];
    final pageUs = <int>[];
    CocoonQuery<Txn> pageFor() => _txnsOf(
      accountId,
    ).orderBy(Txn$.bookedOn, descending: true).limit(deeppagePageSize);
    var sw = Stopwatch()..start();
    var page = await pageFor().get();
    sw.stop();
    while (true) {
      pageIds.add([for (final doc in page.docs) doc.id]);
      pageUs.add(sw.elapsedMicroseconds);
      final next = page.nextCursor;
      if (next == null || pageIds.length >= deeppagePageCount) {
        break;
      }
      sw = Stopwatch()..start();
      page = await pageFor().startAfter(next).get();
      sw.stop();
    }
    return (pageIds: pageIds, pageUs: pageUs);
  }

  @override
  Future<({List<int> us, int count})> pendingCountUs(String baseDir) async {
    // Cocoon's index rule requires a sort key to serve an equality-only
    // shape, so the count declares the `(status, bookedOn)` index's own
    // order; `count()` runs a `SELECT count(*)` whose SQL ignores the
    // order (see `planQuery`'s countSql).
    final micros = <int>[];
    var count = 0;
    for (var i = 0; i < countRuns; i++) {
      final sw = Stopwatch()..start();
      count = await _db!
          .collectionGroup(txns)
          .where(Txn$.status.isEqualTo(TxnStatus.pending))
          .orderBy(Txn$.bookedOn)
          .count();
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return (us: micros, count: count);
  }

  @override
  Future<({List<int> us, int count})> yearCountUs(
    String accountId,
    String baseDir,
  ) async {
    // Same rule as [pendingCountUs]: the range count needs a sort key, and
    // the `(accountId, -bookedOn)` index's own descending order is the one
    // that serves scope + range + order together.
    final firstDay = reportYear * 10000 + 101;
    final lastDay = reportYear * 10000 + 1231;
    final micros = <int>[];
    var count = 0;
    for (var i = 0; i < countRuns; i++) {
      final sw = Stopwatch()..start();
      count = await _txnsOf(accountId)
          .where(Txn$.bookedOn.isGreaterThanOrEqualTo(firstDay))
          .where(Txn$.bookedOn.isLessThanOrEqualTo(lastDay))
          .orderBy(Txn$.bookedOn, descending: true)
          .count();
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return (us: micros, count: count);
  }

  @override
  Future<void> writeOneTxn(String accountId, String id, int seq) {
    return _txnsOf(accountId).doc(id).set(syncTxnOf(seq));
  }

  @override
  Future<(int, int)> restore(String baseDir) async {
    wipe(baseDir);
    Directory(baseDir).createSync(recursive: true);
    final db = await _open(baseDir);
    final sw = Stopwatch()..start();
    var restored = 0;
    final file = File(_backupFile ?? backupPath());
    final lines = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    var batch = <BenchTxn>[];
    Future<void> flush() async {
      if (batch.isEmpty) {
        return;
      }
      await db.runTransaction((tx) async {
        for (final benchTxn in batch) {
          await tx.set(
            _txnsOf(benchTxn.accountId).doc(benchTxn.id),
            benchTxn.txn,
          );
        }
      });
      restored += batch.length;
      batch = <BenchTxn>[];
    }

    await for (final line in lines) {
      if (line.isEmpty) {
        continue;
      }
      final map = jsonDecode(line) as Map<String, Object?>;
      final (:accountId, :txn) = txnFromBackupMap(map);
      batch.add(
        BenchTxn(id: map['id']! as String, accountId: accountId, txn: txn),
      );
      if (batch.length >= restoreBatchSize) {
        await flush();
      }
    }
    await flush();
    sw.stop();
    await db.close();
    _db = null;
    return (sw.elapsedMilliseconds, restored);
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
