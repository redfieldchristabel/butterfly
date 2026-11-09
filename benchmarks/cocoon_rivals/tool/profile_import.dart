/// Phase-1 import profiler for the Cocoon bulk-import path (dev tool, not
/// shipped with the package).
///
/// Imports the benchmark dataset exactly the way the harness does
/// (`runTransaction` + `tx.set`, 1000 documents per transaction), with the
/// executor wrapped so every SQL round trip is counted and timed, and prints
/// a breakdown of where the wall time goes:
///
/// - the SQL round trips (`execute`/`executeBatch`/reads), each of which is
///   an isolate hop in sqlite_async, with the wait time attributed to the
///   document upserts, the change-log rows and everything else;
/// - the Dart-side costs measured over the same dataset outside the import:
///   `adapter.encode`, the encode->decode normalize round trip
///   `putDocInTx` performs per document, the per-document SQL string
///   building, and the change-row parameter building;
/// - the unaccounted remainder (cache staging, id/path building, event
///   loop overhead, ...).
///
/// The SQLite ceiling runs with `--mode ceiling` in its own process: the
/// same table + indexes Cocoon creates, filled with the same pre-encoded
/// rows via one `executeBatch` per 1000 rows — once at Cocoon's commit
/// granularity (one transaction per 1000 rows) and once inside a single
/// transaction (what SQLite itself can do here). The retained dataset's GC
/// pressure skews in-process ceilings at 100k+ rows, so the two modes never
/// share a process.
///
/// usage:
/// ```sh
/// dart run tool/profile_import.dart --size 100000 [--durability full|normal]
/// dart run tool/profile_import.dart --size 100000 --mode ceiling
/// ```
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:cocoon/cocoon.dart';
// The profiler deliberately reaches into the engine's executor interface to
// instrument it; nothing outside this dev tool depends on these imports.
import 'package:cocoon/src/engine/executor.dart'; // ignore: implementation_imports
import 'package:cocoon/src/engine/schema_sql.dart'; // ignore: implementation_imports
import 'package:cocoon/src/engine/sqlite_executor.dart'; // ignore: implementation_imports
import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/engine.dart' show importBatchSize;
import 'package:cocoon_rivals/models.dart';
import 'package:sqlite_async/sqlite_async.dart';

Future<void> main(List<String> args) async {
  var size = 100000;
  var durability = Durability.full;
  // 'profile' runs the instrumented import; 'ceiling' measures the SQLite
  // ceiling in its own process — the retained dataset's GC pressure skews
  // in-process ceilings at 100k+ rows, so the two never share a process.
  var mode = 'profile';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--size':
        size = int.parse(args[++i]);
      case '--durability':
        durability = switch (args[++i]) {
          'normal' => Durability.normal,
          _ => Durability.full,
        };
      case '--mode':
        mode = args[++i];
      default:
        stderr.writeln('Unknown argument ${args[i]}');
        exit(2);
    }
  }

  switch (mode) {
    case 'profile':
      await _runProfile(size, durability);
    case 'ceiling':
      await _runCeiling(size, durability);
    default:
      stderr.writeln('Unknown mode $mode (use profile or ceiling)');
      exit(2);
  }
}

Future<void> _runProfile(int size, Durability durability) async {
  final dir = Directory.systemTemp.createTempSync('cocoon_profile_');
  try {
    final data = BenchDataset.build(txnCount: size);
    final registry = SchemaRegistry.build([accounts, txns]);
    final entry = registry.byPattern(txns.pattern)!;

    // -- The Dart-side costs, measured over the same dataset ----------------
    final encodeUs = _timeAll(data.txns, (t) => txns.encode(t.txn));
    final normalizeUs = _timeAll(
      data.txns,
      (t) => txns.decode(txns.encode(t.txn)),
    );
    final sqlBuildUs = _timeAll(
      data.txns,
      (t) => _buildUpsertSqlString(entry, _txnPath(t)),
    );
    final changeRowUs = _timeAll(data.txns, (t) {
      final at = DateTime.now().toUtc().microsecondsSinceEpoch;
      return [entry.table, _txnPath(t), 'set', at];
    });

    // -- The instrumented import -------------------------------------------
    // The database opens exactly as `Cocoon.open` opens it: the engine's
    // factory, so the profile measures the shipped default pragmas
    // (CocoonOptions' 64 MiB page cache and temp_store = MEMORY) too.
    final executor = _ProfiledExecutor(
      SqliteExecutor(
        SqliteDatabase.withFactory(
          CocoonSqliteOpenFactory(
            path: '${dir.path}/profile.db',
            sqliteOptions: SqliteOptions(
              synchronous: _synchronousOf(durability),
              profileQueries: false,
            ),
            pageCacheKib: CocoonOptions.defaultPageCacheMiB * 1024,
            tempStoreInMemory: true,
            walAutoCheckpointPages:
                CocoonOptions.defaultWalAutoCheckpointPages,
          ),
        ),
      ),
    );
    // A dev-tool test of the engine's instrumented open path.
    // ignore: invalid_use_of_visible_for_testing_member
    final db = await Cocoon.openWith(
      executor,
      collections: [accounts, txns],
      options: CocoonOptions(durability: durability),
    );

    // Accounts first, untimed — the harness import does the same.
    for (var i = 0; i < data.accounts.length; i++) {
      await db
          .collection(accounts)
          .doc('a${i.toString().padLeft(2, '0')}')
          .set(data.accounts[i]);
    }

    executor.reset();
    final sw = Stopwatch()..start();
    for (var start = 0; start < data.txns.length; start += importBatchSize) {
      final batch = data.txns.sublist(
        start,
        math.min(start + importBatchSize, data.txns.length),
      );
      await db.runTransaction((tx) async {
        for (final benchTxn in batch) {
          await tx.set(
            db
                .collection(accounts)
                .doc(benchTxn.accountId)
                .collection(txns)
                .doc(benchTxn.id),
            benchTxn.txn,
          );
        }
      });
    }
    sw.stop();
    await db.close();
    final importMs = sw.elapsedMilliseconds;

    _report(
      size: size,
      durability: durability,
      importMs: importMs,
      profiler: executor,
      encodeUs: encodeUs,
      normalizeUs: normalizeUs,
      sqlBuildUs: sqlBuildUs,
      changeRowUs: changeRowUs,
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Future<void> _runCeiling(int size, Durability durability) async {
  final dir = Directory.systemTemp.createTempSync('cocoon_ceiling_');
  try {
    final data = BenchDataset.build(txnCount: size);
    final registry = SchemaRegistry.build([accounts, txns]);
    final entry = registry.byPattern(txns.pattern)!;
    // Pre-encode every row outside the timed sections, then drop the typed
    // dataset so its heap does not skew the measurements.
    final rows = <List<Object?>>[
      for (final benchTxn in data.txns) _buildUpsertArgs(entry, benchTxn),
    ];

    List<List<Object?>> chunkRows(int start) =>
        rows.sublist(start, math.min(start + importBatchSize, rows.length));
    final upsertSql = _buildUpsertSqlString(entry, 'accounts/a00/txns/x');

    // Ceiling A: one write transaction per 1000 rows — Cocoon's own commit
    // granularity, so the same number of commits and fsyncs.
    final swA = await _withFresh('${dir.path}/ceilingA.db', entry, durability, (
      executor,
    ) async {
      final sw = Stopwatch()..start();
      for (var start = 0; start < rows.length; start += importBatchSize) {
        await executor.writeTransaction(
          (tx) => tx.executeBatch(upsertSql, chunkRows(start)),
        );
      }
      sw.stop();
      return sw.elapsedMilliseconds;
    });

    // Ceiling B: one write transaction for the whole import, executeBatch
    // per 1000 rows — what SQLite itself can do with the same rows/indexes.
    final swB = await _withFresh('${dir.path}/ceilingB.db', entry, durability, (
      executor,
    ) async {
      final sw = Stopwatch()..start();
      await executor.writeTransaction((tx) async {
        for (var start = 0; start < rows.length; start += importBatchSize) {
          await tx.executeBatch(upsertSql, chunkRows(start));
        }
      });
      sw.stop();
      return sw.elapsedMilliseconds;
    });

    final perChunk = swA / (rows.length / importBatchSize);
    stdout.writeln(
      '== SQLite import ceiling: $size txns '
      '(Durability.${durability.name}) ==',
    );
    stdout.writeln(
      '  one txn per 1000 rows: $swA ms '
      '(${perChunk.toStringAsFixed(1)} ms per 1000-row chunk)',
    );
    stdout.writeln('  one txn for all rows:  $swB ms');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Creates a fresh database with Cocoon's `txn` table + indexes and hands it
/// to [fill] as a [CocoonExecutor]; the fill manages its own transactions and
/// returns its own elapsed milliseconds.
Future<int> _withFresh(
  String path,
  RegistryEntry entry,
  Durability durability,
  Future<int> Function(CocoonExecutor executor) fill,
) async {
  final db = SqliteDatabase.withFactory(
    // The engine's open path, so the ceiling is what SQLite itself can do
    // under Cocoon's shipped default pragmas.
    CocoonSqliteOpenFactory(
      path: path,
      sqliteOptions: SqliteOptions(
        synchronous: _synchronousOf(durability),
        profileQueries: false,
      ),
      pageCacheKib: CocoonOptions.defaultPageCacheMiB * 1024,
      tempStoreInMemory: true,
      walAutoCheckpointPages: CocoonOptions.defaultWalAutoCheckpointPages,
    ),
  );
  final executor = SqliteExecutor(db);
  try {
    await executor.writeTransaction((tx) async {
      await tx.execute(
        createTableSql(entry.table, entry.paramSqlNames, entry.columnDdls),
      );
      await tx.execute(createScopeIndexSql(entry.table, entry.paramSqlNames));
      for (final index in entry.indexes) {
        await tx.execute(createIndexSql(entry.table, index));
      }
    });
    return await fill(executor);
  } finally {
    await executor.close();
  }
}

String _txnPath(BenchTxn t) => 'accounts/${t.accountId}/txns/${t.id}';

/// The per-document upsert SQL exactly as `putDocInTx` builds it today.
String _buildUpsertSqlString(RegistryEntry entry, String docPath) {
  final columnNames = [for (final column in entry.columnDdls) column.name];
  final columns = [
    'path',
    'id',
    ...entry.paramSqlNames,
    'data',
    ...columnNames,
  ];
  final placeholders = List.filled(columns.length, '?').join(', ');
  final updates = [
    'id',
    ...entry.paramSqlNames,
    'data',
    ...columnNames,
  ].map((name) => '$name = excluded.$name').join(', ');
  return 'INSERT INTO ${entry.table} (${columns.join(', ')}) '
      'VALUES ($placeholders) '
      'ON CONFLICT(path) DO UPDATE SET $updates';
}

/// The bound arguments of one upsert row, as `putDocInTx` binds them today.
List<Object?> _buildUpsertArgs(RegistryEntry entry, BenchTxn benchTxn) {
  final value = benchTxn.txn;
  final docPath = _txnPath(benchTxn);
  final columnValues = [
    for (final column in entry.fieldColumns) column.sqlOf(value),
  ];
  final patternSegments = entry.adapter.pattern.pattern.split('/');
  final pathSegments = docPath.split('/');
  final paramValues = [
    for (var i = 1; i < patternSegments.length; i += 2) pathSegments[i],
  ];
  return [
    docPath,
    benchTxn.id,
    ...paramValues,
    txns.encode(value),
    ...columnValues,
  ];
}

int _timeAll(List<BenchTxn> txns, Object? Function(BenchTxn) body) {
  final sw = Stopwatch()..start();
  for (final t in txns) {
    body(t);
  }
  sw.stop();
  return sw.elapsedMicroseconds;
}

SqliteSynchronous _synchronousOf(Durability durability) => switch (durability) {
  Durability.full => SqliteSynchronous.full,
  Durability.normal => SqliteSynchronous.normal,
};

void _report({
  required int size,
  required Durability durability,
  required int importMs,
  required _ProfiledExecutor profiler,
  required int encodeUs,
  required int normalizeUs,
  required int sqlBuildUs,
  required int changeRowUs,
}) {
  final perDoc = importMs * 1000 / size;
  String ms(int us) => (us / 1000).toStringAsFixed(0);
  String share(int us) => (us / 1000 / importMs * 100).toStringAsFixed(1);

  stdout.writeln(
    '== Cocoon import profile: $size txns '
    '(Durability.${durability.name}) ==',
  );
  stdout.writeln(
    'total import wall: $importMs ms '
    '(${perDoc.toStringAsFixed(1)} us/doc, ${(size / (importMs / 1000)).round()} docs/s)',
  );
  stdout.writeln('');
  stdout.writeln('SQL round trips while importing:');
  stdout.writeln(
    '  execute:          ${profiler.executeCount} calls, '
    '${profiler.executeWait.inMilliseconds} ms wait',
  );
  stdout.writeln(
    '  executeBatch:     ${profiler.batchCount} calls, '
    '${profiler.batchWait.inMilliseconds} ms wait',
  );
  for (final entry in profiler.batchBySql.entries) {
    final (count, wait) = entry.value;
    stdout.writeln(
      '    ${entry.key.padRight(18)} $count calls, ${wait.inMilliseconds} ms wait',
    );
  }
  for (final entry in profiler.executeBySql.entries) {
    final (count, wait) = entry.value;
    stdout.writeln(
      '    ${entry.key.padRight(18)} $count calls, ${wait.inMilliseconds} ms wait',
    );
  }
  stdout.writeln(
    '  reads:            ${profiler.readCount} calls, '
    '${profiler.readWait.inMilliseconds} ms wait',
  );
  stdout.writeln('');
  stdout.writeln('Dart-side costs (measured over the same dataset):');
  stdout.writeln(
    '  adapter.encode:           ${ms(encodeUs)} ms (${share(encodeUs)}%)',
  );
  stdout.writeln(
    '  encode->decode normalize: ${ms(normalizeUs)} ms (${share(normalizeUs)}%)',
  );
  stdout.writeln(
    '  SQL string building:      ${ms(sqlBuildUs)} ms (${share(sqlBuildUs)}%)'
    ' — the pre-step-11 per-document shape, shown for reference',
  );
  stdout.writeln(
    '  change-row building:      ${ms(changeRowUs)} ms (${share(changeRowUs)}%)',
  );
  final accounted =
      profiler.sqlWaitMs * 1000 +
      encodeUs +
      normalizeUs +
      sqlBuildUs +
      changeRowUs;
  final unaccounted = importMs * 1000 - accounted;
  stdout.writeln(
    '  unaccounted:              ${ms(unaccounted)} ms '
    '(${share(unaccounted)}%) — cache staging, refs, event loop',
  );
  stdout.writeln('');
  stdout.writeln(
    'Run --mode ceiling in a separate process for the SQLite ceiling.',
  );
}

final class _ProfiledExecutor implements CocoonExecutor {
  _ProfiledExecutor(this._inner);

  final CocoonExecutor _inner;

  var executeCount = 0;
  var batchCount = 0;
  var readCount = 0;
  Duration executeWait = Duration.zero;
  Duration batchWait = Duration.zero;
  Duration readWait = Duration.zero;
  final executeBySql = <String, (int, Duration)>{};
  final batchBySql = <String, (int, Duration)>{};

  /// Total wait time across every SQL call, in milliseconds.
  int get sqlWaitMs => (executeWait + batchWait + readWait).inMilliseconds;

  void reset() {
    executeCount = 0;
    batchCount = 0;
    readCount = 0;
    executeWait = Duration.zero;
    batchWait = Duration.zero;
    readWait = Duration.zero;
    executeBySql.clear();
    batchBySql.clear();
  }

  String _classify(String sql) {
    if (sql.contains('_cocoon_changes')) {
      return 'changes';
    }
    if (sql.contains('ON CONFLICT')) {
      return 'upsert';
    }
    if (sql.startsWith('DELETE') || sql.startsWith('delete')) {
      return 'delete';
    }
    return 'other';
  }

  void _record(Map<String, (int, Duration)> into, String sql, Duration wait) {
    final key = _classify(sql);
    final (count, total) = into[key] ?? (0, Duration.zero);
    into[key] = (count + 1, total + wait);
  }

  Future<List<Map<String, Object?>>> _timeRead(
    Future<List<Map<String, Object?>>> Function() run,
  ) async {
    readCount++;
    final sw = Stopwatch()..start();
    try {
      return await run();
    } finally {
      readWait += sw.elapsed;
    }
  }

  Future<Map<String, Object?>?> _timeReadOne(
    Future<Map<String, Object?>?> Function() run,
  ) async {
    readCount++;
    final sw = Stopwatch()..start();
    try {
      return await run();
    } finally {
      readWait += sw.elapsed;
    }
  }

  Future<void> _timeExecute(String sql, Future<void> Function() run) async {
    executeCount++;
    final sw = Stopwatch()..start();
    try {
      return await run();
    } finally {
      executeWait += sw.elapsed;
      _record(executeBySql, sql, sw.elapsed);
    }
  }

  Future<void> _timeBatch(String sql, Future<void> Function() run) async {
    batchCount++;
    final sw = Stopwatch()..start();
    try {
      return await run();
    } finally {
      batchWait += sw.elapsed;
      _record(batchBySql, sql, sw.elapsed);
    }
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) => _timeRead(() => _inner.getAll(sql, args));

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) => _timeReadOne(() => _inner.getOptional(sql, args));

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) =>
      _timeExecute(sql, () => _inner.execute(sql, args));

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _timeBatch(sql, () => _inner.executeBatch(sql, parameterSets));

  @override
  Future<T> writeTransaction<T>(Future<T> Function(CocoonTx tx) body) =>
      _inner.writeTransaction<T>((tx) => body(_ProfiledTx(this, tx)));

  @override
  Future<T> readTransaction<T>(Future<T> Function(CocoonRead tx) body) =>
      _inner.readTransaction<T>((tx) => body(_ProfiledRead(this, tx)));

  @override
  Future<void> close() => _inner.close();
}

final class _ProfiledTx implements CocoonTx {
  _ProfiledTx(this._outer, this._inner);

  final _ProfiledExecutor _outer;
  final CocoonTx _inner;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) => _outer._timeRead(() => _inner.getAll(sql, args));

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) => _outer._timeReadOne(() => _inner.getOptional(sql, args));

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) =>
      _outer._timeExecute(sql, () => _inner.execute(sql, args));

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _outer._timeBatch(sql, () => _inner.executeBatch(sql, parameterSets));
}

final class _ProfiledRead implements CocoonRead {
  _ProfiledRead(this._outer, this._inner);

  final _ProfiledExecutor _outer;
  final CocoonRead _inner;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) => _outer._timeRead(() => _inner.getAll(sql, args));

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) => _outer._timeReadOne(() => _inner.getOptional(sql, args));
}
