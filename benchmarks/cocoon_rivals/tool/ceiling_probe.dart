/// The SQLite ceiling map (dev tool, not shipped): what the fastest possible
/// SQLite load of Cocoon's real `txn` table costs at 1M, and what each lever
/// buys — the numbers behind `CEILING.md`.
///
/// The DDL is not written from memory: the probe first builds a small real
/// `cocoon.db` with the engine, reads the exact `CREATE TABLE`/`CREATE
/// INDEX` statements (the amount index and the change-log table included)
/// from its `sqlite_master`, and measures the average encoded row-blob size
/// from that database. The fill then generates rows per chunk (low
/// retention, see the step-11 ceiling addendum in `IMPORT.md`) with blobs of
/// exactly that average size, at Cocoon's writer pragmas (64 MiB page cache,
/// temp_store MEMORY, wal_autocheckpoint 8000, journal_size_limit 4 MiB),
/// `synchronous=FULL` unless the variant says otherwise.
///
/// Variants (each: fresh db in its own process — peak RSS is a process
/// high-water mark — and the median of [runs] runs):
///
/// - `v1`   per-1000-row transactions, all indexes live, dataset order
///          (today's raw ceiling);
/// - `v2`   v1 + one change-log row per document (what Cocoon writes today);
/// - `v2b`  v1 + one change-log row per 1000-doc batch (a watermark row);
/// - `v3`   all rows in one transaction;
/// - `v4`   secondary indexes absent during the load, created at the end
///          (load and index build timed separately, the total is the wall);
/// - `v5`   v4 with the rows inserted in `path` order;
/// - `v6`   integer rowid key (the inline `path UNIQUE` dropped), scope
///          index only during the load, path-unique + secondaries at the end;
/// - `v7`   v1 through sqlite_async `executeBatch` from the main isolate
///          (prices the isolate hop and driver against v1's direct
///          `package:sqlite3` calls);
/// - `v8a`  v1 with `synchronous=NORMAL`;
/// - `v8b`  v4 with `synchronous=NORMAL`.
///
/// usage:
/// ```sh
/// dart run tool/ceiling_probe.dart [--size 1000000] [--runs 3]
/// dart run tool/ceiling_probe.dart --variant v1 --run 1   # one measurement
/// ```
///
/// The orchestrator (no `--variant`) spawns one fresh process per run, takes
/// medians and prints the summary table. The cost metrics (CPU, disk
/// written) bracket DDL + fill + deferred index builds; the close-time WAL
/// checkpoint lands only in the final file size. Chunk randoms are seeded
/// per chunk index, so every variant and run draws the same distribution.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/dataset.dart';
// The v7 variant prices Cocoon's own open path (the same factory pragmas);
// nothing outside this dev tool depends on these imports.
import 'package:cocoon/src/engine/sqlite_executor.dart'; // ignore: implementation_imports
import 'package:cocoon_rivals/engine.dart'
    show OpCost, fileSizeWithSidecars, importBatchSize;
import 'package:cocoon_rivals/models.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

/// Whether a variant writes change-log rows, and at which granularity.
enum ChangeRows { none, perDoc, perChunk }

/// One variant's definition: everything that differs from v1.
final class Variant {
  const Variant({
    required this.name,
    required this.description,
    this.singleTxn = false,
    this.changeRows = ChangeRows.none,
    this.deferSecondaries = false,
    this.pathOrder = false,
    this.rowidKey = false,
    this.synchronousNormal = false,
    this.viaSqliteAsync = false,
  });

  /// Short name (`v1`, `v2b`, ...).
  final String name;

  /// One-line description for the summary table.
  final String description;

  /// All rows inside one transaction.
  final bool singleTxn;

  /// Whether/how the change log is written.
  final ChangeRows changeRows;

  /// Secondary indexes created at the end, not during the load.
  final bool deferSecondaries;

  /// Rows inserted in `path` order instead of dataset order.
  final bool pathOrder;

  /// The table loses its inline `path UNIQUE` (integer rowid key); the path
  /// unique index is created at the end with the secondaries.
  final bool rowidKey;

  /// `PRAGMA synchronous = NORMAL` instead of FULL.
  final bool synchronousNormal;

  /// The fill runs through sqlite_async `executeBatch` (main isolate)
  /// instead of direct `package:sqlite3` calls.
  final bool viaSqliteAsync;

  /// Whether the fill defers index DDL to the end.
  bool get hasDeferredIndexes => deferSecondaries || rowidKey;
}

/// The variants, in run order.
const variants = [
  Variant(
    name: 'v1',
    description: 'per-1000 txns, all indexes, dataset order (today)',
  ),
  Variant(
    name: 'v2',
    description: 'v1 + one change-log row per document (Cocoon today)',
    changeRows: ChangeRows.perDoc,
  ),
  Variant(
    name: 'v2b',
    description: 'v1 + one change-log row per 1000-doc batch',
    changeRows: ChangeRows.perChunk,
  ),
  Variant(
    name: 'v3',
    description: 'all rows in one transaction',
    singleTxn: true,
  ),
  Variant(
    name: 'v4',
    description: 'secondary indexes deferred to the end',
    deferSecondaries: true,
  ),
  Variant(
    name: 'v5',
    description: 'v4, rows inserted in path order',
    deferSecondaries: true,
    pathOrder: true,
  ),
  Variant(
    name: 'v6',
    description: 'integer rowid key, path unique + secondaries at the end',
    rowidKey: true,
  ),
  Variant(
    name: 'v7',
    description: 'v1 through sqlite_async executeBatch (main isolate)',
    viaSqliteAsync: true,
  ),
  Variant(
    name: 'v8a',
    description: 'v1 with synchronous=NORMAL',
    synchronousNormal: true,
  ),
  Variant(
    name: 'v8b',
    description: 'v4 with synchronous=NORMAL',
    deferSecondaries: true,
    synchronousNormal: true,
  ),
];

Future<void> main(List<String> args) async {
  var size = 1000000;
  var runs = 3;
  var ddlSize = 2000;
  String? variantName;
  int? run;
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
      default:
        stderr.writeln('Unknown argument ${args[i]}');
        exit(2);
    }
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
    final dir = Directory.systemTemp.createTempSync('cocoon_ceiling_');
    try {
      final result = await measure(
        variant: variant,
        size: size,
        run: run ?? 1,
        ddlSize: ddlSize,
        dir: dir,
      );
      stdout.writeln(jsonEncode(result));
    } finally {
      dir.deleteSync(recursive: true);
    }
    return;
  }

  await orchestrate(size: size, runs: runs, ddlSize: ddlSize);
}

/// The DDL and average row-blob size read from a real engine-built
/// `cocoon.db`.
final class RealSchema {
  RealSchema({
    required this.tableName,
    required this.tableSql,
    required this.changesTableName,
    required this.changesSql,
    required this.scopeIndexSql,
    required this.secondaryIndexSqls,
    required this.avgDataBytes,
    required this.columnNames,
  });

  /// The txn table's SQL name (e.g. `txn`).
  final String tableName;

  /// Its `CREATE TABLE` statement.
  final String tableSql;

  /// The change log's SQL name and `CREATE TABLE` statement.
  final String changesTableName;
  final String changesSql;

  /// The table's implicit `(p_params..., id)` unique index.
  final String scopeIndexSql;

  /// The declared (secondary) index statements, in creation order.
  final List<String> secondaryIndexSqls;

  /// `avg(length(data))` over the real database's rows, in bytes.
  final int avgDataBytes;

  /// The txn table's columns in declared order.
  final List<String> columnNames;
}

/// Builds a small real `cocoon.db` with the engine and reads its schema.
Future<RealSchema> readRealSchema(String dir, int ddlSize) async {
  Directory(dir).createSync(recursive: true);
  final data = BenchDataset.build(txnCount: ddlSize);
  final db = await Cocoon.open('$dir/cocoon.db', collections: [accounts, txns]);
  try {
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        start + importBatchSize > data.txns.length
            ? data.txns.length
            : start + importBatchSize,
      );
      final write = db.batch();
      for (final benchTxn in batch) {
        write.set(
          db
              .collection(accounts)
              .doc(benchTxn.accountId)
              .collection(txns)
              .doc(benchTxn.id),
          benchTxn.txn,
        );
      }
      await write.commit();
    }
  } finally {
    await db.close();
  }

  final rawDb = raw.sqlite3.open('$dir/cocoon.db');
  try {
    final rows = rawDb.select(
      'SELECT name, type, sql FROM sqlite_master WHERE sql IS NOT NULL',
    );
    final txnIndexRows = rawDb.select(
      "SELECT name, sql FROM sqlite_master "
      "WHERE type = 'index' AND sql IS NOT NULL AND tbl_name = ?",
      [tableNameFor('Txn')],
    );
    String? changesSql;
    final indexSqls = <String>[
      for (final row in txnIndexRows) row['sql']! as String,
    ];
    // The change-log table by name; the txn table by the engine's own
    // naming rule (the db holds both collections' tables, and sqlite_master
    // stores `CREATE TABLE <name> ...` without the IF NOT EXISTS).
    for (final row in rows) {
      if ((row['type']! as String) != 'table') {
        continue;
      }
      final sql = row['sql']! as String;
      if (sql.startsWith('CREATE TABLE _cocoon_changes')) {
        changesSql = sql;
      }
    }
    final tableName = tableNameFor('Txn');
    final tableSql = rows
        .map((row) => row['sql'])
        .whereType<String>()
        .where((sql) => sql.startsWith('CREATE TABLE $tableName '))
        .single;
    if (changesSql == null) {
      throw StateError(
        'real cocoon.db: expected the txn table and the change-log table, '
        'found ${rows.length} schema objects',
      );
    }
    final changesTableName = RegExp(
      r'CREATE TABLE (\w+)',
    ).firstMatch(changesSql)!.group(1)!;
    final scopeName = 'cx_${tableName}_scope';
    final scopeIndexSql = indexSqls
        .where((sql) => sql.contains(scopeName))
        .single;
    final secondaryIndexSqls = indexSqls
        .where((sql) => !sql.contains(scopeName))
        .toList();
    final columns = [
      for (final row in rawDb.select('PRAGMA table_info($tableName)'))
        row['name']! as String,
    ];
    final avg = rawDb.select('SELECT avg(length(data)) AS a FROM $tableName');
    stderr.writeln(
      'real schema: table $tableName, ${secondaryIndexSqls.length} secondary '
      'indexes, avg row blob ${((avg.first['a']! as double).round())} bytes, '
      'columns ${columns.join(', ')}',
    );
    return RealSchema(
      tableName: tableName,
      tableSql: tableSql,
      changesTableName: changesTableName,
      changesSql: changesSql,
      scopeIndexSql: scopeIndexSql,
      secondaryIndexSqls: secondaryIndexSqls,
      avgDataBytes: (avg.first['a']! as double).round(),
      columnNames: columns,
    );
  } finally {
    rawDb.close();
  }
}

/// One measurement: a fresh db, filled per [variant], fully closed. All temp
/// files live under [dir] (deleted by the caller).
Future<Map<String, Object?>> measure({
  required Variant variant,
  required int size,
  required int run,
  required int ddlSize,
  required Directory dir,
}) async {
  // 1. The real schema (untimed).
  final schema = await readRealSchema('${dir.path}/real', ddlSize);

  // 2. The variant's database, filled and closed inside the bracket.
  final path = '${dir.path}/${variant.name}_$run.db';
  final tableSql = variant.rowidKey
      ? _withoutPathUnique(schema.tableSql)
      : schema.tableSql;
  final deferred = <String>[
    if (variant.rowidKey) _pathUniqueIndexSql(schema),
    if (variant.deferSecondaries || variant.rowidKey)
      ...schema.secondaryIndexSqls,
  ];

  final cost = OpCost.start();
  final sw = Stopwatch()..start();
  final (loadMs, indexMs) = variant.viaSqliteAsync
      ? await _fillSqliteAsync(path, variant, schema, size, run)
      : await _fillRaw(path, variant, schema, size, run, tableSql, deferred);
  sw.stop();
  final wallMs = sw.elapsedMilliseconds;
  final (:cpuMs, :diskWriteBytes) = cost.stop();

  // Post-close diagnostics: what the fill actually left on disk.
  final diagDb = raw.sqlite3.open(path);
  int pageCount = 0;
  int freePages = 0;
  try {
    pageCount = diagDb.select('PRAGMA page_count').first['page_count']! as int;
    freePages =
        diagDb.select('PRAGMA freelist_count').first['freelist_count']! as int;
  } finally {
    diagDb.close();
  }

  return {
    'variant': variant.name,
    'run': run,
    'size': size,
    'wallMs': wallMs,
    'loadMs': loadMs,
    'indexMs': indexMs,
    'pageCount': pageCount,
    'freelistPages': freePages,
    'peakRssBytes': ProcessInfo.maxRss,
    'cpuMs': cpuMs,
    'diskWriteBytes': ?diskWriteBytes,
    'fileBytes': fileSizeWithSidecars(path),
    'avgDataBytes': schema.avgDataBytes,
  };
}

/// Strips the inline `UNIQUE` from `path` (v6's rowid-keyed table).
String _withoutPathUnique(String tableSql) {
  const marker = 'path TEXT NOT NULL UNIQUE';
  if (!tableSql.contains(marker)) {
    throw StateError('real table DDL does not declare "$marker"');
  }
  return tableSql.replaceFirst(marker, 'path TEXT NOT NULL');
}

/// The path unique index statement v6 defers to the end (the inline
/// `UNIQUE`'s stand-in, same column, same uniqueness).
String _pathUniqueIndexSql(RealSchema schema) =>
    'CREATE UNIQUE INDEX IF NOT EXISTS cx_${schema.tableName}_path_late '
    'ON ${schema.tableName} (path)';

/// Opens the database at Cocoon's writer pragmas.
raw.Database _openRaw(String path, {required bool synchronousNormal}) {
  final db = raw.sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('PRAGMA synchronous = ${synchronousNormal ? 'NORMAL' : 'FULL'}');
  db.execute('PRAGMA cache_size = -65536');
  db.execute('PRAGMA temp_store = MEMORY');
  db.execute('PRAGMA wal_autocheckpoint = 8000');
  db.execute('PRAGMA journal_size_limit = 4194304');
  return db;
}

/// The direct-`package:sqlite3` fill used by every variant but v7. Returns
/// (loadMs, deferredIndexMs); the wall time (DDL + load + indexes) is the
/// caller's stopwatch.
Future<(int, int)> _fillRaw(
  String path,
  Variant variant,
  RealSchema schema,
  int size,
  int run,
  String tableSql,
  List<String> deferredIndexSqls,
) async {
  final db = _openRaw(path, synchronousNormal: variant.synchronousNormal);
  try {
    db.execute(tableSql);
    db.execute(schema.changesSql);
    db.execute(schema.scopeIndexSql);
    if (!variant.deferSecondaries && !variant.rowidKey) {
      for (final indexSql in schema.secondaryIndexSqls) {
        db.execute(indexSql);
      }
    }

    final insert = db.prepare(
      variant.rowidKey ? _plainInsertSql(schema) : _upsertSql(schema),
    );
    final changeRow = db.prepare(
      "INSERT INTO ${schema.changesTableName} (tbl, path, op, at) "
      "VALUES ('txn', ?, 'set', ?)",
    );
    final changeBatch = db.prepare(
      "INSERT INTO ${schema.changesTableName} (tbl, path, op, at) "
      "VALUES ('txn', '', 'set', ?)",
    );

    final swLoad = Stopwatch()..start();
    if (variant.singleTxn) {
      db.execute('BEGIN IMMEDIATE');
    }
    var chunkIndex = 0;
    for (var start = 0; start < size; start += importBatchSize) {
      final rows = chunkRows(
        index: chunkIndex++,
        count: min(importBatchSize, size - start),
        avgDataBytes: schema.avgDataBytes,
        seed: 42 + run,
        pathOrder: variant.pathOrder,
        size: size,
      );
      if (!variant.singleTxn) {
        db.execute('BEGIN IMMEDIATE');
      }
      final at = DateTime.now().toUtc().microsecondsSinceEpoch;
      for (final row in rows) {
        insert.execute(row);
        if (variant.changeRows == ChangeRows.perDoc) {
          changeRow.execute([row[0], at]);
        }
      }
      if (variant.changeRows == ChangeRows.perChunk) {
        changeBatch.execute([at]);
      }
      if (!variant.singleTxn) {
        db.execute('COMMIT');
      }
    }
    if (variant.singleTxn) {
      db.execute('COMMIT');
    }
    swLoad.stop();

    // Finalize before close: an open statement holds a WAL read mark and
    // the close-time checkpoint would silently not happen, leaving the
    // fill's pages in the WAL instead of the database file.
    insert.close();
    changeRow.close();
    changeBatch.close();

    var indexMs = 0;
    for (final indexSql in deferredIndexSqls) {
      final swIndex = Stopwatch()..start();
      db.execute(indexSql);
      swIndex.stop();
      indexMs += swIndex.elapsedMilliseconds;
    }
    return (swLoad.elapsedMilliseconds, indexMs);
  } finally {
    db.close();
  }
}

/// The sqlite_async fill (v7): one `executeBatch` per 1000 rows from the
/// main isolate, the same factory pragmas Cocoon opens with.
Future<(int, int)> _fillSqliteAsync(
  String path,
  Variant variant,
  RealSchema schema,
  int size,
  int run,
) async {
  final database = SqliteDatabase.withFactory(
    CocoonSqliteOpenFactory(
      path: path,
      sqliteOptions: SqliteOptions(
        synchronous: variant.synchronousNormal
            ? SqliteSynchronous.normal
            : SqliteSynchronous.full,
        profileQueries: false,
      ),
      pageCacheKib: 64 * 1024,
      tempStoreInMemory: true,
      walAutoCheckpointPages: 8000,
    ),
  );
  final executor = SqliteExecutor(database);
  try {
    final upsertSql = _upsertSql(schema);
    await executor.writeTransaction((tx) async {
      await tx.execute(schema.tableSql);
      await tx.execute(schema.changesSql);
      await tx.execute(schema.scopeIndexSql);
      for (final indexSql in schema.secondaryIndexSqls) {
        await tx.execute(indexSql);
      }
    });

    final swLoad = Stopwatch()..start();
    var chunkIndex = 0;
    for (var start = 0; start < size; start += importBatchSize) {
      final rows = chunkRows(
        index: chunkIndex++,
        count: min(importBatchSize, size - start),
        avgDataBytes: schema.avgDataBytes,
        seed: 42 + run,
        pathOrder: false,
        size: size,
      );
      await executor.writeTransaction((tx) => tx.executeBatch(upsertSql, rows));
    }
    swLoad.stop();
    return (swLoad.elapsedMilliseconds, 0);
  } finally {
    await executor.close();
  }
}

/// The upsert statement over the real columns, in declared order — the
/// statement Cocoon's own writes bind.
String _upsertSql(RealSchema schema) {
  final columns = schema.columnNames;
  final placeholders = List.filled(columns.length, '?').join(', ');
  final updates = columns
      .skip(1)
      .map((name) => '$name = excluded.$name')
      .join(', ');
  return 'INSERT INTO ${schema.tableName} (${columns.join(', ')}) '
      'VALUES ($placeholders) '
      'ON CONFLICT(path) DO UPDATE SET $updates';
}

/// The plain insert for v6's rowid-keyed table: no unique constraint exists
/// during the load, so there is no conflict target.
String _plainInsertSql(RealSchema schema) {
  final columns = schema.columnNames;
  final placeholders = List.filled(columns.length, '?').join(', ');
  return 'INSERT INTO ${schema.tableName} (${columns.join(', ')}) '
      'VALUES ($placeholders)';
}

/// Builds one chunk of rows, dropped again right after its transaction —
/// nothing is retained (the step-11 ceiling addendum).
///
/// Dataset order walks the global index account-round-robin (row `i` lives
/// at `accounts/a{i % 20}/txns/t{i}`); `path` order walks account-major.
/// Blobs are random bytes of exactly [avgDataBytes] — the real database's
/// average — and booked days, statuses and amounts follow the dataset's
/// distribution. The chunk's rng is seeded from (seed, chunk index), so
/// every variant and run draws the same distribution.
///
/// Public so `storage_probe.dart` reuses the exact same rows for the layout
/// variants; the drift-shaped rows of its L5 reference are generated there
/// with the same distributions (see `dataset.dart`).
List<List<Object?>> chunkRows({
  required int index,
  required int count,
  required int avgDataBytes,
  required int seed,
  required bool pathOrder,
  required int size,
}) {
  final rng = Random(seed * 1000003 + index);
  final rows = <List<Object?>>[];
  for (var i = 0; i < count; i++) {
    final globalIndex = pathOrder
        ? // Account-major: chunk c covers the c*1000-th rows of the
          // path-sorted sequence — account (c*1000+i) ~/ (size/20)'s round,
          // id within the account.
          pathOrderedIndex(index * importBatchSize + i, size)
        : index * importBatchSize + i;
    final accountId = globalIndex % 20;
    final blob = Uint8List(avgDataBytes);
    for (var b = 0; b < blob.length; b++) {
      blob[b] = rng.nextInt(256);
    }
    final year = 2022 + rng.nextInt(5);
    final month = 1 + rng.nextInt(12);
    final day = 1 + rng.nextInt(28);
    final status = switch (rng.nextInt(100)) {
      < 85 => 'posted',
      < 95 => 'pending',
      _ => 'failed',
    };
    final negative = rng.nextInt(10) < 4;
    final magnitude = 100 + rng.nextInt(990000);
    rows.add([
      'accounts/a${accountId.toString().padLeft(2, '0')}/txns/'
          't${globalIndex.toString().padLeft(9, '0')}',
      't${globalIndex.toString().padLeft(9, '0')}',
      'a${accountId.toString().padLeft(2, '0')}',
      blob,
      year * 10000 + month * 100 + day,
      status,
      negative ? -magnitude : magnitude,
    ]);
  }
  return rows;
}

/// The global index of the [position]-th row of the path-sorted sequence:
/// account-major over 20 accounts of [size] rows total.
int pathOrderedIndex(int position, int size) {
  const accounts = 20;
  final perAccount = size ~/ accounts;
  final account = position ~/ perAccount;
  final within = position % perAccount;
  return within * accounts + account;
}

/// Runs every variant [runs] times, one fresh process per run (peak RSS is
/// a process high-water mark), and prints the median summary table.
Future<void> orchestrate({
  required int size,
  required int runs,
  required int ddlSize,
}) async {
  final results = <String, List<Map<String, Object?>>>{};
  for (final variant in variants) {
    final runs_ = <Map<String, Object?>>[];
    for (var run = 1; run <= runs; run++) {
      stderr.writeln('== ${variant.name} run $run/$runs ==');
      final proc = await Process.run('dart', [
        'run',
        'tool/ceiling_probe.dart',
        '--variant',
        variant.name,
        '--run',
        '$run',
        '--size',
        '$size',
        '--ddl-size',
        '$ddlSize',
      ]);
      if (proc.exitCode != 0) {
        stderr.write(proc.stderr);
        throw StateError('${variant.name} run $run failed: ${proc.exitCode}');
      }
      stderr.write(proc.stderr);
      final line = (proc.stdout as String)
          .split('\n')
          .lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      runs_.add(jsonDecode(line) as Map<String, Object?>);
    }
    results[variant.name] = runs_;
  }

  final dir = Directory.systemTemp.createTempSync('cocoon_ceiling_report_');
  try {
    // One real-schema read for the header numbers.
    final schema = await readRealSchema(dir.path, ddlSize);
    stdout.writeln('');
    stdout.writeln(
      '# SQLite ceiling at $size txns '
      '(medians of $runs fresh-process runs; '
      'real avg row blob ${schema.avgDataBytes} bytes)',
    );
    stdout.writeln('');
    stdout.writeln(
      '| variant | wall s | load s | index s | peak RSS MB | CPU s | '
      'disk MB | file MB |',
    );
    stdout.writeln('|---|---|---|---|---|---|---|---|');
    for (final variant in variants) {
      final rs = results[variant.name]!;
      int? med(String key) {
        final values = [
          for (final r in rs)
            if (r[key] != null) (r[key]! as num).toInt(),
        ]..sort();
        return values.isEmpty ? null : values[values.length ~/ 2];
      }

      String s(int? ms) => ms == null ? '—' : (ms / 1000).toStringAsFixed(1);
      String mb(int? bytes) =>
          bytes == null ? '—' : (bytes / (1024 * 1024)).toStringAsFixed(0);
      final indexMs = variant.hasDeferredIndexes ? med('indexMs') : null;
      stdout.writeln(
        '| ${variant.name} | ${s(med("wallMs"))} | ${s(med("loadMs"))} | '
        '${s(indexMs)} | ${mb(med("peakRssBytes"))} | ${s(med("cpuMs"))} | '
        '${mb(med("diskWriteBytes"))} | ${mb(med("fileBytes"))} |',
      );
    }
    stdout.writeln('');
    for (final variant in variants) {
      stdout.writeln('- ${variant.name}: ${variant.description}');
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}
