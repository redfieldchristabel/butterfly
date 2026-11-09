/// The op runner behind every `bin/bench.dart --op <name>` case, kept as a
/// library so the smoke test can run the exact CLI path for every engine
/// and assert the cost metrics each op must report.
///
/// Every op fills [runOp]'s metrics map with its own results plus the cost
/// metrics:
///
/// - `peakRssBytes` — the process high-water mark, set once per op (it is a
///   process-wide number, which is why one measurement is one fresh
///   process);
/// - `cpuMs` and `diskWriteBytes` — the `/proc/self/stat` utime+stime and
///   `/proc/self/io` `write_bytes` deltas ([OpCost]) over the op's measured
///   section: the same section the wall-time metrics cover (the harness's
///   open/seed/sample setup stays outside, like the elapsed numbers), with
///   two documented exceptions — `import` brackets the engine's whole
///   import call (its untimed accounts live inside) and `restore` brackets
///   the engine's whole restore call (its internal fresh open does).
///
/// The one exception to the map's completeness: `open` reports the engine's
/// own open time as `engineOpenMs`; the CLI adds the process-start-to-first-
/// query `openMs` on top, because that number starts before `main()` and
/// only the CLI can see it.
library;

import 'dart:io';
import 'dart:math';

import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/engine.dart';

/// The ops `runOp` executes, in the order `tool/run_all.sh` runs them
/// (`bulkimport` runs right after `import`; it wipes and rebuilds its own
/// `${baseDir}_bulk` database, so the read ops keep measuring `import`'s).
const benchOps = [
  'verify',
  'bulkimport',
  'open',
  'rss',
  'latest50',
  'monthly',
  'gets',
  'write',
  'range',
  'yearreport',
  'statussearch',
  'bigspend',
  'amountrange',
  'pendingmonth',
  'deeppage',
  'count',
  'rww',
  'restore',
];

/// The read shapes a finance app runs, used by the `rss` operation.
const rssReadAccounts = 200;
const rssReadGetCount = 1000;

/// How many documents the `gets` operation reads by id.
const getsCount = 1000;

/// How many documents the `write` operation rewrites.
const writeCount = 200;

/// How many latest-50 queries the `rww` operation times.
const rwwQueries = 200;

/// The seed every database-side sample uses, so ids and values are identical
/// in every process over the same database.
const sampleSeed = 424242;

/// Runs one op for one engine against [baseDir], filling [metrics] with the
/// op's results and cost metrics. The read ops require an imported database
/// under [baseDir] (the `import` op builds one; `restore` rebuilds its own
/// `${baseDir}_restore`).
Future<void> runOp({
  required BenchEngine engine,
  required String op,
  required int size,
  required String baseDir,
  required Map<String, Object?> metrics,
  required Random rng,
  required List<String> accountIds,
}) async {
  switch (op) {
    case 'import':
      // The only operation that needs the typed dataset in RAM: it feeds
      // the bulk import. The bracket covers the engine's whole import call
      // (open + the untimed 20 accounts + the timed batches); the wall
      // number stays the engine's own elapsed, as before.
      final data = BenchDataset.build(txnCount: size);
      engine.wipe(baseDir);
      Directory(baseDir).createSync(recursive: true);
      final cost = OpCost.start();
      final elapsed = await engine.import(data, baseDir);
      final (:cpuMs, :diskWriteBytes) = cost.stop();
      final fileBytes = engine.fileSize(baseDir);
      metrics
        ..[Metrics.elapsedMs] = elapsed
        ..[Metrics.fileBytes] = fileBytes
        ..[Metrics.txns] = data.txns.length
        ..[Metrics.cpuMs] = cpuMs;
      if (diskWriteBytes != null) {
        metrics[Metrics.diskWriteBytes] = diskWriteBytes;
        // Write amplification: storage-layer bytes per byte of database.
        if (diskWriteBytes > 0) {
          metrics[Metrics.writeAmplification] = diskWriteBytes / fileBytes;
        }
      }

    case 'bulkimport':
      // The same dataset through each engine's best documented bulk API,
      // into a wiped database under its own directory — the read ops keep
      // measuring the 1000-per-commit `import` database. Like `import`, the
      // bracket covers the engine's whole call.
      final data = BenchDataset.build(txnCount: size);
      final bulkDir = '${baseDir}_bulk';
      engine.wipe(bulkDir);
      Directory(bulkDir).createSync(recursive: true);
      final cost = OpCost.start();
      final elapsed = await engine.bulkimport(data, bulkDir);
      final (:cpuMs, :diskWriteBytes) = cost.stop();
      metrics
        ..[Metrics.elapsedMs] = elapsed
        ..[Metrics.fileBytes] = engine.fileSize(bulkDir)
        ..[Metrics.txns] = data.txns.length
        ..[Metrics.cpuMs] = cpuMs;
      if (diskWriteBytes != null) {
        metrics[Metrics.diskWriteBytes] = diskWriteBytes;
      }

    case 'open':
      final cost = OpCost.start();
      final engineOpenMs = await engine.coldOpen(
        baseDir,
        accountId: accountIds.first,
      );
      final (:cpuMs, :diskWriteBytes) = cost.stop();
      metrics['engineOpenMs'] = engineOpenMs;
      metrics[Metrics.cpuMs] = cpuMs;
      if (diskWriteBytes != null) {
        metrics[Metrics.diskWriteBytes] = diskWriteBytes;
      }

    case 'rss':
      await engine.open(baseDir);
      metrics[Metrics.rssAfterOpenBytes] = await engine.rssAfterOpen(baseDir);
      // The read shapes below, then the steady state and the process peak.
      await _measured(metrics, () async {
        await engine.latest50Us([
          for (var i = 0; i < rssReadAccounts; i++)
            'a${rng.nextInt(20).toString().padLeft(2, '0')}',
        ], baseDir);
        await engine.monthlyTotals('a05', 2024, baseDir);
        await engine.getsById(
          _idsOf(await _sample(engine, baseDir, rssReadGetCount)),
          baseDir,
        );
      });
      metrics[Metrics.rssAfterReadsBytes] = ProcessInfo.currentRss;

    case 'latest50':
      await engine.open(baseDir);
      final micros = (await _measured(
        metrics,
        () => engine.latest50Us([
          for (var i = 0; i < 200; i++)
            'a${rng.nextInt(20).toString().padLeft(2, '0')}',
        ], baseDir),
      )).$1;
      final p = percentiles(micros);
      metrics
        ..[Metrics.p50Us] = p.p50Us
        ..[Metrics.p95Us] = p.p95Us
        ..[Metrics.queries] = p.count;

    case 'monthly':
      await engine.open(baseDir);
      final ((engineElapsed, scanned, grandTotal), _) = await _measured(
        metrics,
        () => engine.monthlyTotals('a05', 2024, baseDir),
      );
      // The engine's own elapsed is the wall number (the same section the
      // bracket covers, without the hop in between).
      metrics
        ..[Metrics.elapsedMs] = engineElapsed
        ..[Metrics.docsScanned] = scanned
        ..[Metrics.grandTotalMinor] = grandTotal;

    case 'gets':
      await engine.open(baseDir);
      final ids = _idsOf(await _sample(engine, baseDir, getsCount));
      final ((engineElapsed, hits), _) = await _measured(
        metrics,
        () => engine.getsById(ids, baseDir),
      );
      _expectAllFound(hits, ids.length, op);
      metrics
        ..[Metrics.elapsedMs] = engineElapsed
        ..[Metrics.count] = ids.length
        ..[Metrics.found] = hits;

    case 'write':
      await engine.open(baseDir);
      final docs = await _sample(engine, baseDir, writeCount);
      final micros = (await _measured(
        metrics,
        () => engine.writeUs(docs, baseDir),
      )).$1;
      final p = percentiles(micros);
      metrics
        ..[Metrics.p50Us] = p.p50Us
        ..[Metrics.p95Us] = p.p95Us
        ..[Metrics.queries] = p.count;

    case 'range':
      await engine.open(baseDir);
      final (ids, elapsed) = await _measured(
        metrics,
        () => engine.rangeMonthIds(baseDir),
      );
      metrics
        ..[Metrics.elapsedMs] = elapsed
        ..[Metrics.count] = ids.length
        ..[Metrics.pages] = (ids.length + rangePageSize - 1) ~/ rangePageSize;

    case 'verify':
      // The contract dump the at-scale correctness checks diff across
      // engines: every read shape's full output, no timing.
      await engine.open(baseDir);
      await _measured(metrics, () async {
        final latest = <String, List<String>>{};
        for (final account in ['a00', 'a07', 'a13', 'a19']) {
          latest[account] = await engine.latest50Ids(account, baseDir);
        }
        final (:totals, scanned: scanned) = await engine.monthlyTotalsMap(
          'a05',
          2024,
          baseDir,
        );
        final (yearMs, sums, accountsCovered) = await engine.yearReport(
          baseDir,
        );
        final rangeIds = await engine.rangeMonthIds(baseDir);
        final statusIds = await engine.statusSearchIds(baseDir);
        final bigspendIds = await engine.bigspendIds(baseDir);
        final amountRangeIds = await engine.amountRangeIds(baseDir);
        final pendingMonthIds = await engine.pendingMonthIds(baseDir);
        final pendingCount = (await engine.pendingCountUs(baseDir)).count;
        final yearCount = (await engine.yearCountUs('a05', baseDir)).count;
        final deepPage = <String, List<String>>{};
        for (final account in ['a02', 'a17']) {
          deepPage[account] = [
            for (final page in (await engine.deeppagePages(
              account,
              baseDir,
            )).pageIds)
              ...page,
          ];
        }
        metrics
          ..['latest50'] = latest
          ..['monthly'] = {
            // JSON object keys are strings; the totals are keyed `yyyyMM`.
            for (final entry in totals.entries) '${entry.key}': entry.value,
          }
          ..['monthlyScanned'] = scanned
          ..['yearreport'] = sums
          ..['yearreportAccounts'] = accountsCovered
          ..['yearreportMs'] = yearMs
          ..['range'] = rangeIds
          ..['status'] = statusIds
          ..['bigspend'] = bigspendIds
          ..['amountrange'] = amountRangeIds
          ..['pendingmonth'] = pendingMonthIds
          ..['count'] = {'pending': pendingCount, 'year': yearCount}
          ..['deeppage'] = deepPage;
      });

    case 'yearreport':
      await engine.open(baseDir);
      final ((engineElapsed, sums, accountsCovered), _) = await _measured(
        metrics,
        () => engine.yearReport(baseDir),
      );
      var grandTotal = 0;
      for (final value in sums.values) {
        grandTotal += value;
      }
      metrics
        ..[Metrics.elapsedMs] = engineElapsed
        ..[Metrics.grandTotalMinor] = grandTotal
        ..[Metrics.accounts] = accountsCovered
        ..['months'] = sums.length;

    case 'statussearch':
      await engine.open(baseDir);
      final micros = (await _measured(
        metrics,
        () => engine.statusSearchUs(baseDir),
      )).$1;
      final p = percentiles(micros);
      metrics
        ..[Metrics.p50Us] = p.p50Us
        ..[Metrics.p95Us] = p.p95Us
        ..[Metrics.queries] = p.count;

    case 'bigspend':
      await engine.open(baseDir);
      final micros = (await _measured(
        metrics,
        () => engine.bigspendUs(baseDir),
      )).$1;
      final p = percentiles(micros);
      metrics
        ..[Metrics.p50Us] = p.p50Us
        ..[Metrics.p95Us] = p.p95Us
        ..[Metrics.queries] = p.count;

    case 'amountrange':
      await engine.open(baseDir);
      final (ids, elapsed) = await _measured(
        metrics,
        () => engine.amountRangeIds(baseDir),
      );
      metrics
        ..[Metrics.elapsedMs] = elapsed
        ..[Metrics.count] = ids.length
        ..[Metrics.pages] =
            (ids.length + amountRangePageSize - 1) ~/ amountRangePageSize;

    case 'pendingmonth':
      await engine.open(baseDir);
      final (ids, elapsed) = await _measured(
        metrics,
        () => engine.pendingMonthIds(baseDir),
      );
      metrics
        ..[Metrics.elapsedMs] = elapsed
        ..[Metrics.count] = ids.length
        ..[Metrics.pages] = (ids.length + rangePageSize - 1) ~/ rangePageSize;

    case 'deeppage':
      await engine.open(baseDir);
      final accounts = [
        for (var i = 0; i < deeppageAccounts; i++)
          'a${i.toString().padLeft(2, '0')}',
      ];
      final pageUsAll = <int>[];
      final page20Us = <int>[];
      var pages = 0;
      final (_, walkMs) = await _measured(metrics, () async {
        for (final account in accounts) {
          final (:pageIds, :pageUs) = await engine.deeppagePages(
            account,
            baseDir,
          );
          pageUsAll.addAll(pageUs);
          pages += pageIds.length;
          if (pageIds.length >= deeppagePageCount) {
            page20Us.add(pageUs[deeppagePageCount - 1]);
          }
        }
      });
      final p = percentiles(pageUsAll);
      metrics
        ..[Metrics.p50Us] = p.p50Us
        ..[Metrics.p95Us] = p.p95Us
        ..[Metrics.queries] = pages
        ..[Metrics.accounts] = accounts.length
        // The whole walk (every account, every page), as the app pays it.
        ..[Metrics.elapsedMs] = walkMs;
      // The page-20 duration, median over the accounts that walked that
      // deep; the key stays unset when no account has 20 pages.
      if (page20Us.isNotEmpty) {
        metrics[Metrics.page20Us] = percentiles(page20Us).p50Us;
      }

    case 'count':
      await engine.open(baseDir);
      // Both shapes inside one bracket: the op reports the two counts' cost
      // together, per-shape percentiles.
      final cost = OpCost.start();
      final pending = await engine.pendingCountUs(baseDir);
      final year = await engine.yearCountUs('a05', baseDir);
      final (:cpuMs, :diskWriteBytes) = cost.stop();
      final pendingP = percentiles(pending.us);
      final yearP = percentiles(year.us);
      metrics[Metrics.cpuMs] = cpuMs;
      if (diskWriteBytes != null) {
        metrics[Metrics.diskWriteBytes] = diskWriteBytes;
      }
      metrics
        ..[Metrics.pendingP50Us] = pendingP.p50Us
        ..[Metrics.pendingP95Us] = pendingP.p95Us
        ..[Metrics.yearP50Us] = yearP.p50Us
        ..[Metrics.yearP95Us] = yearP.p95Us
        ..[Metrics.pendingCount] = pending.count
        ..[Metrics.yearCount] = year.count;

    case 'rww':
      await engine.open(baseDir);
      // The writer: one new txn every [rwwIntervalMs] ms (wall clock),
      // counted; the reads run in parallel on the same event loop.
      var writes = 0;
      var writerDone = false;
      final clock = Stopwatch()..start();
      Future<void> writer() async {
        var seq = 0;
        while (!writerDone) {
          final tick = clock.elapsedMilliseconds;
          await engine.writeOneTxn(
            'a00',
            'w${seq.toString().padLeft(9, '0')}',
            seq,
          );
          writes++;
          seq++;
          final spent = clock.elapsedMilliseconds - tick;
          if (spent < rwwIntervalMs) {
            await Future<void>.delayed(
              Duration(milliseconds: rwwIntervalMs - spent),
            );
          }
        }
      }

      final writerFuture = writer();
      final micros = (await _measured(
        metrics,
        () => engine.latest50Us([
          for (var i = 0; i < rwwQueries; i++)
            'a${rng.nextInt(20).toString().padLeft(2, '0')}',
        ], baseDir),
      )).$1;
      writerDone = true;
      await writerFuture;
      final p = percentiles(micros);
      metrics
        ..[Metrics.p50Us] = p.p50Us
        ..[Metrics.p95Us] = p.p95Us
        ..[Metrics.queries] = p.count
        ..[Metrics.writes] = writes
        ..['intervalMs'] = rwwIntervalMs;

    case 'restore':
      // Untimed setup: the shared NDJSON backup, built once if missing.
      await ensureNdjsonBackup();
      // Restore wipes and rebuilds its own directory: the imported
      // database the read ops measure against stays untouched. The bracket
      // covers the engine's whole restore call (its internal wipe + fresh
      // open included); the wall number stays the engine's own elapsed.
      // The CLI checks the restored count against the shared backup's size;
      // tests with their own smaller backups just read `txns`.
      final restoreDir = '${baseDir}_restore';
      final ((engineElapsed, restored), _) = await _measured(
        metrics,
        () => engine.restore(restoreDir),
      );
      metrics
        ..[Metrics.elapsedMs] = engineElapsed
        ..[Metrics.txns] = restored
        ..[Metrics.fileBytes] = engine.fileSize(restoreDir);

    default:
      throw ArgumentError.value(op, 'op', 'Unknown op');
  }
  metrics[Metrics.peakRssBytes] = ProcessInfo.maxRss;
}

/// Brackets [body] with an [OpCost] and a wall stopwatch: returns the body's
/// value and its elapsed ms, and records cpuMs (+ diskWriteBytes where the
/// kernel has io accounting) into [metrics].
Future<(T, int)> _measured<T>(
  Map<String, Object?> metrics,
  Future<T> Function() body,
) async {
  final cost = OpCost.start();
  final sw = Stopwatch()..start();
  final value = await body();
  sw.stop();
  final (:cpuMs, :diskWriteBytes) = cost.stop();
  metrics[Metrics.cpuMs] = cpuMs;
  if (diskWriteBytes != null) {
    metrics[Metrics.diskWriteBytes] = diskWriteBytes;
  }
  return (value, sw.elapsedMilliseconds);
}

/// Samples [count] documents from the database itself, untimed: the ids and
/// values every non-import operation needs, without the typed dataset.
Future<List<SampledDoc>> _sample(
  BenchEngine engine,
  String baseDir,
  int count,
) => engine.sampleDocs(baseDir, count, Random(sampleSeed));

/// The (accountId, id) pairs of a sample, for the get-by-id reads.
List<({String accountId, String id})> _idsOf(List<SampledDoc> docs) => [
  for (final doc in docs) (accountId: doc.accountId, id: doc.id),
];

void _expectAllFound(int hits, int count, String op) {
  if (hits != count) {
    throw StateError('$op: found only $hits of $count documents');
  }
}
