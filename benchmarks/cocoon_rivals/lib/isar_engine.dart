/// The Isar engine: native C core (`Isar.initializeIsarCore(download:
/// true)`), one flat collection, bulk import through `putAll` batches, reads
/// through Isar's where-clause (index) + filter + sort query API. Where the
/// query API cannot express the shared tie-break directly, the sort names
/// the `code` property (the stable string id) — Isar's native sort applies
/// it as a secondary key.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/isar_models.dart';
import 'package:cocoon_rivals/models.dart' as m;
import 'package:isar_community/isar.dart';

/// One record the import and the restore write.
IsarTxn _recordOf({
  required String id,
  required String accountId,
  required m.Txn txn,
}) => IsarTxn()
  ..id = isarIntIdOf(id)
  ..code = id
  ..accountId = accountId
  ..bookedOn = txn.bookedOn
  ..amountMinor = txn.amountMinor
  ..currency = txn.currency
  ..status = txn.status
  ..memo = txn.memo
  ..labels = txn.labels
  ..splits = [
    for (final split in txn.splits)
      IsarSplit()
        ..label = split.label
        ..shareMinor = split.shareMinor,
  ]
  ..metaJson = jsonEncode(txn.meta);

final class IsarBenchEngine implements BenchEngine {
  /// Builds the engine; [backupFile] overrides the NDJSON file `restore`
  /// reads (the tests point it at a small backup).
  IsarBenchEngine({String? backupFile}) : _backupFile = backupFile;

  /// The NDJSON file `restore` reads, or the shared one when null.
  final String? _backupFile;

  Isar? _isar;

  Future<Isar> _open(String baseDir) async {
    await Isar.initializeIsarCore(download: true);
    // Isar does not create its directory; an Isar app opens into one that
    // exists.
    await Directory(BenchDataset.isarPath(baseDir)).create(recursive: true);
    final isar = await Isar.open(
      [IsarTxnSchema],
      directory: BenchDataset.isarPath(baseDir),
      name: 'rivals',
    );
    _isar = isar;
    return isar;
  }

  @override
  String get name => 'isar';

  @override
  String dbPath(String baseDir) => BenchDataset.isarPath(baseDir);

  @override
  void wipe(String baseDir) {
    final dir = Directory(baseDir);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  @override
  int fileSize(String baseDir) => dirSizeWithSidecars(dbPath(baseDir));

  @override
  Future<int> import(BenchDataset data, String baseDir) async {
    final isar = await _open(baseDir);
    // Accounts live in the seed only (account ids are deterministic); Isar
    // holds the flat txn collection, its normal shape for this data.
    final sw = Stopwatch()..start();
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        start + importBatchSize > data.txns.length
            ? data.txns.length
            : start + importBatchSize,
      );
      await isar.writeTxn(() async {
        await isar.isarTxns.putAll([
          for (final benchTxn in batch)
            _recordOf(
              id: benchTxn.id,
              accountId: benchTxn.accountId,
              txn: benchTxn.txn,
            ),
        ]);
      });
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> bulkimport(BenchDataset data, String baseDir) async {
    // Sequential in-process ops (the smoke test's metrics loop) must close
    // the live instance first — Isar names are process-global — and the
    // bulk load leaves nothing open, like `restore`: the read ops keep
    // measuring `import`'s database.
    await _isar?.close();
    _isar = null;
    final isar = await _open(baseDir);
    final sw = Stopwatch()..start();
    // Isar's best documented bulk API: one writeTxn around one putAll.
    await isar.writeTxn(() async {
      await isar.isarTxns.putAll([
        for (final benchTxn in data.txns)
          _recordOf(
            id: benchTxn.id,
            accountId: benchTxn.accountId,
            txn: benchTxn.txn,
          ),
      ]);
    });
    sw.stop();
    await isar.close();
    _isar = null;
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> coldOpen(String baseDir, {required String accountId}) async {
    final sw = Stopwatch()..start();
    // A fresh process opens here; an already-open instance (the smoke
    // test's sequential ops) reuses its database, like the other engines'
    // `_db ??=` pattern.
    final isar = _isar ?? await _open(baseDir);
    final first = await isar.isarTxns
        .where(sort: Sort.desc)
        .accountIdEqualToAnyBookedOn(accountId)
        .sortByBookedOnDesc()
        .limit(1)
        .findAll();
    sw.stop();
    if (first.isEmpty) {
      throw StateError('cold open: first query answered with nothing');
    }
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> rssAfterOpen(String baseDir) async {
    _isar ??= await _open(baseDir);
    return ProcessInfo.currentRss;
  }

  @override
  Future<void> open(String baseDir) async {
    _isar ??= await _open(baseDir);
  }

  @override
  Future<List<String>> latest50Ids(String accountId, String baseDir) async {
    // The composite index selects the account; the native sort applies the
    // contract order (bookedOn DESC, then the string id DESC).
    final records = await _isar!.isarTxns
        .where()
        .accountIdEqualToAnyBookedOn(accountId)
        .sortByBookedOnDesc()
        .thenByCodeDesc()
        .limit(50)
        .findAll();
    return [for (final record in records) record.code];
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
    final isar = _isar!;
    final totals = <int, int>{};
    var scanned = 0;
    final firstDay = year * 10000 + 101;
    final lastDay = year * 10000 + 1231;
    // The composite index selects the account; the filter trims the year.
    final records = await isar.isarTxns
        .where()
        .accountIdEqualToAnyBookedOn(accountId)
        .filter()
        .bookedOnBetween(firstDay, lastDay)
        .findAll();
    for (final record in records) {
      final month = record.bookedOn ~/ 100 % 100;
      totals[year * 100 + month] =
          (totals[year * 100 + month] ?? 0) + record.amountMinor;
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
        // Offset-pages every record in Isar's id order and keeps only the
        // reservoir: one page of objects at a time, nothing more.
        final isar = _isar!;
        var offset = 0;
        while (true) {
          final page = await isar.isarTxns
              .where()
              .offset(offset)
              .limit(monthlyPageSize)
              .findAll();
          if (page.isEmpty) {
            break;
          }
          for (final record in page) {
            yield (accountId: record.accountId, id: record.code, value: record);
          }
          if (page.length < monthlyPageSize) {
            break;
          }
          offset += monthlyPageSize;
        }
      });

  @override
  Future<(int, int)> getsById(
    List<({String accountId, String id})> ids,
    String baseDir,
  ) async {
    final isar = _isar!;
    var hits = 0;
    final sw = Stopwatch()..start();
    for (final id in ids) {
      // The unique `code` index is how an Isar app gets by a string id.
      final record = await isar.isarTxns
          .where()
          .codeEqualTo(id.id)
          .limit(1)
          .findFirst();
      if (record != null) {
        hits++;
      }
    }
    sw.stop();
    return (sw.elapsedMilliseconds, hits);
  }

  @override
  Future<List<int>> writeUs(List<SampledDoc> docs, String baseDir) async {
    final isar = _isar!;
    final micros = <int>[];
    for (final doc in docs) {
      final record = doc.value as IsarTxn;
      final sw = Stopwatch()..start();
      // One writeTxn per write — Isar requires it, and it is the cost a
      // single-record Isar app pays per write.
      await isar.writeTxn(() async {
        await isar.isarTxns.put(record);
      });
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<List<String>> rangeMonthIds(String baseDir) async {
    final isar = _isar!;
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final ids = <String>[];
    var pages = 0;
    // No (bookedOn)-only index is declared, so every page is one native
    // filter pass with Isar's own offset/limit pagination.
    while (true) {
      final page = await isar.isarTxns
          .filter()
          .bookedOnBetween(firstDay, lastDay)
          .sortByBookedOn()
          .thenByCode()
          .offset(pages * rangePageSize)
          .limit(rangePageSize)
          .findAll();
      if (page.isEmpty) {
        break;
      }
      ids.addAll([for (final record in page) record.code]);
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
    final isar = _isar!;
    final sw = Stopwatch()..start();
    final firstDay = reportYear * 10000 + 101;
    final lastDay = reportYear * 10000 + 1231;
    final sums = <String, int>{};
    var accountsCovered = 0;
    // Per account: the composite index selects the rows, the property
    // queries read only the two fields the sum needs, aligned in id order.
    for (final accountId in benchAccountIds()) {
      final query = isar.isarTxns
          .where()
          .accountIdEqualToAnyBookedOn(accountId)
          .filter()
          .bookedOnBetween(firstDay, lastDay);
      final days = await query.bookedOnProperty().findAll();
      final amounts = await query.amountMinorProperty().findAll();
      if (days.isEmpty) {
        continue;
      }
      accountsCovered++;
      for (var i = 0; i < days.length; i++) {
        final month = days[i] ~/ 100 % 100;
        final key = '$accountId|${reportYear * 100 + month}';
        sums[key] = (sums[key] ?? 0) + amounts[i];
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
    // The status index selects the pending records; the native sort applies
    // the contract order over them.
    final records = await _isar!.isarTxns
        .where()
        .statusEqualTo(m.TxnStatus.pending)
        .sortByBookedOnDesc()
        .thenByCodeDesc()
        .limit(50)
        .findAll();
    return [for (final record in records) record.code];
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

  /// The full int range: a where clause over the amount index walks it in
  /// its own ascending order (amountMinor, then the internal id — assigned
  /// from the string id, so ties break in the contract's id ASC order).
  static const _intMin = -9223372036854775808;
  static const _intMax = 9223372036854775807;

  @override
  Future<List<String>> bigspendIds(String baseDir) async {
    // No amount filter (the dataset's 50 smallest amounts are always
    // debits); the where clause walks the amount index, most negative
    // first.
    final records = await _isar!.isarTxns
        .where()
        .amountMinorBetween(_intMin, _intMax)
        .limit(50)
        .findAll();
    return [for (final record in records) record.code];
  }

  @override
  Future<List<String>> amountRangeIds(String baseDir) async {
    // The amount index serves the band and the contract order directly;
    // Isar's idiom is offset/limit pagination (as in `rangeMonthIds`).
    final isar = _isar!;
    final ids = <String>[];
    var pages = 0;
    while (true) {
      final page = await isar.isarTxns
          .where()
          // Isar's between is inclusive on both ends; [lo, hi-1] == [lo, hi)
          // for integers.
          .amountMinorBetween(amountBandLo, amountBandHi - 1)
          .offset(pages * amountRangePageSize)
          .limit(amountRangePageSize)
          .findAll();
      if (page.isEmpty) {
        break;
      }
      ids.addAll([for (final record in page) record.code]);
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
    // The status index selects the pending records, the filter trims the
    // month, the native sort applies the contract order, offset paging (the
    // idiom, as in `rangeMonthIds`).
    final isar = _isar!;
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final ids = <String>[];
    var pages = 0;
    while (true) {
      final page = await isar.isarTxns
          .where()
          .statusEqualTo(m.TxnStatus.pending)
          .filter()
          .bookedOnBetween(firstDay, lastDay)
          .sortByBookedOn()
          .thenByCode()
          .offset(pages * rangePageSize)
          .limit(rangePageSize)
          .findAll();
      if (page.isEmpty) {
        break;
      }
      ids.addAll([for (final record in page) record.code]);
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
    // Isar's idiom is offset/limit pagination: page N re-reads the
    // account's index selection from the top — what the op is here to
    // measure.
    final isar = _isar!;
    final pageIds = <List<String>>[];
    final pageUs = <int>[];
    for (var page = 0; page < deeppagePageCount; page++) {
      final sw = Stopwatch()..start();
      final records = await isar.isarTxns
          .where()
          .accountIdEqualToAnyBookedOn(accountId)
          .sortByBookedOnDesc()
          .thenByCodeDesc()
          .offset(page * deeppagePageSize)
          .limit(deeppagePageSize)
          .findAll();
      sw.stop();
      if (records.isEmpty) {
        break;
      }
      pageIds.add([for (final record in records) record.code]);
      pageUs.add(sw.elapsedMicroseconds);
    }
    return (pageIds: pageIds, pageUs: pageUs);
  }

  @override
  Future<({List<int> us, int count})> pendingCountUs(String baseDir) async {
    final micros = <int>[];
    var count = 0;
    for (var i = 0; i < countRuns; i++) {
      final sw = Stopwatch()..start();
      count = await _isar!.isarTxns
          .where()
          .statusEqualTo(m.TxnStatus.pending)
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
    final firstDay = reportYear * 10000 + 101;
    final lastDay = reportYear * 10000 + 1231;
    final micros = <int>[];
    var count = 0;
    for (var i = 0; i < countRuns; i++) {
      final sw = Stopwatch()..start();
      count = await _isar!.isarTxns
          .where()
          .accountIdEqualToAnyBookedOn(accountId)
          .filter()
          .bookedOnBetween(firstDay, lastDay)
          .count();
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return (us: micros, count: count);
  }

  @override
  Future<void> writeOneTxn(String accountId, String id, int seq) {
    final record = _recordOf(id: id, accountId: accountId, txn: syncTxnOf(seq));
    return _isar!.writeTxn(() async {
      await _isar!.isarTxns.put(record);
    });
  }

  @override
  Future<(int, int)> restore(String baseDir) async {
    // A fresh process has nothing open; sequential in-process ops (the
    // smoke test) must close the live instance first — Isar names are
    // process-global.
    await _isar?.close();
    _isar = null;
    wipe(baseDir);
    Directory(baseDir).createSync(recursive: true);
    final isar = await _open(baseDir);
    final sw = Stopwatch()..start();
    var restored = 0;
    final file = File(_backupFile ?? backupPath());
    final lines = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    var batch = <IsarTxn>[];
    Future<void> flush() async {
      if (batch.isEmpty) {
        return;
      }
      await isar.writeTxn(() async {
        await isar.isarTxns.putAll(batch);
      });
      restored += batch.length;
      batch = <IsarTxn>[];
    }

    await for (final line in lines) {
      if (line.isEmpty) {
        continue;
      }
      final map = jsonDecode(line) as Map<String, Object?>;
      final (:accountId, :txn) = txnFromBackupMap(map);
      batch.add(
        _recordOf(id: map['id']! as String, accountId: accountId, txn: txn),
      );
      if (batch.length >= restoreBatchSize) {
        await flush();
      }
    }
    await flush();
    sw.stop();
    await isar.close();
    _isar = null;
    return (sw.elapsedMilliseconds, restored);
  }

  @override
  Future<void> close() async {
    await _isar?.close();
    _isar = null;
  }
}
