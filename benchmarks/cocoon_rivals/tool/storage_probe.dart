/// Where the bytes go: layout variants of Cocoon's real `txn` table (dev
/// tool, not shipped) — the measurements behind `STORAGE.md`.
///
/// Same approach as `tool/ceiling_probe.dart`: the exact DDL Cocoon creates
/// is read from a small engine-built `cocoon.db` (`readRealSchema`, reused),
/// the rows come from that probe's `chunkRows` (blobs of the real encoded
/// size, the dataset's value shape), every variant is a fresh database in
/// its own process, and the writer runs at Cocoon's pragmas with
/// `synchronous = FULL`. Secondary indexes are built AFTER the load in
/// every variant (Cocoon's measured bulk path), so the layouts are compared
/// at their best rather than through index-maintenance noise; the scope
/// index / primary key stays live because it is the write path's conflict
/// target.
///
/// Variants:
///
/// - `L0` Cocoon's real DDL as-is: `path TEXT UNIQUE`, the scope index and
///   one change-log row per document — today's layout;
/// - `L1` L0 without change-log rows (prices the change log alone);
/// - `L2` L0 without the `path` column and its UNIQUE index; the scope
///   index `(p_account_id, id)` is the only unique key;
/// - `L3` L2 as a `WITHOUT ROWID` table with `PRIMARY KEY (p_account_id,
///   id)` — the scope index becomes the table, and secondary indexes carry
///   the key instead of a rowid;
/// - `L4` L2 and L1 together;
/// - `L5` drift's own layout for the same data (DDL read from the real 1M
///   `drift.db`), as the reference. Its rows are generated with the same
///   distributions, seeding and dataset order as `chunkRows`, mapped onto
///   drift's columns (labels/splits/meta as JSON text, like
///   `drift_models.dart`).
///
/// Reads (p50 over 200 runs on a warm process, statement time only — a
/// commit adds the same fsync to every layout):
///
/// - **get** one document by its full identity: `path = ?` for L0/L1,
///   `p_account_id = ? AND id = ?` for L2-L4, the drift primary key for L5;
/// - **latest-50** of one account by `bookedOn DESC`, served by the
///   `(p_account_id, f_booked_on DESC, id DESC)` index (drift's
///   `(account_id, booked_on DESC)`);
/// - **delete** one document with its subtree, expressed the way the layout
///   allows: a path range `path >= p AND path < p0` for L0/L1 — exactly the
///   half-open descendants range the engine's cascade delete scans — and
///   `p_account_id = ? AND id = ?` for L2-L4, the drift primary key for L5.
///   The `txn` table is flat (no child collections), so the subtree is the
///   row itself; the change-log row a real delete appends is left out so
///   the layouts compare on the delete alone. The row is captured before
///   the delete and re-inserted untimed, so the tree shape stays put across
///   the 200 runs.
///
/// usage:
/// ```sh
/// dart run tool/storage_probe.dart [--size 1000000] [--runs 3]
/// dart run tool/storage_probe.dart --variant L0 --run 1 --out r.json
/// dart run tool/storage_probe.dart --collect <dir-of-run-jsons>
/// ```
///
/// The single-variant mode prints one JSON line (peak RSS is a process
/// high-water mark, so one measurement is one process); `--collect` reads
/// the run files and prints the markdown tables.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cocoon_rivals/engine.dart' show importBatchSize;
import 'package:sqlite3/sqlite3.dart' as raw;

import 'ceiling_probe.dart' show RealSchema, chunkRows, readRealSchema;

/// The real 1M drift database (read-only source of L5's DDL).
const defaultRealDriftDb =
    '/tmp/cocoon_rivals_run/cocoon_rivals_drift_1000000/drift.db';

/// How many documents the read benchmarks walk (p50 over this many runs).
const readRuns = 200;

/// The id stride of the read targets: coprime to 20, so the 200 targets
/// rotate through every account.
const targetStride = 4999;

/// Whether a variant writes change-log rows, is a `WITHOUT ROWID` table, or
/// uses drift's layout entirely. Since step 20's shipped layout every Cocoon
/// variant identifies rows by the scope key (`p_account_id`, `id`) — the
/// stored `path` column of the pre-step-20 layouts no longer exists.
final class LayoutVariant {
  const LayoutVariant({
    required this.name,
    required this.description,
    this.changeRows = true,
    this.withoutRowid = false,
    this.driftLayout = false,
  });

  /// Short name (`L0`..`L3`).
  final String name;

  /// One-line description for the summary table.
  final String description;

  /// One change-log row per written document.
  final bool changeRows;

  /// The table is `WITHOUT ROWID` with `PRIMARY KEY (p_account_id, id)`.
  final bool withoutRowid;

  /// The whole layout is drift's (`txn_rows`), read from the real db.
  final bool driftLayout;
}

/// The variants, in run order.
const variants = [
  LayoutVariant(
    name: 'L0',
    description:
        'shipped layout: scope-key identity + change log per doc (no path column)',
  ),
  LayoutVariant(
    name: 'L1',
    description: 'L0 without change-log rows (the pruning ceiling)',
    changeRows: false,
  ),
  LayoutVariant(
    name: 'L2',
    description: 'L0 as WITHOUT ROWID, PRIMARY KEY (p_account_id, id)',
    withoutRowid: true,
  ),
  LayoutVariant(
    name: 'L3',
    description: "drift's layout for the same data (reference)",
    driftLayout: true,
  ),
];

/// L5's source schema, read from the real drift database.
final class DriftSchema {
  DriftSchema({
    required this.tableSql,
    required this.secondaryIndexSqls,
    required this.columnNames,
  });

  /// The `CREATE TABLE "txn_rows" ...` statement.
  final String tableSql;

  /// The four declared index statements, in creation order.
  final List<String> secondaryIndexSqls;

  /// The table's columns in declared order.
  final List<String> columnNames;
}

/// Reads L5's DDL from [path], read-only.
DriftSchema readDriftSchema(String path) {
  final db = raw.sqlite3.open(path, mode: raw.OpenMode.readOnly);
  try {
    final tableRows = db.select(
      "SELECT name, sql FROM sqlite_master "
      "WHERE type = 'table' AND name = 'txn_rows'",
    );
    if (tableRows.isEmpty) {
      throw StateError('real drift db $path: no txn_rows table');
    }
    final indexSqls = [
      for (final row in db.select(
        "SELECT sql FROM sqlite_master "
        "WHERE type = 'index' AND sql IS NOT NULL AND tbl_name = 'txn_rows'",
      ))
        row['sql']! as String,
    ];
    final columns = [
      for (final row in db.select('PRAGMA table_info("txn_rows")'))
        row['name']! as String,
    ];
    return DriftSchema(
      tableSql: tableRows.first['sql']! as String,
      secondaryIndexSqls: indexSqls,
      columnNames: columns,
    );
  } finally {
    db.close();
  }
}

/// The upsert/insert statement over [columns]: `ON CONFLICT(target)` where
/// the layout has a unique key to target, `INSERT OR REPLACE` where the key
/// IS the table (drift's `id` primary key).
String insertSql(
  String table,
  List<String> columns, {
  String? conflictTarget,
  bool orReplace = false,
}) {
  final placeholders = List.filled(columns.length, '?').join(', ');
  if (orReplace) {
    return 'INSERT OR REPLACE INTO $table (${columns.join(', ')}) '
        'VALUES ($placeholders)';
  }
  if (conflictTarget != null) {
    final updates = [
      for (final column in columns.skip(1)) '$column = excluded.$column',
    ].join(', ');
    return 'INSERT INTO $table (${columns.join(', ')}) '
        'VALUES ($placeholders) '
        'ON CONFLICT($conflictTarget) DO UPDATE SET $updates';
  }
  return 'INSERT INTO $table (${columns.join(', ')}) '
      'VALUES ($placeholders)';
}

/// The variant's `CREATE TABLE` statement and its insert/bind column list.
///
/// The real schema IS the shipped layout; L2's `WITHOUT ROWID` adds the
/// table-level primary key.
(String, List<String>) variantDdl(
  LayoutVariant variant,
  RealSchema schema,
  DriftSchema? drift,
) {
  if (variant.driftLayout) {
    return (drift!.tableSql, drift.columnNames);
  }
  if (!variant.withoutRowid) {
    return (schema.tableSql, schema.columnNames);
  }
  // The stored DDL is one column definition per line between the opening
  // paren and the closing '\n)'.
  final openParen = schema.tableSql.indexOf('(');
  final bodyStart = schema.tableSql.indexOf('\n  ', openParen) + 3;
  final bodyEnd = schema.tableSql.lastIndexOf('\n)');
  if (openParen < 0 ||
      !schema.tableSql.startsWith('CREATE TABLE', 0) ||
      bodyEnd < bodyStart) {
    throw StateError(
      'real table DDL is not in the expected one-line-per-column form',
    );
  }
  final header = schema.tableSql.substring(0, bodyStart);
  final lines = schema.tableSql
      .substring(bodyStart, bodyEnd)
      .split(',\n  ')
      .toList();
  lines.add('PRIMARY KEY (p_account_id, id)');
  return ('$header${lines.join(',\n  ')}\n) WITHOUT ROWID', schema.columnNames);
}

/// The writer connection at Cocoon's pragmas (the ceiling probe's set).
raw.Database openWriter(String path) {
  final db = raw.sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('PRAGMA synchronous = FULL');
  db.execute('PRAGMA cache_size = -65536');
  db.execute('PRAGMA temp_store = MEMORY');
  db.execute('PRAGMA wal_autocheckpoint = 8000');
  db.execute('PRAGMA journal_size_limit = 4194304');
  return db;
}

/// One read target: the r-th document, derived from [size] so every variant
/// and run walks the same documents.
({String path, String id, String accountId}) targetFor(int index, int size) {
  final globalIndex = index % size;
  final accountId = globalIndex % 20;
  final id = 't${globalIndex.toString().padLeft(9, '0')}';
  return (
    path: 'accounts/a${accountId.toString().padLeft(2, '0')}/txns/$id',
    id: id,
    accountId: 'a${accountId.toString().padLeft(2, '0')}',
  );
}

/// The identity lookup arguments of [t] under [variant]: the scope/PK key
/// for the Cocoon layouts, the drift id for L3.
List<Object?> keyArgs(
  LayoutVariant variant,
  ({String path, String id, String accountId}) t,
) => variant.driftLayout ? [t.id] : [t.accountId, t.id];

/// One chunk of drift-shaped rows: the same distributions, seeding and
/// dataset order as `chunkRows` in `ceiling_probe.dart`, but the fields
/// drift stores as columns (labels/splits/meta as JSON text, like
/// `drift_models.dart`).
List<List<Object?>> chunkDriftRows({
  required int index,
  required int count,
  required int seed,
}) {
  const currencies = ['MYR', 'SGD', 'USD', 'EUR'];
  const labelPool = ['groceries', 'rent', 'fuel', 'fees', 'salary', 'gift'];
  const splitLabels = ['food', 'transport', 'utilities', 'fees'];
  final rng = Random(seed * 1000003 + index);
  final rows = <List<Object?>>[];
  for (var i = 0; i < count; i++) {
    final globalIndex = index * importBatchSize + i;
    final accountId = 'a${(globalIndex % 20).toString().padLeft(2, '0')}';
    final year = 2022 + rng.nextInt(5);
    final month = 1 + rng.nextInt(12);
    final day = 1 + rng.nextInt(28);
    final negative = rng.nextInt(10) < 4;
    final magnitude = 100 + rng.nextInt(990000);
    final status = switch (rng.nextInt(100)) {
      < 85 => 'posted',
      < 95 => 'pending',
      _ => 'failed',
    };
    final currency = currencies[rng.nextInt(currencies.length)];
    final memo = rng.nextInt(10) < 6 ? 'memo-${rng.nextInt(100000)}' : null;
    final labelCount = rng.nextInt(4);
    final labels = [
      for (var l = 0; l < labelCount; l++)
        labelPool[rng.nextInt(labelPool.length)],
    ];
    final splitCount = rng.nextInt(4);
    var unassigned = magnitude;
    final splits = [
      for (var s = 0; s < splitCount; s++)
        {
          'label': splitLabels[rng.nextInt(splitLabels.length)],
          'shareMinor': () {
            final share = s == splitCount - 1
                ? unassigned
                : unassigned ~/ (2 + s);
            unassigned -= share;
            return share;
          }(),
        },
    ];
    final metaCount = rng.nextInt(5);
    final meta = <String, String>{
      for (var m = 0; m < metaCount; m++)
        'k${rng.nextInt(8)}': 'v${rng.nextInt(1000000)}',
    };
    rows.add([
      't${globalIndex.toString().padLeft(9, '0')}',
      accountId,
      year * 10000 + month * 100 + day,
      negative ? -magnitude : magnitude,
      currency,
      status,
      memo,
      jsonEncode(labels),
      jsonEncode(splits),
      jsonEncode(meta),
    ]);
  }
  return rows;
}

/// One measurement: a fresh db filled per [variant], closed, snapshotted,
/// then the three read benchmarks. All temp files live under [dir].
Future<Map<String, Object?>> measure({
  required LayoutVariant variant,
  required int size,
  required int run,
  required int ddlSize,
  required Directory dir,
  required String realDriftDb,
}) async {
  // 1. The real Cocoon schema and average row-blob size (untimed).
  final schema = await readRealSchema('${dir.path}/real', ddlSize);
  final drift = variant.driftLayout ? readDriftSchema(realDriftDb) : null;
  final (tableSql, insertColumns) = variantDdl(variant, schema, drift);
  final table = variant.driftLayout ? 'txn_rows' : 'txn';
  final fillSql = variant.driftLayout
      ? insertSql(table, insertColumns, orReplace: true)
      : insertSql(table, insertColumns, conflictTarget: 'p_account_id, id');

  // 2. The load: per-1000-row transactions, deferred secondaries.
  final path = '${dir.path}/${variant.name}_$run.db';
  raw.Database? db;
  try {
    db = openWriter(path);
    db.execute(tableSql);
    if (!variant.driftLayout) {
      // The engine's schema always carries the change log; only the rows
      // are a variant's choice. The scope index is the write path's
      // conflict target, so it stays live like the engine's.
      db.execute(schema.changesSql);
      if (!variant.withoutRowid) {
        db.execute(schema.scopeIndexSql);
      }
    }

    final insert = db.prepare(fillSql);
    // The change log always stores the full document path — the one column
    // L2/L3/L4 drop from the table is still the log's key (it is what a
    // watcher matches and what a sync outbox sends).
    final changeRow = variant.changeRows && !variant.driftLayout
        ? db.prepare(
            "INSERT INTO ${schema.changesTableName} (tbl, path, op, at) "
            "VALUES ('txn', ?, 'set', ?)",
          )
        : null;

    final swLoad = Stopwatch()..start();
    var chunkIndex = 0;
    for (var start = 0; start < size; start += importBatchSize) {
      final count = min(importBatchSize, size - start);
      final rows = variant.driftLayout
          ? chunkDriftRows(index: chunkIndex, count: count, seed: 42 + run)
          : chunkRows(
              index: chunkIndex,
              count: count,
              avgDataBytes: schema.avgDataBytes,
              seed: 42 + run,
              pathOrder: false,
              size: size,
            );
      chunkIndex++;
      db.execute('BEGIN IMMEDIATE');
      final at = DateTime.now().toUtc().microsecondsSinceEpoch;
      for (final row in rows) {
        // chunkRows leads with the path; the scope-key layouts bind the rest.
        insert.execute(row.sublist(1));
        changeRow?.execute([row[0], at]);
      }
      db.execute('COMMIT');
    }
    swLoad.stop();
    final loadMs = swLoad.elapsedMilliseconds;

    // 3. Deferred secondary indexes (timed), then statements closed BEFORE
    // the close-time checkpoint (an open statement holds a WAL read mark).
    var indexMs = 0;
    for (final indexSql
        in variant.driftLayout
            ? drift!.secondaryIndexSqls
            : schema.secondaryIndexSqls) {
      final swIndex = Stopwatch()..start();
      db.execute(indexSql);
      indexMs += swIndex.elapsedMilliseconds;
    }
    insert.close();
    changeRow?.close();
    db.close();
    db = null;

    // 4. Snapshot: file, pages, freelist, per-object dbstat accounting.
    final snapshot = snapshotDb(path, table);

    // 5. The read benchmarks on a warm process.
    final reads = runReads(
      path: path,
      variant: variant,
      size: size,
      table: table,
      insertColumns: insertColumns,
      fillSql: fillSql,
    );

    return {
      'variant': variant.name,
      'run': run,
      'size': size,
      'loadMs': loadMs,
      'indexMs': indexMs,
      'fileBytes': snapshot.fileBytes,
      'pageCount': snapshot.pageCount,
      'freelistPages': snapshot.freelistPages,
      'objects': snapshot.objects,
      'sanity': {
        ...snapshot.sanity,
        'avgRowPayloadB': snapshot.avgRowPayload,
        'getP50Us': reads.getUs,
        'latest50P50Us': reads.latest50Us,
        'monthlyGroupByP50Us': reads.monthUs,
        'deleteP50Us': reads.deleteUs,
      },
      'getUs': reads.getUs,
      'latest50Us': reads.latest50Us,
      'monthlyGroupByUs': reads.monthUs,
      'deleteUs': reads.deleteUs,
    };
  } finally {
    // Non-null only when the happy path didn't get to close it.
    db?.close();
  }
}

/// File, page, freelist and per-object dbstat accounting of a closed
/// database: tables count their rows over leaf cells (interior cells are
/// rowid-only), indexes over all cells (interior cells carry real entries).
({
  int fileBytes,
  int pageCount,
  int freelistPages,
  List<Object?> objects,
  double avgRowPayload,
  Map<String, Object?> sanity,
})
snapshotDb(String path, String table) {
  final bytes = File(path).lengthSync();
  final ro = raw.sqlite3.open(path, mode: raw.OpenMode.readOnly);
  try {
    final pageCount =
        ro.select('PRAGMA page_count').first['page_count']! as int;
    final freelist =
        ro.select('PRAGMA freelist_count').first['freelist_count']! as int;
    final pageSize = ro.select('PRAGMA page_size').first['page_size']! as int;
    final types = <String, String>{
      for (final row in ro.select('SELECT name, type FROM sqlite_master'))
        row['name']! as String: row['type']! as String,
    };
    final objects = <Object?>[];
    double tablePayload = 0;
    for (final row in ro.select('''
          SELECT name, sum(pgsize) AS bytes, sum(ncell) AS entries,
                 sum(CASE WHEN pagetype = 'leaf' THEN ncell ELSE 0 END)
                     AS leaf_entries,
                 sum(payload) AS payload,
                 sum(CASE WHEN pagetype = 'leaf' THEN payload ELSE 0 END)
                     AS leaf_payload
          FROM dbstat GROUP BY name ORDER BY bytes DESC
        ''')) {
      final name = row['name']! as String;
      final type = types[name] ?? '?';
      final isTable = type == 'table';
      final entries = (isTable ? row['leaf_entries'] : row['entries'])! as int;
      final payload = (isTable ? row['leaf_payload'] : row['payload'])! as int;
      if (name == table) {
        tablePayload = entries == 0 ? 0 : payload / entries;
      }
      objects.add({
        'name': name,
        'type': type,
        'bytes': row['bytes']! as int,
        'entries': entries,
        'avgPayloadB': entries == 0 ? null : payload / entries,
      });
    }
    return (
      fileBytes: bytes,
      pageCount: pageCount,
      freelistPages: freelist,
      objects: objects,
      avgRowPayload: tablePayload,
      sanity: {
        'pageSize': pageSize,
        'pageSumMatchesFile': (pageCount * pageSize) == bytes,
      },
    );
  } finally {
    ro.close();
  }
}

/// The three read benchmarks: p50 statement time over [readRuns] warm runs
/// each. Deletes run inside a transaction and are undone untimed, so the
/// timing is the b-tree work, not the commit's fsync. Closes its
/// statements; the caller closes the connection.
({int getUs, int latest50Us, int monthUs, int deleteUs}) runReads({
  required String path,
  required LayoutVariant variant,
  required int size,
  required String table,
  required List<String> insertColumns,
  required String fillSql,
}) {
  final db = openWriter(path);
  try {
    final targets = [
      for (var r = 0; r < readRuns; r++)
        targetFor(r * targetStride + size ~/ 4, size),
    ];
    final getStmt = db.prepare(
      variant.driftLayout
          ? 'SELECT * FROM "$table" WHERE id = ?'
          : 'SELECT * FROM "$table" WHERE p_account_id = ? AND id = ?',
    );
    final latestStmt = db.prepare(
      variant.driftLayout
          ? 'SELECT * FROM "$table" WHERE account_id = ? '
                'ORDER BY booked_on DESC LIMIT 50'
          : 'SELECT * FROM "$table" WHERE p_account_id = ? '
                'ORDER BY f_booked_on DESC, id DESC LIMIT 50',
    );
    // One account's monthly report, expressed the way the engine's
    // `bucket(field, width: 100)` emits it (exact integer arithmetic, no
    // floats): yyyymmdd -> yyyymm00, count and sum per month.
    final monthStmt = db.prepare(
      variant.driftLayout
          ? 'SELECT (booked_on - ((booked_on % 100) + 100) % 100) AS k, '
                'count(*) AS c, SUM(amount_minor) AS s FROM "$table" '
                'WHERE account_id = ? GROUP BY k ORDER BY k ASC'
          : 'SELECT (f_booked_on - ((f_booked_on % 100) + 100) % 100) AS k, '
                'count(*) AS c, SUM(f_amount_minor) AS s FROM "$table" '
                'WHERE p_account_id = ? GROUP BY k ORDER BY k ASC',
    );
    final deleteStmt = db.prepare(
      variant.driftLayout
          ? 'DELETE FROM "$table" WHERE id = ?'
          // The engine's cascade delete keys the row by its scope key.
          : 'DELETE FROM "$table" WHERE p_account_id = ? AND id = ?',
    );
    final reinsertStmt = db.prepare(fillSql);

    // Warm-up: every touched page hot, shapes checked once.
    for (final t in targets) {
      final rows = getStmt.select(keyArgs(variant, t));
      if (rows.length != 1) {
        throw StateError('get(${t.path}) returned ${rows.length} rows');
      }
    }
    for (final account in {for (final t in targets) t.accountId}) {
      final rows = latestStmt.select([account]);
      if (rows.length != 50) {
        throw StateError('latest50($account) returned ${rows.length} rows');
      }
      final months = monthStmt.select([account]);
      if (months.isEmpty) {
        throw StateError('monthly groupBy($account) returned no groups');
      }
    }
    final before =
        db.select('SELECT count(*) AS c FROM "$table"').first['c']! as int;
    final warmRow = getStmt.select(keyArgs(variant, targets.first)).first;
    db.execute('BEGIN IMMEDIATE');
    executeDelete(deleteStmt, variant, targets.first);
    final afterDelete =
        db.select('SELECT count(*) AS c FROM "$table"').first['c']! as int;
    reinsertStmt.execute([for (final column in insertColumns) warmRow[column]]);
    db.execute('COMMIT');
    final after =
        db.select('SELECT count(*) AS c FROM "$table"').first['c']! as int;
    if (before - afterDelete != 1 || after != before) {
      throw StateError(
        'the delete shape removed ${before - afterDelete} rows or the '
        're-insert did not restore the table: $before -> $afterDelete -> $after',
      );
    }

    // (a) get by full identity.
    final getMicros = <int>[];
    for (final t in targets) {
      final sw = Stopwatch()..start();
      final rows = getStmt.select(keyArgs(variant, t));
      sw.stop();
      if (rows.length != 1) {
        throw StateError('get returned ${rows.length} rows');
      }
      getMicros.add(sw.elapsedMicroseconds);
    }

    // (b) one account's latest 50 by bookedOn DESC.
    final latestMicros = <int>[];
    for (final t in targets) {
      final sw = Stopwatch()..start();
      final rows = latestStmt.select([t.accountId]);
      sw.stop();
      if (rows.length != 50) {
        throw StateError('latest50 returned ${rows.length} rows');
      }
      latestMicros.add(sw.elapsedMicroseconds);
    }

    // (b2) one account's monthly groupBy (bucket bookedOn by 100, count and
    // sum per month bucket) — the engine's groupBy SQL shape.
    final monthMicros = <int>[];
    for (final t in targets) {
      final sw = Stopwatch()..start();
      final rows = monthStmt.select([t.accountId]);
      sw.stop();
      if (rows.isEmpty) {
        throw StateError('monthly groupBy returned no rows');
      }
      monthMicros.add(sw.elapsedMicroseconds);
    }

    // (c) delete one document with its subtree: the row is captured first
    // and re-inserted untimed, so the timed section is the delete alone.
    final deleteMicros = <int>[];
    for (final t in targets) {
      final captured = getStmt.select(keyArgs(variant, t)).first;
      db.execute('BEGIN IMMEDIATE');
      final sw = Stopwatch()..start();
      executeDelete(deleteStmt, variant, t);
      sw.stop();
      reinsertStmt.execute([
        for (final column in insertColumns) captured[column],
      ]);
      db.execute('COMMIT');
      deleteMicros.add(sw.elapsedMicroseconds);
    }

    getStmt.close();
    latestStmt.close();
    monthStmt.close();
    deleteStmt.close();
    reinsertStmt.close();
    return (
      getUs: p50Of(getMicros),
      latest50Us: p50Of(latestMicros),
      monthUs: p50Of(monthMicros),
      deleteUs: p50Of(deleteMicros),
    );
  } finally {
    db.close();
  }
}

/// The delete statement's arguments for [t]: the scope/PK key for the
/// Cocoon layouts, the drift id for L3.
void executeDelete(
  raw.PreparedStatement deleteStmt,
  LayoutVariant variant,
  ({String path, String id, String accountId}) t,
) {
  if (variant.driftLayout) {
    deleteStmt.execute([t.id]);
  } else {
    deleteStmt.execute([t.accountId, t.id]);
  }
}

/// The p50 of a sample list.
int p50Of(List<int> micros) {
  final sorted = [...micros]..sort();
  return sorted[sorted.length ~/ 2];
}

/// Runs every variant [runs] times (one fresh process per run), then prints
/// the markdown tables from the collected run files.
Future<void> orchestrate({
  required int size,
  required int runs,
  required int ddlSize,
  required Directory dir,
  required String realDriftDb,
}) async {
  try {
    for (final variant in variants) {
      for (var run = 1; run <= runs; run++) {
        stderr.writeln('== ${variant.name} run $run/$runs ==');
        final proc = await Process.run('dart', [
          'run',
          'tool/storage_probe.dart',
          '--variant',
          variant.name,
          '--run',
          '$run',
          '--size',
          '$size',
          '--ddl-size',
          '$ddlSize',
          '--real-drift-db',
          realDriftDb,
          '--out',
          '${dir.path}/${variant.name}_$run.json',
        ]);
        if (proc.exitCode != 0) {
          stderr.write(proc.stderr);
          throw StateError('${variant.name} run $run failed: ${proc.exitCode}');
        }
        stderr.write(proc.stderr);
      }
    }
    collect(dir.path);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Reads every `*.json` run file under [dir] and prints the markdown
/// summary: the main per-variant table and the per-object byte pivot.
void collect(String dir) {
  final runsByVariant = <String, List<Map<String, Object?>>>{};
  for (final file in Directory(
    dir,
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
    final result = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    runsByVariant
        .putIfAbsent(result['variant']! as String, () => [])
        .add(result);
  }
  final medians = <String, Map<String, Object?>>{};
  for (final entry in runsByVariant.entries) {
    num? median(String key) {
      final values = [
        for (final run in entry.value)
          if (run[key] != null) run[key]! as num,
      ]..sort();
      if (values.isEmpty) return null;
      return values[values.length ~/ 2];
    }

    medians[entry.key] = {
      'fileBytes': median('fileBytes'),
      'loadMs': median('loadMs'),
      'indexMs': median('indexMs'),
      'getUs': median('getUs'),
      'latest50Us': median('latest50Us'),
      'monthlyGroupByUs': median('monthlyGroupByUs'),
      'deleteUs': median('deleteUs'),
      'runs': entry.value.length,
    };
  }

  final l0Bytes = medians['L0']?['fileBytes'] as num?;
  String mb(Object? bytes) => bytes == null
      ? '—'
      : ((bytes as num).toInt() / (1024 * 1024)).toStringAsFixed(1);
  String s(Object? ms) =>
      ms == null ? '—' : ((ms as num).toInt() / 1000).toStringAsFixed(1);

  stdout.writeln(
    '| variant | what | file MB | saving vs L0 MB | load s | index s | '
    'get p50 µs | latest-50 p50 µs | monthly groupBy p50 µs | delete p50 µs |',
  );
  stdout.writeln('|---|---|---|---|---|---|---|---|---|---|');
  for (final variant in variants) {
    final m = medians[variant.name];
    if (m == null) {
      continue;
    }
    final saving = l0Bytes == null ? null : l0Bytes - (m['fileBytes']! as num);
    stdout.writeln(
      '| ${variant.name} | ${variant.description} | ${mb(m["fileBytes"])} | '
      '${saving == null ? '—' : (saving == 0 ? '—' : mb(saving))} | '
      '${s(m["loadMs"])} | ${s(m["indexMs"])} | ${m["getUs"]} | '
      '${m["latest50Us"]} | ${m["monthlyGroupByUs"]} | ${m["deleteUs"]} |',
    );
  }

  // Per-object byte pivot: one row per object any variant holds, median
  // bytes across the variant's runs.
  final objectTypes = <String, String>{};
  final objectBytes = <String, Map<String, int>>{};
  for (final entry in runsByVariant.entries) {
    final bytesByName = <String, List<int>>{};
    for (final run in entry.value) {
      for (final object in run['objects']! as List) {
        final object_ = object! as Map<String, Object?>;
        final name = object_['name']! as String;
        bytesByName.putIfAbsent(name, () => []).add(object_['bytes']! as int);
        objectTypes[name] = object_['type']! as String;
      }
    }
    for (final name in bytesByName.keys) {
      final values = bytesByName[name]!..sort();
      objectBytes.putIfAbsent(name, () => {})[entry.key] =
          values[values.length ~/ 2];
    }
  }
  final orderedNames = objectTypes.keys.toList()
    ..sort((a, b) {
      int bytesOf(String name) =>
          objectBytes[name]?['L0'] ?? objectBytes[name]?['L1'] ?? 0;
      final byL0 = bytesOf(b).compareTo(bytesOf(a));
      if (byL0 != 0) return byL0;
      return a.compareTo(b);
    });
  stdout.writeln('');
  stdout.writeln(
    '| object | type | '
    '${variants.map((v) => "${v.name} MB").join(' | ')} |',
  );
  stdout.writeln('|${'---|' * (variants.length + 2)}');
  for (final name in orderedNames) {
    stdout.writeln(
      '| $name | ${objectTypes[name]} | '
      '${variants.map((v) => mb(objectBytes[name]?[v.name])).join(' | ')} |',
    );
  }
}

Future<void> main(List<String> args) async {
  var size = 1000000;
  var runs = 3;
  var ddlSize = 2000;
  var collectDir = '';
  String? variantName;
  int? run;
  var outPath = '';
  var realDriftDb = defaultRealDriftDb;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--size':
        size = int.parse(args[++i]);
      case '--runs':
        runs = int.parse(args[++i]);
      case '--ddl-size':
        ddlSize = int.parse(args[++i]);
      case '--variant':
        variantName = args[++i];
      case '--run':
        run = int.parse(args[++i]);
      case '--out':
        outPath = args[++i];
      case '--collect':
        collectDir = args[++i];
      case '--real-drift-db':
        realDriftDb = args[++i];
      default:
        stderr.writeln('Unknown argument ${args[i]}');
        exit(2);
    }
  }

  if (collectDir.isNotEmpty) {
    collect(collectDir);
    return;
  }

  if (variantName != null) {
    final variant = variants.where((v) => v.name == variantName).firstOrNull;
    if (variant == null) {
      stderr.writeln(
        'Unknown variant $variantName '
        '(known: ${variants.map((v) => v.name).join(" ")})',
      );
      exit(2);
    }
    final dir = Directory.systemTemp.createTempSync('cocoon_storage_');
    try {
      final result = await measure(
        variant: variant,
        size: size,
        run: run ?? 1,
        ddlSize: ddlSize,
        dir: dir,
        realDriftDb: realDriftDb,
      );
      final line = jsonEncode(result);
      if (outPath.isNotEmpty) {
        File(outPath).parent.createSync(recursive: true);
        File(outPath).writeAsStringSync(line);
      }
      stdout.writeln(line);
    } finally {
      dir.deleteSync(recursive: true);
    }
    return;
  }

  await orchestrate(
    size: size,
    runs: runs,
    ddlSize: ddlSize,
    dir: Directory.systemTemp.createTempSync('cocoon_storage_report_'),
    realDriftDb: realDriftDb,
  );
}
