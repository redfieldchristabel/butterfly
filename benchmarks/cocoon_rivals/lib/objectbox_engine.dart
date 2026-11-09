/// The ObjectBox engine: native store (the C library installed by
/// objectbox's install script), one flat box, bulk import through `putMany`
/// batches, reads through ObjectBox's query API with its property queries
/// for the report, single writes through `put`. Pagination uses the query's
/// own offset/limit setters.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/models.dart' as m;
import 'package:cocoon_rivals/objectbox.g.dart';
import 'package:cocoon_rivals/objectbox_models.dart';

/// One record the import and the restore write.
ObTxn _recordOf({
  required String id,
  required String accountId,
  required m.Txn txn,
}) => ObTxn()
  ..id = obIntIdOf(id)
  ..code = id
  ..accountId = accountId
  ..bookedOn = txn.bookedOn
  ..amountMinor = txn.amountMinor
  ..currency = txn.currency
  ..status = txn.status.name
  ..memo = txn.memo
  ..labelsJson = jsonEncode(txn.labels)
  ..splitsJson = jsonEncode([
    for (final split in txn.splits)
      {'label': split.label, 'shareMinor': split.shareMinor},
  ])
  ..metaJson = jsonEncode(txn.meta);

final class ObjectBoxBenchEngine implements BenchEngine {
  /// Builds the engine; [backupFile] overrides the NDJSON file `restore`
  /// reads (the tests point it at a small backup).
  ObjectBoxBenchEngine({String? backupFile}) : _backupFile = backupFile;

  /// The NDJSON file `restore` reads, or the shared one when null.
  final String? _backupFile;

  Store? _store;
  late Box<ObTxn> _box;

  Future<Store> _open(String baseDir) async {
    final store = Store(
      getObjectBoxModel(),
      directory: BenchDataset.objectboxPath(baseDir),
    );
    _store = store;
    _box = store.box<ObTxn>();
    return store;
  }

  @override
  String get name => 'objectbox';

  @override
  String dbPath(String baseDir) => BenchDataset.objectboxPath(baseDir);

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
    final store = await _open(baseDir);
    // Accounts live in the seed only (account ids are deterministic);
    // ObjectBox holds the flat txn box, its normal shape for this data.
    final sw = Stopwatch()..start();
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        start + importBatchSize > data.txns.length
            ? data.txns.length
            : start + importBatchSize,
      );
      store.box<ObTxn>().putMany([
        for (final benchTxn in batch)
          _recordOf(
            id: benchTxn.id,
            accountId: benchTxn.accountId,
            txn: benchTxn.txn,
          ),
      ]);
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> bulkimport(BenchDataset data, String baseDir) async {
    // Sequential in-process ops (the smoke test's metrics loop) close the
    // live store first, and the bulk load leaves nothing open, like
    // `restore`: the read ops keep measuring `import`'s database.
    _store?.close();
    _store = null;
    final store = await _open(baseDir);
    final sw = Stopwatch()..start();
    // ObjectBox's best documented bulk API: one putMany.
    store.box<ObTxn>().putMany([
      for (final benchTxn in data.txns)
        _recordOf(
          id: benchTxn.id,
          accountId: benchTxn.accountId,
          txn: benchTxn.txn,
        ),
    ]);
    sw.stop();
    store.close();
    _store = null;
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> coldOpen(String baseDir, {required String accountId}) async {
    final sw = Stopwatch()..start();
    // A fresh process opens here; an already-open instance (the smoke
    // test's sequential ops) reuses its store — ObjectBox allows one Store
    // per directory per isolate.
    final store = _store ?? await _open(baseDir);
    final box = store.box<ObTxn>();
    final first = box
        .query(
          ObTxn_.accountId.equals(accountId) & ObTxn_.bookedOn.greaterThan(0),
        )
        .order(ObTxn_.bookedOn, flags: Order.descending)
        .order(ObTxn_.id, flags: Order.descending)
        .build()
        .property(ObTxn_.id)
        .find();
    sw.stop();
    if (first.isEmpty) {
      throw StateError('cold open: first query answered with nothing');
    }
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> rssAfterOpen(String baseDir) async {
    _store ??= await _open(baseDir);
    return ProcessInfo.currentRss;
  }

  @override
  Future<void> open(String baseDir) async {
    _store ??= await _open(baseDir);
  }

  @override
  Future<List<String>> latest50Ids(String accountId, String baseDir) async {
    final query = _box
        .query(ObTxn_.accountId.equals(accountId))
        .order(ObTxn_.bookedOn, flags: Order.descending)
        .order(ObTxn_.id, flags: Order.descending)
        .build();
    try {
      query.limit = 50;
      final records = query.find();
      return [for (final record in records) record.code];
    } finally {
      query.close();
    }
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
    final query = _box
        .query(
          ObTxn_.accountId.equals(accountId) &
              ObTxn_.bookedOn.between(firstDay, lastDay),
        )
        .build();
    try {
      // Property queries read only the two fields the sum needs, in the
      // query's (internal id) order, so the two lists stay aligned.
      final days = query.property(ObTxn_.bookedOn).find();
      final amounts = query.property(ObTxn_.amountMinor).find();
      for (var i = 0; i < days.length; i++) {
        final month = days[i] ~/ 100 % 100;
        totals[year * 100 + month] =
            (totals[year * 100 + month] ?? 0) + amounts[i];
        scanned++;
      }
    } finally {
      query.close();
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
        // Keyset-pages every entity by internal id (an explicit order keeps
        // the walk deterministic). A keyset, not an offset: offset paging
        // re-scans the index from the top for every page, which does not
        // survive 1M entities inside the harness's untimed sampler.
        var lastId = 0;
        while (true) {
          final query =
              _box.query(ObTxn_.id.greaterThan(lastId)).order(ObTxn_.id).build()
                ..limit = monthlyPageSize;
          try {
            final page = query.find();
            if (page.isEmpty) {
              break;
            }
            for (final record in page) {
              yield (
                accountId: record.accountId,
                id: record.code,
                value: record,
              );
            }
            if (page.length < monthlyPageSize) {
              break;
            }
            lastId = page.last.id;
          } finally {
            query.close();
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
      // The numeric id IS the string id's digits, so a get is a native
      // primary-key lookup.
      if (_box.get(obIntIdOf(id.id)) != null) {
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
      final record = doc.value as ObTxn;
      final sw = Stopwatch()..start();
      _box.put(record);
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<List<String>> rangeMonthIds(String baseDir) async {
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final query = _box
        .query(ObTxn_.bookedOn.between(firstDay, lastDay))
        .order(ObTxn_.bookedOn)
        .order(ObTxn_.id)
        .build();
    try {
      final ids = <String>[];
      var pages = 0;
      query.limit = rangePageSize;
      while (true) {
        query.offset = pages * rangePageSize;
        final page = query.find();
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
    } finally {
      query.close();
    }
  }

  @override
  Future<(int, Map<String, int>, int)> yearReport(String baseDir) async {
    final sw = Stopwatch()..start();
    final firstDay = reportYear * 10000 + 101;
    final lastDay = reportYear * 10000 + 1231;
    final sums = <String, int>{};
    var accountsCovered = 0;
    // Per account: an indexed query and two property queries (aligned in
    // internal id order) — ObjectBox's documented way to aggregate.
    for (final accountId in benchAccountIds()) {
      final query = _box
          .query(
            ObTxn_.accountId.equals(accountId) &
                ObTxn_.bookedOn.between(firstDay, lastDay),
          )
          .build();
      try {
        final days = query.property(ObTxn_.bookedOn).find();
        if (days.isEmpty) {
          continue;
        }
        final amounts = query.property(ObTxn_.amountMinor).find();
        accountsCovered++;
        for (var i = 0; i < days.length; i++) {
          final month = days[i] ~/ 100 % 100;
          final key = '$accountId|${reportYear * 100 + month}';
          sums[key] = (sums[key] ?? 0) + amounts[i];
        }
      } finally {
        query.close();
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
    final query = _box
        .query(ObTxn_.status.equals(m.TxnStatus.pending.name))
        .order(ObTxn_.bookedOn, flags: Order.descending)
        .order(ObTxn_.id, flags: Order.descending)
        .build();
    try {
      query.limit = 50;
      final records = query.find();
      return [for (final record in records) record.code];
    } finally {
      query.close();
    }
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
    // No amount filter (the dataset's 50 smallest amounts are always
    // debits); the amount index backs the first order, the id order
    // breaks the ties.
    final query = _box
        .query()
        .order(ObTxn_.amountMinor)
        .order(ObTxn_.id)
        .build();
    try {
      query.limit = 50;
      final records = query.find();
      return [for (final record in records) record.code];
    } finally {
      query.close();
    }
  }

  @override
  Future<List<String>> amountRangeIds(String baseDir) async {
    // The amount index serves the band and the first order; ObjectBox's
    // idiom is offset/limit pagination (as in `rangeMonthIds`).
    final query = _box
        .query(ObTxn_.amountMinor.between(amountBandLo, amountBandHi - 1))
        .order(ObTxn_.amountMinor)
        .order(ObTxn_.id)
        .build();
    try {
      final ids = <String>[];
      var pages = 0;
      query.limit = amountRangePageSize;
      while (true) {
        query.offset = pages * amountRangePageSize;
        final page = query.find();
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
    } finally {
      query.close();
    }
  }

  @override
  Future<List<String>> pendingMonthIds(String baseDir) async {
    // The compound filter through the status + bookedOn indexes, offset
    // paging (the idiom, as in `rangeMonthIds`).
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final query = _box
        .query(
          ObTxn_.status.equals(m.TxnStatus.pending.name) &
              ObTxn_.bookedOn.between(firstDay, lastDay),
        )
        .order(ObTxn_.bookedOn)
        .order(ObTxn_.id)
        .build();
    try {
      final ids = <String>[];
      var pages = 0;
      query.limit = rangePageSize;
      while (true) {
        query.offset = pages * rangePageSize;
        final page = query.find();
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
    } finally {
      query.close();
    }
  }

  @override
  Future<({List<List<String>> pageIds, List<int> pageUs})> deeppagePages(
    String accountId,
    String baseDir,
  ) async {
    // ObjectBox's idiom is offset/limit pagination: page N re-reads the
    // account's query from the top — what the op is here to measure.
    final query = _box
        .query(ObTxn_.accountId.equals(accountId))
        .order(ObTxn_.bookedOn, flags: Order.descending)
        .order(ObTxn_.id, flags: Order.descending)
        .build();
    try {
      final pageIds = <List<String>>[];
      final pageUs = <int>[];
      query.limit = deeppagePageSize;
      for (var page = 0; page < deeppagePageCount; page++) {
        query.offset = page * deeppagePageSize;
        final sw = Stopwatch()..start();
        final records = query.find();
        sw.stop();
        if (records.isEmpty) {
          break;
        }
        pageIds.add([for (final record in records) record.code]);
        pageUs.add(sw.elapsedMicroseconds);
      }
      return (pageIds: pageIds, pageUs: pageUs);
    } finally {
      query.close();
    }
  }

  @override
  Future<({List<int> us, int count})> pendingCountUs(String baseDir) async {
    final micros = <int>[];
    var count = 0;
    for (var i = 0; i < countRuns; i++) {
      final query = _box
          .query(ObTxn_.status.equals(m.TxnStatus.pending.name))
          .build();
      try {
        final sw = Stopwatch()..start();
        count = query.count();
        sw.stop();
        micros.add(sw.elapsedMicroseconds);
      } finally {
        query.close();
      }
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
      final query = _box
          .query(
            ObTxn_.accountId.equals(accountId) &
                ObTxn_.bookedOn.between(firstDay, lastDay),
          )
          .build();
      try {
        final sw = Stopwatch()..start();
        count = query.count();
        sw.stop();
        micros.add(sw.elapsedMicroseconds);
      } finally {
        query.close();
      }
    }
    return (us: micros, count: count);
  }

  @override
  Future<void> writeOneTxn(String accountId, String id, int seq) {
    _box.put(_recordOf(id: id, accountId: accountId, txn: syncTxnOf(seq)));
    return Future.value();
  }

  @override
  Future<(int, int)> restore(String baseDir) async {
    // A fresh process has nothing open; sequential in-process ops (the
    // smoke test) close the live store first so the restore directory gets
    // its own store.
    _store?.close();
    _store = null;
    wipe(baseDir);
    Directory(baseDir).createSync(recursive: true);
    final store = await _open(baseDir);
    final box = store.box<ObTxn>();
    final sw = Stopwatch()..start();
    var restored = 0;
    final file = File(_backupFile ?? backupPath());
    final lines = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    var batch = <ObTxn>[];
    void flush() {
      if (batch.isEmpty) {
        return;
      }
      box.putMany(batch);
      restored += batch.length;
      batch = <ObTxn>[];
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
        flush();
      }
    }
    flush();
    sw.stop();
    store.close();
    _store = null;
    return (sw.elapsedMilliseconds, restored);
  }

  @override
  Future<void> close() async {
    _store?.close();
    _store = null;
  }
}
