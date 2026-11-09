/// The Hive CE side of the benchmark: one box, string key → stored map, the
/// way a Hive app holds a big transaction history. Hive has no query engine
/// and no indexes — that is the point of including it: every read filters
/// and sorts Dart-side over the box's in-RAM values, and the box loads
/// everything at open.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/models.dart' as m;
import 'package:hive_ce/hive.dart';

final class HiveBenchEngine implements BenchEngine {
  /// Builds the engine; [backupFile] overrides the NDJSON file `restore`
  /// reads (the tests point it at a small backup).
  HiveBenchEngine({String? backupFile}) : _backupFile = backupFile;

  /// The NDJSON file `restore` reads, or the shared one when null.
  final String? _backupFile;

  Box<Map<dynamic, dynamic>>? _txns;

  Future<Box<Map<dynamic, dynamic>>> _open(String baseDir) async {
    Hive.init(BenchDataset.hivePath(baseDir));
    final box = await Hive.openBox<Map<dynamic, dynamic>>('txns');
    _txns = box;
    return box;
  }

  @override
  String get name => 'hive';

  @override
  String dbPath(String baseDir) => '$baseDir/txns.hive';

  @override
  void wipe(String baseDir) {
    final dir = Directory(baseDir);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  @override
  int fileSize(String baseDir) {
    var total = 0;
    final dir = Directory(baseDir);
    if (!dir.existsSync()) {
      return 0;
    }
    for (final entity in dir.listSync()) {
      if (entity is File && entity.path.endsWith('.hive')) {
        total += entity.lengthSync();
      }
    }
    return total;
  }

  @override
  Future<int> import(BenchDataset data, String baseDir) async {
    final box = await _open(baseDir);
    // Accounts live in the seed only (account ids are deterministic); Hive
    // holds the one txns box, its normal shape for this data.
    final sw = Stopwatch()..start();
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        start + importBatchSize > data.txns.length
            ? data.txns.length
            : start + importBatchSize,
      );
      await box.putAll({
        for (final benchTxn in batch) benchTxn.id: BenchDataset.sembastMapOf(
          benchTxn,
        ),
      });
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> coldOpen(String baseDir, {required String accountId}) async {
    final sw = Stopwatch()..start();
    final box = await _open(baseDir);
    // Hive has no queries: the "first query" is the same Dart-side scan the
    // app would run, shortened to one hit.
    for (final value in box.values) {
      if (value['accountId'] == accountId) {
        break;
      }
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  @override
  Future<int> rssAfterOpen(String baseDir) async {
    _txns ??= await _open(baseDir);
    return ProcessInfo.currentRss;
  }

  @override
  Future<void> open(String baseDir) async {
    _txns ??= await _open(baseDir);
  }

  @override
  Future<List<String>> latest50Ids(String accountId, String baseDir) async {
    // No query engine: scan the box, keep the top 50 by the contract order.
    final top = <MapEntry<String, Map<dynamic, dynamic>>>[];
    for (final key in _txns!.keys.cast<String>()) {
      final value = _txns!.get(key)!;
      if (value['accountId'] != accountId) {
        continue;
      }
      top.add(MapEntry(key, value));
    }
    top.sort((a, b) {
      final byDay = (b.value['bookedOn']! as int).compareTo(
        a.value['bookedOn']! as int,
      );
      if (byDay != 0) {
        return byDay;
      }
      return b.key.compareTo(a.key);
    });
    return [
      for (final entry in top.take(50)) entry.key,
    ];
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
    for (final value in _txns!.values) {
      if (value['accountId'] != accountId) {
        continue;
      }
      final bookedOn = value['bookedOn']! as int;
      if (bookedOn ~/ 10000 != year) {
        continue;
      }
      final month = bookedOn ~/ 100 % 100;
      totals[year * 100 + month] =
          (totals[year * 100 + month] ?? 0) + (value['amountMinor']! as int);
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
        // Walks every stored entry once, in Hive's key order, and keeps only
        // the reservoir. The box is already all in RAM after open.
        for (final key in _txns!.keys.cast<String>()) {
          final value = _txns!.get(key)!;
          yield (
            accountId: value['accountId']! as String,
            id: key,
            value: value,
          );
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
      if (_txns!.get(id.id) != null) {
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
      await _txns!.put(doc.id, doc.value as Map<dynamic, dynamic>);
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }
    return micros;
  }

  @override
  Future<List<String>> rangeMonthIds(String baseDir) async {
    final firstDay = rangeMonthKey * 100 + 1;
    final lastDay = rangeMonthKey * 100 + 31;
    final sw = Stopwatch()..start();
    // One Dart-side pass collects the month's (id, bookedOn) pairs in
    // contract order; paging by 100 slices that list (Hive has no
    // server-side pagination to model).
    final month = <MapEntry<String, int>>[];
    for (final key in _txns!.keys.cast<String>()) {
      final bookedOn = _txns!.get(key)!['bookedOn']! as int;
      if (bookedOn >= firstDay && bookedOn <= lastDay) {
        month.add(MapEntry(key, bookedOn));
      }
    }
    month.sort((a, b) {
      final byDay = a.value.compareTo(b.value);
      if (byDay != 0) {
        return byDay;
      }
      return a.key.compareTo(b.key);
    });
    final ids = [for (final entry in month) entry.key];
    sw.stop();
    if (ids.isEmpty) {
      throw StateError('range: month $rangeMonthKey matched nothing');
    }
    return ids;
  }

  @override
  Future<(int, Map<String, int>, int)> yearReport(String baseDir) async {
    final sw = Stopwatch()..start();
    final sums = <String, int>{};
    final accounts = <String>{};
    for (final value in _txns!.values) {
      final bookedOn = value['bookedOn']! as int;
      if (bookedOn ~/ 10000 != reportYear) {
        continue;
      }
      final accountId = value['accountId']! as String;
      final month = bookedOn ~/ 100 % 100;
      final key = '$accountId|${reportYear * 100 + month}';
      sums[key] = (sums[key] ?? 0) + (value['amountMinor']! as int);
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
    // The Dart-side top-50 of the pending txns, the contract order.
    final top = <MapEntry<String, Map<dynamic, dynamic>>>[];
    for (final key in _txns!.keys.cast<String>()) {
      final value = _txns!.get(key)!;
      if (value['status'] != m.TxnStatus.pending.name) {
        continue;
      }
      top.add(MapEntry(key, value));
      if (top.length > 400) {
        top.sort((a, b) {
          final byDay = (b.value['bookedOn']! as int).compareTo(
            a.value['bookedOn']! as int,
          );
          if (byDay != 0) {
            return byDay;
          }
          return b.key.compareTo(a.key);
        });
        top.removeRange(200, top.length);
      }
    }
    top.sort((a, b) {
      final byDay = (b.value['bookedOn']! as int).compareTo(
        a.value['bookedOn']! as int,
      );
      if (byDay != 0) {
        return byDay;
      }
      return b.key.compareTo(a.key);
    });
    return [
      for (final entry in top.take(50)) entry.key,
    ];
  }

  @override
  Future<void> writeOneTxn(String accountId, String id, int seq) {
    return _txns!.put(id, {
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
    final box = await _open(baseDir);
    final sw = Stopwatch()..start();
    var restored = 0;
    final file = File(_backupFile ?? backupPath());
    final lines = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    var batch = <String, Map<String, Object?>>{};
    Future<void> flush() async {
      if (batch.isEmpty) {
        return;
      }
      await box.putAll(batch);
      restored += batch.length;
      batch = <String, Map<String, Object?>>{};
    }

    await for (final line in lines) {
      if (line.isEmpty) {
        continue;
      }
      final map = jsonDecode(line) as Map<String, Object?>;
      final id = map.remove('id')! as String;
      batch[id] = map;
      if (batch.length >= restoreBatchSize) {
        await flush();
      }
    }
    await flush();
    sw.stop();
    await box.close();
    _txns = null;
    return (sw.elapsedMilliseconds, restored);
  }

  @override
  Future<void> close() async {
    await _txns?.close();
    _txns = null;
  }
}
