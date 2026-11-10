/// The step-20 shipped-layout engine measurements over the rivals dataset,
/// with the real Cocoon engine (not raw SQL):
///
/// - 1M bulkWriter() import time on the new layout,
/// - engine get-by-id / latest-50 / single delete p50s,
/// - one account's monthly groupBy (the engine's `bucket` key),
/// - a REAL subtree delete: deleting an account cascades to its ~50k txns,
/// - the storage-format migration time of an existing 1M OLD-format file
///   (a scratch copy of `/tmp/cocoon_rivals_run/cocoon_rivals_cocoon_1000000/
///   cocoon.db`; the original is never opened for writing),
/// - per-object dbstat bytes of the new-layout file.
///
/// Prints one JSON object. Everything is written under a scratch dir and
/// deleted at the end; the rivals originals are only copied, never modified.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/dataset.dart' show BenchDataset;
import 'package:cocoon_rivals/models.dart' show Txn$, accounts, txns;
import 'package:sqlite3/sqlite3.dart' as raw;

const size = 1000000;
const readRuns = 200;
const targetStride = 4999;

Future<void> main() async {
  final scratch = Directory.systemTemp.createTempSync('cocoon_shipped_');
  try {
    stdout.writeln(jsonEncode(await measure(scratch)));
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

Future<Map<String, Object?>> measure(Directory scratch) async {
  final dbPath = '${scratch.path}${Platform.pathSeparator}shipped.db';
  final accountCount = BenchDataset.build(txnCount: 20).accounts.length;

  // -- 1. The 1M bulkWriter() import (timed). -------------------------------
  final db = await Cocoon.open(
    dbPath,
    collections: [accounts, txns],
    options: const CocoonOptions(durability: Durability.full),
  );
  final dataset = BenchDataset.build(txnCount: size);
  // Accounts first, untimed: 20 rows, exactly like the harness's import.
  for (var i = 0; i < dataset.accounts.length; i++) {
    await db
        .collection(accounts)
        .doc('a${i.toString().padLeft(2, '0')}')
        .set(dataset.accounts[i]);
  }
  final importWatch = Stopwatch()..start();
  final bulk = db.bulkWriter();
  var queued = 0;
  for (final benchTxn in dataset.txns) {
    bulk.set(
      db
          .collection(accounts)
          .doc(benchTxn.accountId)
          .collection(txns)
          .doc(benchTxn.id),
      benchTxn.txn,
    );
    if (++queued % 50000 == 0) {
      await bulk.flush();
    }
  }
  await bulk.close();
  importWatch.stop();
  final importMs = importWatch.elapsedMilliseconds;
  final freshFileBytes = File(dbPath).lengthSync();

  // -- 2. Engine read p50s + the monthly groupBy. ---------------------------
  int p50Of(List<int> micros) {
    final sorted = [...micros]..sort();
    return sorted[sorted.length ~/ 2];
  }

  final getMicros = <int>[];
  final latestMicros = <int>[];
  final monthMicros = <int>[];
  for (var r = 0; r < readRuns; r++) {
    final globalIndex = (r * targetStride + size ~/ 4) % size;
    final accountId =
        'a${(globalIndex % accountCount).toString().padLeft(2, '0')}';
    final id = 't${globalIndex.toString().padLeft(9, '0')}';
    final scope = db.collection(accounts).doc(accountId).collection(txns);

    var sw = Stopwatch()..start();
    final snap = await scope.doc(id).get();
    sw.stop();
    if (snap == null) {
      throw StateError('get($id) missed');
    }
    getMicros.add(sw.elapsedMicroseconds);

    sw = Stopwatch()..start();
    final page = await scope
        .orderBy(Txn$.bookedOn, descending: true)
        .limit(50)
        .get();
    sw.stop();
    if (page.docs.length != 50) {
      throw StateError('latest-50 got ${page.docs.length}');
    }
    latestMicros.add(sw.elapsedMicroseconds);

    sw = Stopwatch()..start();
    final groups = await scope
        .groupBy([bucket(Txn$.bookedOn, width: 100)])
        .aggregate([count(), sum(Txn$.amountMinor)])
        .get();
    sw.stop();
    if (groups.isEmpty) {
      throw StateError('monthly groupBy returned no groups');
    }
    monthMicros.add(sw.elapsedMicroseconds);
  }

  // -- 3. Single delete (delete + re-add untimed), like the storage probe. --
  final singleDeleteMicros = <int>[];
  for (var r = 0; r < readRuns; r++) {
    final globalIndex = (r * targetStride + size ~/ 4) % size;
    final accountId =
        'a${(globalIndex % accountCount).toString().padLeft(2, '0')}';
    final id = 't${globalIndex.toString().padLeft(9, '0')}';
    final ref = db.collection(accounts).doc(accountId).collection(txns).doc(id);
    final before = (await ref.get())!;
    final sw = Stopwatch()..start();
    await ref.delete();
    sw.stop();
    await ref.set(before.data);
    singleDeleteMicros.add(sw.elapsedMicroseconds);
  }

  // -- 4. A REAL subtree delete: one account and its ~50k txns. -------------
  // Done last (destructive). Counts the change rows the cascade appends.
  const subtreeAccount = 'a00';
  final subtreeBefore = await db
      .collection(accounts)
      .doc(subtreeAccount)
      .collection(txns)
      .count();
  final seqBefore = await db.lastChangeSeq();
  final subtreeWatch = Stopwatch()..start();
  await db.collection(accounts).doc(subtreeAccount).delete();
  subtreeWatch.stop();
  final subtreeMs = subtreeWatch.elapsedMilliseconds;
  final subtreeChanges = (await db.changesSince(
    seqBefore,
    limit: subtreeBefore + 2,
  )).length;
  final subtreeAfter = await db
      .collection(accounts)
      .doc(subtreeAccount)
      .collection(txns)
      .count();
  if (subtreeAfter != 0 || subtreeChanges != subtreeBefore + 1) {
    throw StateError(
      'subtree delete: $subtreeBefore txns remained as '
      '$subtreeAfter, $subtreeChanges change rows logged',
    );
  }
  await db.close();
  final afterSubtreeFileBytes = File(dbPath).lengthSync();

  // -- 5. dbstat accounting of the closed new-layout file. ------------------
  final objects = dbstatObjects(dbPath);

  // -- 6. The format migration of an existing 1M OLD-format file. -----------
  const oldOriginal =
      '/tmp/cocoon_rivals_run/cocoon_rivals_cocoon_1000000/cocoon.db';
  final oldCopy = '${scratch.path}${Platform.pathSeparator}old_format_1m.db';
  File(oldOriginal).copySync(oldCopy);
  final oldBytes = File(oldCopy).lengthSync();
  final migrationWatch = Stopwatch()..start();
  var progressReports = 0;
  final migrated = await Cocoon.open(
    oldCopy,
    collections: [accounts, txns],
    onMigrationProgress: (done, total) => progressReports++,
  );
  migrationWatch.stop();
  final migrationMs = migrationWatch.elapsedMilliseconds;
  final migratedCount = await migrated
      .collectionGroup(txns)
      .query()
      .allowFullScan()
      .count();
  final migratedLogHead = await migrated.lastChangeSeq();
  await migrated.close();
  // A second open must be a no-op.
  final reopenWatch = Stopwatch()..start();
  final reopened = await Cocoon.open(oldCopy, collections: [accounts, txns]);
  reopenWatch.stop();
  await reopened.close();
  final migratedBytes = File(oldCopy).lengthSync();

  return {
    'size': size,
    'bulkWriterImportMs': importMs,
    'freshFileBytes': freshFileBytes,
    'getP50Us': p50Of(getMicros),
    'latest50P50Us': p50Of(latestMicros),
    'monthlyGroupByP50Us': p50Of(monthMicros),
    'singleDeleteP50Us': p50Of(singleDeleteMicros),
    'subtreeDelete': {
      'account': subtreeAccount,
      'documents': subtreeBefore + 1,
      'changeRows': subtreeChanges,
      'ms': subtreeMs,
    },
    'afterSubtreeFileBytes': afterSubtreeFileBytes,
    'dbstatObjects': objects,
    'formatMigration': {
      'source': oldOriginal,
      'sourceBytes': oldBytes,
      'ms': migrationMs,
      'documents': migratedCount,
      'logHead': migratedLogHead,
      'reopenMs': reopenWatch.elapsedMilliseconds,
      'migratedBytes': migratedBytes,
      'progressReports': progressReports,
    },
  };
}

/// Per-object dbstat accounting of a CLOSED database (indexes count every
/// page's cells; rowid tables count leaf cells only).
List<Object?> dbstatObjects(String path) {
  final ro = raw.sqlite3.open(path, mode: raw.OpenMode.readOnly);
  try {
    final types = <String, String>{
      for (final row in ro.select('SELECT name, type FROM sqlite_master'))
        row['name']! as String: row['type']! as String,
    };
    return [
      for (final row in ro.select('''
            SELECT name, sum(pgsize) AS bytes, sum(ncell) AS entries,
                   sum(CASE WHEN pagetype = 'leaf' THEN ncell ELSE 0 END)
                       AS leaf_entries,
                   sum(payload) AS payload,
                   sum(CASE WHEN pagetype = 'leaf' THEN payload ELSE 0 END)
                       AS leaf_payload
            FROM dbstat GROUP BY name ORDER BY bytes DESC
          '''))
        {
          'name': row['name']! as String,
          'type': types[row['name']! as String] ?? '?',
          'bytes': row['bytes']! as int,
          'entries':
              (types[row['name']!] == 'table'
                      ? row['leaf_entries']
                      : row['entries'])!
                  as int,
          'avgPayloadB': (row['entries']! as int) == 0
              ? null
              : (row['payload']! as int) / (row['entries']! as int),
        },
    ];
  } finally {
    ro.close();
  }
}
