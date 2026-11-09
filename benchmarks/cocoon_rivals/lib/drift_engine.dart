/// The drift engine: bulk import through drift's batch inserts, reads
/// through drift's select API (and one custom SQL aggregate for the year
/// report — that is what drift's docs recommend for sums), single writes
/// through `insertOnConflictUpdate`. This is the SQLite speed limit the
/// document engines are measured against.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/drift_models.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/models.dart' as m;

/// One row the import and the restore write.
TxnRowsCompanion _rowOf({
  required String id,
  required String accountId,
  required m.Txn txn,
}) => TxnRowsCompanion.insert(
  id: id,
  accountId: accountId,
  bookedOn: txn.bookedOn,
  amountMinor: txn.amountMinor,
  currency: txn.currency,
  status: txn.status.name,
  memo: Value(txn.memo),
  labelsJson: jsonEncode(txn.labels),
  splitsJson: jsonEncode([
    for (final split in txn.splits)
      {'label': split.label, 'shareMinor': split.shareMinor},
  ]),
  metaJson: jsonEncode(txn.meta),
);

final class DriftBenchEngine implements BenchEngine {
  /// Builds the engine; [backupFile] overrides the NDJSON file `restore`
  /// reads (the tests point it at a small backup).
  DriftBenchEngine({String? backupFile}) : _backupFile = backupFile;

  /// The NDJSON file `restore` reads, or the shared one when null.
  final String? _backupFile;

  AppDb? _db;

  Future<AppDb> _open(String baseDir) async {
    final db = AppDb(
      NativeDatabase.createInBackground(
        File(BenchDataset.driftPath(baseDir)),
      ),
    );
    await db.customSelect('SELECT 1').getSingle();
    _db = db;
    return db;
  }

  @override
  String get name => 'drift';

  @override
  String dbPath(String baseDir) => BenchDataset.driftPath(baseDir);

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
    // The accounts live in the seed only: every workload derives account ids
    // from the dataset, and the step models drift as the plain txns table.
    final sw = Stopwatch()..start();
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        start + importBatchSize > data.txns.length
            ? data.txns.length
            : start + importBatchSize,
      );
      await db.batch((b) {
        b.insertAll(
          db.txnRows,
          [
            for (final benchTxn in batch)
              _rowOf(
                id: benchTxn.id,
                accountId: benchTxn.accountId,
                txn: benchTxn.txn,
              ),
          ],
          mode: InsertMode.insertOrReplace,
        );
      });
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> coldOpen(String baseDir, {required String accountId}) async {
    final sw = Stopwatch()..start();
    final db = await _open(baseDir);
    final first = await _latest50(db, accountId, 1);
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

  Future<List<TxnRow>> _latest50(AppDb db, String accountId, int limit) {
    return (db.select(db.txnRows)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.bookedOn),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .get();
  }

  @override
  Future<List<String>> latest50Ids(String accountId, String baseDir) async {
    final rows = await _latest50(_db!, accountId, 50);
    return [for (final row in rows) row.id];
  }

  @override
  Future<List<int>> latest50Us(List<String> accountIds, String baseDir) async {
    final db = _db!;
    final micros = <int>[];
    for (final accountId in accountIds) {
      final sw = Stopwatch()..start();
      final rows = await _latest50(db, accountId, 50);
      sw.stop();
      if (rows.isEmpty) {
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
    final firstDay = year * 10000 + 101;
    final lastDay = year * 10000 + 1231;
    // The account's year, one indexed range scan; sums in Dart.
    final query = db.select(db.txnRows)
      ..where(
        (t) =>
            t.accountId.equals(accountId) &
            t.bookedOn.isBiggerOrEqualValue(firstDay) &
            t.bookedOn.isSmallerOrEqualValue(lastDay),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.bookedOn)]);
    var scanned = 0;
    final rows = await query.get();
    for (final row in rows) {
      final month = row.bookedOn ~/ 100 % 100;
      totals[year * 100 + month] =
          (totals[year * 100 + month] ?? 0) + row.amountMinor;
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
        // Keyset-pages every row by id (the ids sort like the numbers they
        // encode) and keeps only the reservoir.
        final db = _db!;
        var lastId = '';
        while (true) {
          final page = await (db.select(db.txnRows)
                ..where((t) => t.id.isBiggerThanValue(lastId))
                ..orderBy([(t) => OrderingTerm.asc(t.id)])
                ..limit(monthlyPageSize))
              .get();
          if (page.isEmpty) {
            break;
          }
          for (final row in page) {
            yield (
              accountId: row.accountId,
              id: row.id,
              value: row,
            );
          }
          lastId = page.last.id;
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
      final rows = await (db.select(
        db.txnRows,
      )..where((t) => t.id.equals(id.id))).get();
      if (rows.isNotEmpty) {
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
      final row = doc.value as TxnRow;
      final sw = Stopwatch()..start();
      await db
          .into(db.txnRows)
          .insertOnConflictUpdate(
            TxnRowsCompanion.insert(
              id: row.id,
              accountId: row.accountId,
              bookedOn: row.bookedOn,
              amountMinor: row.amountMinor,
              currency: row.currency,
              status: row.status,
              memo: Value(row.memo),
              labelsJson: row.labelsJson,
              splitsJson: row.splitsJson,
              metaJson: row.metaJson,
            ),
          );
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<List<String>> rangeMonthIds(String baseDir) async {
    final db = _db!;
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final ids = <String>[];
    var pages = 0;
    while (true) {
      final page = await (db.select(db.txnRows)
            ..where(
              (t) =>
                  t.bookedOn.isBiggerOrEqualValue(firstDay) &
                  t.bookedOn.isSmallerOrEqualValue(lastDay),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.bookedOn),
              (t) => OrderingTerm.asc(t.id),
            ])
            ..limit(rangePageSize, offset: pages * rangePageSize))
          .get();
      if (page.isEmpty) {
        break;
      }
      ids.addAll([for (final row in page) row.id]);
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
    final db = _db!;
    final firstDay = reportYear * 10000 + 101;
    final lastDay = reportYear * 10000 + 1231;
    final sw = Stopwatch()..start();
    // The aggregate a SQL engine exists for: group by account and month.
    final rows = await db
        .customSelect(
          'SELECT account_id, (booked_on / 100) % 100 AS m, '
          'SUM(amount_minor) AS s, COUNT(*) AS c FROM txn_rows '
          'WHERE booked_on >= ? AND booked_on <= ? '
          'GROUP BY account_id, m',
          variables: [Variable(firstDay), Variable(lastDay)],
        )
        .get();
    final sums = <String, int>{};
    final accounts = <String>{};
    for (final row in rows) {
      final accountId = row.read<String>('account_id');
      final month = row.read<int>('m');
      final sum = row.read<int>('s');
      sums['$accountId|${reportYear * 100 + month}'] = sum;
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
    final db = _db!;
    final rows = await (db.select(db.txnRows)
          ..where((t) => t.status.equals(m.TxnStatus.pending.name))
          ..orderBy([
            (t) => OrderingTerm.desc(t.bookedOn),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(50))
        .get();
    return [for (final row in rows) row.id];
  }

  @override
  Future<void> writeOneTxn(String accountId, String id, int seq) async {
    final db = _db!;
    await db
        .into(db.txnRows)
        .insertOnConflictUpdate(
          _rowOf(id: id, accountId: accountId, txn: syncTxnOf(seq)),
        );
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
    var batch = <TxnRowsCompanion>[];
    Future<void> flush() async {
      if (batch.isEmpty) {
        return;
      }
      await db.batch(
        (b) => b.insertAll(
          db.txnRows,
          batch,
          mode: InsertMode.insertOrReplace,
        ),
      );
      restored += batch.length;
      batch = <TxnRowsCompanion>[];
    }

    await for (final line in lines) {
      if (line.isEmpty) {
        continue;
      }
      final map = jsonDecode(line) as Map<String, Object?>;
      final (:accountId, :txn) = txnFromBackupMap(map);
      batch.add(
        _rowOf(id: map['id']! as String, accountId: accountId, txn: txn),
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
