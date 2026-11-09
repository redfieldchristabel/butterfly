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
  String get name => durability == Durability.normal ? 'cocoon-normal' : 'cocoon';

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
    final sums = <String, int>{};
    var accountsCovered = 0;
    final sw = Stopwatch()..start();
    for (final accountId in benchAccountIds()) {
      final (:totals, scanned: _) = await monthlyTotalsMap(
        accountId,
        reportYear,
        baseDir,
      );
      if (totals.isNotEmpty) {
        accountsCovered++;
      }
      for (final entry in totals.entries) {
        sums['$accountId|${entry.key}'] = entry.value;
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
