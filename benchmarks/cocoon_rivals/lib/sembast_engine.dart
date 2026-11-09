/// The sembast side of the benchmark: the same finance-shaped data as plain
/// maps in a `txns` store with an `accountId` field, sembast's normal way,
/// with its own transactions for the bulk import and sembast's defaults
/// everywhere (no tuning on either side). Ported from
/// `packages/cocoon_bench`; the finds add an explicit key sort order so the
/// equal-`bookedOn` days of the bigger datasets come back in the shared
/// contract order (`bookedOn DESC, id DESC` and the reverse for ranges).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sembast/sembast_io.dart';

import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/models.dart' as m;

/// The `txns` store: one record per transaction, keyed by the stable id.
final _txns = stringMapStoreFactory.store('txns');

/// The `accounts` store.
final _accounts = stringMapStoreFactory.store('accounts');

final class SembastBenchEngine implements BenchEngine {
  /// Builds the engine; [backupFile] overrides the NDJSON file `restore`
  /// reads (the tests point it at a small backup).
  SembastBenchEngine({String? backupFile}) : _backupFile = backupFile;

  /// The NDJSON file `restore` reads, or the shared one when null.
  final String? _backupFile;

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
  Future<int> coldOpen(String baseDir, {required String accountId}) async {
    final sw = Stopwatch()..start();
    final db = await _open(baseDir);
    final first = await _txns.find(
      db,
      finder: Finder(
        filter: Filter.equals('accountId', accountId),
        sortOrders: [SortOrder('bookedOn', false), SortOrder(Field.key, false)],
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
    final records = await _txns.find(
      _db!,
      finder: Finder(
        filter: Filter.equals('accountId', accountId),
        sortOrders: [SortOrder('bookedOn', false), SortOrder(Field.key, false)],
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
        sortOrders: [SortOrder('bookedOn'), SortOrder(Field.key)],
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
  Future<List<SampledDoc>> sampleDocs(String baseDir, int count, Random rng) =>
      reservoirSample(count, rng, () async* {
        // Walks every stored record once, in sembast's key order, and keeps
        // only the reservoir. sembast's decoded store is already all in RAM
        // after open — sampling adds the reservoir itself, nothing more.
        final db = _db!;
        final records = await _txns.find(db);
        for (final record in records) {
          yield (
            accountId: record.value['accountId']! as String,
            id: record.key,
            value: record.value,
          );
        }
      });

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
  Future<List<int>> writeUs(List<SampledDoc> docs, String baseDir) async {
    final db = _db!;
    final micros = <int>[];
    for (final doc in docs) {
      final sw = Stopwatch()..start();
      await _txns.record(doc.id).put(db, doc.value as Map<String, Object?>);
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<List<String>> rangeMonthIds(String baseDir) async {
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final ids = <String>[];
    // Paged by [rangePageSize] the way the other query engines page: one
    // find per page with an offset. sembast has no indexes, so every page
    // scans the (in-RAM) store — that is the point of this engine.
    var pages = 0;
    while (true) {
      final page = await _txns.find(
        _db!,
        finder: Finder(
          filter: Filter.and([
            Filter.greaterThanOrEquals('bookedOn', firstDay),
            Filter.lessThanOrEquals('bookedOn', lastDay),
          ]),
          sortOrders: [SortOrder('bookedOn'), SortOrder(Field.key)],
          offset: pages * rangePageSize,
          limit: rangePageSize,
        ),
      );
      if (page.isEmpty) {
        break;
      }
      ids.addAll([for (final record in page) record.key]);
      if (page.length < rangePageSize) {
        break;
      }
      pages++;
    }
    if (ids.isEmpty) {
      throw StateError('range: month $rangeMonthKey matched nothing');
    }
    return ids;
  }

  @override
  Future<(int, Map<String, int>, int)> yearReport(String baseDir) async {
    final sw = Stopwatch()..start();
    final firstDay = reportYear * 10000 + 101;
    final lastDay = reportYear * 10000 + 1231;
    // One find over the store: sembast has no indexes and no aggregates, so
    // the report scans the year's records once and sums in Dart.
    final records = await _txns.find(
      _db!,
      finder: Finder(
        filter: Filter.and([
          Filter.greaterThanOrEquals('bookedOn', firstDay),
          Filter.lessThanOrEquals('bookedOn', lastDay),
        ]),
      ),
    );
    final sums = <String, int>{};
    final accounts = <String>{};
    for (final snapshot in records) {
      final accountId = snapshot.value['accountId']! as String;
      final bookedOn = snapshot.value['bookedOn']! as int;
      final month = bookedOn ~/ 100 % 100;
      final key = '$accountId|${reportYear * 100 + month}';
      sums[key] = (sums[key] ?? 0) + (snapshot.value['amountMinor']! as int);
      accounts.add(accountId);
    }
    sw.stop();
    return (sw.elapsedMilliseconds, sums, accounts.length);
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
    final records = await _txns.find(
      _db!,
      finder: Finder(
        filter: Filter.equals('status', m.TxnStatus.pending.name),
        sortOrders: [SortOrder('bookedOn', false), SortOrder(Field.key, false)],
        limit: 50,
      ),
    );
    return [for (final record in records) record.key];
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
    // No indexes: sembast sorts the (in-RAM) store for the contract order —
    // smallest amount (the largest debit) first, key order for ties.
    final records = await _txns.find(
      _db!,
      finder: Finder(
        sortOrders: [SortOrder('amountMinor'), SortOrder(Field.key)],
        limit: 50,
      ),
    );
    return [for (final record in records) record.key];
  }

  @override
  Future<List<String>> amountRangeIds(String baseDir) async {
    // Paged by [amountRangePageSize] with an offset (the idiom this engine's
    // `rangeMonthIds` uses): sembast has no indexes, so every page scans and
    // re-sorts the (in-RAM) store — that is the point of this engine.
    final ids = <String>[];
    var pages = 0;
    while (true) {
      final page = await _txns.find(
        _db!,
        finder: Finder(
          filter: Filter.and([
            Filter.greaterThanOrEquals('amountMinor', amountBandLo),
            Filter.lessThan('amountMinor', amountBandHi),
          ]),
          sortOrders: [SortOrder('amountMinor'), SortOrder(Field.key)],
          offset: pages * amountRangePageSize,
          limit: amountRangePageSize,
        ),
      );
      if (page.isEmpty) {
        break;
      }
      ids.addAll([for (final record in page) record.key]);
      if (page.length < amountRangePageSize) {
        break;
      }
      pages++;
    }
    // An empty band is a legal answer (the smoke test runs at 500 txns,
    // where it is often empty); the verify dump diffs emptiness loudly.
    return ids;
  }

  @override
  Future<List<String>> pendingMonthIds(String baseDir) async {
    // The compound filter + sort + offset paging, the shape `rangeMonthIds`
    // models for this engine.
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final ids = <String>[];
    var pages = 0;
    while (true) {
      final page = await _txns.find(
        _db!,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('status', m.TxnStatus.pending.name),
            Filter.greaterThanOrEquals('bookedOn', firstDay),
            Filter.lessThanOrEquals('bookedOn', lastDay),
          ]),
          sortOrders: [SortOrder('bookedOn'), SortOrder(Field.key)],
          offset: pages * rangePageSize,
          limit: rangePageSize,
        ),
      );
      if (page.isEmpty) {
        break;
      }
      ids.addAll([for (final record in page) record.key]);
      if (page.length < rangePageSize) {
        break;
      }
      pages++;
    }
    // An empty month is a legal answer at the smoke test's 500 txns.
    return ids;
  }

  @override
  Future<({List<List<String>> pageIds, List<int> pageUs})> deeppagePages(
    String accountId,
    String baseDir,
  ) async {
    // sembast's idiom is Finder offset/limit: page N re-scans and re-sorts
    // the (in-RAM) store from the top — what the op is here to measure.
    final pageIds = <List<String>>[];
    final pageUs = <int>[];
    for (var page = 0; page < deeppagePageCount; page++) {
      final sw = Stopwatch()..start();
      final records = await _txns.find(
        _db!,
        finder: Finder(
          filter: Filter.equals('accountId', accountId),
          sortOrders: [
            SortOrder('bookedOn', false),
            SortOrder(Field.key, false),
          ],
          offset: page * deeppagePageSize,
          limit: deeppagePageSize,
        ),
      );
      sw.stop();
      if (records.isEmpty) {
        break;
      }
      pageIds.add([for (final record in records) record.key]);
      pageUs.add(sw.elapsedMicroseconds);
    }
    return (pageIds: pageIds, pageUs: pageUs);
  }

  @override
  Future<({List<int> us, int count})> pendingCountUs(String baseDir) async {
    // sembast's own query count over a filter — still a scan underneath,
    // which is the honest comparison.
    final micros = <int>[];
    var count = 0;
    for (var i = 0; i < countRuns; i++) {
      final sw = Stopwatch()..start();
      count = await _txns
          .query(
            finder: Finder(
              filter: Filter.equals('status', m.TxnStatus.pending.name),
            ),
          )
          .count(_db!);
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
    final firstDay = reportYear * 10000 + 101;
    final lastDay = reportYear * 10000 + 1231;
    final micros = <int>[];
    var count = 0;
    for (var i = 0; i < countRuns; i++) {
      final sw = Stopwatch()..start();
      count = await _txns
          .query(
            finder: Finder(
              filter: Filter.and([
                Filter.equals('accountId', accountId),
                Filter.greaterThanOrEquals('bookedOn', firstDay),
                Filter.lessThanOrEquals('bookedOn', lastDay),
              ]),
            ),
          )
          .count(_db!);
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return (us: micros, count: count);
  }

  @override
  Future<void> writeOneTxn(String accountId, String id, int seq) {
    return _txns.record(id).put(_db!, {
      'accountId': accountId,
      'bookedOn': 20261101,
      'amountMinor': 100 + seq,
      'currency': 'MYR',
      'status': m.TxnStatus.posted.name,
      'memo': 'sync',
      'labels': const <String>[],
      'splits': const <Map<String, Object?>>[],
      'meta': const <String, String>{},
    });
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
    var batch = <(String, Map<String, Object?>)>[];
    Future<void> flush() async {
      if (batch.isEmpty) {
        return;
      }
      await db.transaction((txn) async {
        for (final (id, map) in batch) {
          await _txns.record(id).put(txn, map);
        }
      });
      restored += batch.length;
      batch = <(String, Map<String, Object?>)>[];
    }

    await for (final line in lines) {
      if (line.isEmpty) {
        continue;
      }
      final map = jsonDecode(line) as Map<String, Object?>;
      final id = map.remove('id')! as String;
      batch.add((id, map));
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
