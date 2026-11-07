/// The engine interface both backends implement, plus the measured values
/// every operation reports. One process runs one engine for one operation —
/// memory numbers never leak between engines.
library;

import 'dart:io';

import 'package:cocoon_bench/dataset.dart';

/// One measured operation over one engine at one size.
///
/// The metrics keys are operation-specific; the CLI prints them as JSON.
abstract final class Metrics {
  static const elapsedMs = 'elapsedMs';
  static const fileBytes = 'fileBytes';
  static const openMs = 'openMs';
  static const rssAfterOpenBytes = 'rssAfterOpenBytes';
  static const peakRssBytes = 'peakRssBytes';
  static const p50Us = 'p50Us';
  static const p95Us = 'p95Us';
  static const queries = 'queries';
  static const docsScanned = 'docsScanned';
  static const grandTotalMinor = 'grandTotalMinor';
  static const count = 'count';
  static const found = 'found';
  static const txns = 'txns';
}

/// A storage backend under benchmark: import, cold open, the read shapes of
/// a finance app, and single writes.
abstract interface class BenchEngine {
  /// `cocoon` or `sembast`.
  String get name;

  /// The path of this engine's database file under [baseDir].
  String dbPath(String baseDir);

  /// Deletes the database files, for a fresh import run.
  void wipe(String baseDir);

  /// The size on disk of the database files after close, in bytes.
  int fileSize(String baseDir);

  /// Imports [data] — accounts first, then transactions in batches of 1000
  /// per transaction. Returns the bulk-import wall time in milliseconds.
  Future<int> import(BenchDataset data, String baseDir);

  /// Opens the database and answers one small query. Returns the open wall
  /// time in milliseconds; the process start-to-first-query time the CLI
  /// reports adds the harness overhead measured in `bin/bench.dart`.
  Future<int> coldOpen(BenchDataset data, String baseDir);

  /// The RSS right after opening (before any read), in bytes.
  Future<int> rssAfterOpen(BenchDataset data, String baseDir);

  /// Opens the database for the read/write operations below. Idempotent;
  /// required before [latest50Ids], [latest50Us], [monthlyTotalsMap],
  /// [monthlyTotals], [getsById] and [writeUs].
  Future<void> open(BenchDataset data, String baseDir);

  /// The ids of [accountId]'s 50 latest transactions, newest first.
  Future<List<String>> latest50Ids(String accountId, String baseDir);

  /// The latest-50 query over every [accountIds] entry, timed per query.
  /// Returns the per-query durations in microseconds, in the order asked.
  Future<List<int>> latest50Us(List<String> accountIds, String baseDir);

  /// One account's monthly totals for [year]: pages the account's txns and
  /// sums `amountMinor` per month in Dart. Returns the totals keyed `yyyyMM`
  /// and how many documents were read.
  Future<({Map<int, int> totals, int scanned})> monthlyTotalsMap(
    String accountId,
    int year,
    String baseDir,
  );

  /// One account's monthly totals for [year], as the CLI reports them:
  /// (elapsed ms, docs scanned, grand total minor units).
  Future<(int, int, int)> monthlyTotals(
    String accountId,
    int year,
    String baseDir,
  );

  /// Gets [ids] by id, returning (elapsed ms, hits).
  Future<(int, int)> getsById(
    List<({String accountId, String id})> ids,
    String baseDir,
  );

  /// Writes [txns] one set each, outside any transaction. Returns the
  /// per-write durations in microseconds, in order.
  Future<List<int>> writeUs(
    List<({String accountId, String id, BenchTxn txn})> txns,
    String baseDir,
  );

  /// Releases the database.
  Future<void> close();
}

/// The p50/p95 (percentile by nearest-rank over the sorted list) of
/// [micros], plus how many measurements there were.
({int p50Us, int p95Us, int count}) percentiles(List<int> micros) {
  final sorted = [...micros]..sort();
  int at(double p) {
    final index = ((sorted.length - 1) * p).round();
    return sorted[index];
  }

  return (p50Us: at(0.50), p95Us: at(0.95), count: sorted.length);
}

/// Sum of the byte sizes of [path] and every sibling journal/WAL file.
int fileSizeWithSidecars(String path) {
  var total = 0;
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    if (file.existsSync()) {
      total += file.lengthSync();
    }
  }
  return total;
}
