/// Measures `db.getAll(refs)` against the 1M rivals dataset — the numbers in
/// `GETALL.md`. Separate from the harness's `gets` op (which stays
/// untouched): this tool re-uses its id sample and adds the many-by-id
/// shapes.
///
/// Shapes, per rep (each rep on a FRESH Cocoon instance, so the cold numbers
/// really are cache-cold — the step-20 lesson):
///
/// - `getAllColdMs`   first `db.getAll(refs)` on a fresh instance (empty
///                    cache; misses fetched in chunks of 500 scope keys
///                    inside one read transaction).
/// - `getAllWarmMs`   the second `db.getAll(refs)` on the same instance.
/// - `getsOneByOneMs` the rivals `gets` op itself: 1,000 individual
///                    `doc.get()` calls on a fresh instance (the number the
///                    existing RESULTS.md table carries), measured on the
///                    same machine for the same session.
/// - `getAllSqlOnlyMs` the same chunked statements `getAll` runs, executed
///                    on a raw probe connection with the rows discarded —
///                    the round-trip + SQL floor without any decoding.
/// - `getAllOneStatementMs` one chunk statement fetching 500 keys inside a
///                    read transaction — the fixed per-call cost (BEGIN/END
///                    hops) plus one chunk.
/// - `decodeMs`       decoding every fetched document's wire bytes once.
///
/// The ids are the `gets` workload's ids: the harness's seeded reservoir
/// sample (`Random(424242)`) over the dataset's deterministic id universe
/// (`t<9 digits>`, account = index % 20), streamed in Cocoon's table order
/// (account by account, id ascending). The current 1M databases additionally
/// carry a few `w`-id rows left by the read-while-write op; the universe
/// excludes them, so the sample is reproducible against any fresh import,
/// and every measured id is checked to exist before anything is reported.
///
/// usage:
///   dart run tool/getall_measure.dart --size 1000000 --count 1000
///   dart run tool/getall_measure.dart --chunk-sweep --count 1000
///   dart run tool/getall_measure.dart --engine drift --count 1000
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/drift_models.dart';
import 'package:cocoon_rivals/engine.dart';
import 'package:cocoon_rivals/harness.dart' show sampleSeed;
import 'package:cocoon_rivals/models.dart';

/// The database location every measurement must use (the same pin
/// tool/lib.sh applies; never the agent runtime's TMPDIR).
const tmpRoot = '/tmp/cocoon_rivals_run';

/// The chunk sizes the sweep measures against the shipped 500.
const sweepChunkSizes = [50, 100, 250, 500, 1000, 2000, 4000];

/// The engine's `getAll` chunk size (the shipped constant).
const getAllChunkKeys = 500;

typedef Id = ({String accountId, String id});

Future<void> main(List<String> arguments) async {
  final parsed = <String, String>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--')) {
      throw ArgumentError.value(argument, 'argument', 'Unknown flag');
    }
    final equals = argument.indexOf('=');
    if (equals >= 0) {
      parsed[argument.substring(2, equals)] = argument.substring(equals + 1);
      continue;
    }
    if (i + 1 >= arguments.length || arguments[i + 1].startsWith('--')) {
      parsed[argument.substring(2)] = '';
    } else {
      parsed[argument.substring(2)] = arguments[++i];
    }
  }
  var size = int.tryParse(parsed['size'] ?? '') ?? 1000000;
  var count = int.tryParse(parsed['count'] ?? '') ?? 1000;
  var reps = int.tryParse(parsed['reps'] ?? '') ?? 5;
  var chunkSweep = parsed.containsKey('chunk-sweep');
  var engine = (parsed['engine'] ?? '').isEmpty ? 'cocoon' : parsed['engine']!;

  final ids = await getsWorkloadIds(size, count);
  if (ids.length != count) {
    throw StateError('sample produced ${ids.length} of $count ids');
  }
  stdout.writeln('# engine=$engine size=$size ids=${ids.length} reps=$reps');

  if (chunkSweep) {
    await _chunkSweep(size, ids, reps);
    return;
  }
  if (engine == 'drift') {
    await _measureDrift(size, ids, reps);
  } else {
    await _measureCocoon(size, ids, reps);
  }
}

/// The (accountId, id) pairs the rivals `gets` op reads at [size], computed
/// from the dataset's deterministic ids and the harness's seeded reservoir
/// sample over the documents in per-account id order (Cocoon's table walk).
Future<List<Id>> getsWorkloadIds(int size, int count) async {
  final sampled = await reservoirSample(
    count,
    Random(sampleSeed),
    () => _workloadStream(size),
  );
  return [for (final doc in sampled) (accountId: doc.accountId, id: doc.id)];
}

/// Every document id in the dataset, in the order Cocoon's tables walk it
/// (account by account, id ascending) — exactly what the harness's cocoon
/// `sampleDocs` streams.
Stream<({String accountId, String id, Object? value})> _workloadStream(
  int size,
) async* {
  for (final accountId in benchAccountIds()) {
    final k = int.parse(accountId.substring(1));
    for (var i = k; i < size; i += accountCount) {
      yield (
        accountId: accountId,
        id: 't${i.toString().padLeft(9, '0')}',
        value: null,
      );
    }
  }
}

Future<Cocoon> _openCocoon(int size) => Cocoon.open(
  '$tmpRoot/cocoon_rivals_cocoon-normal_$size/cocoon.db',
  collections: [accounts, txns],
  options: const CocoonOptions(durability: Durability.normal),
);

/// A raw read-only probe connection on the same file for the executor-level
/// floors (SQL + round trips without Cocoon's decode or cache).
Future<SqliteDatabase> _openProbe(int size) async {
  final db = SqliteDatabase(
    path: '$tmpRoot/cocoon_rivals_cocoon-normal_$size/cocoon.db',
  );
  await db.initialize();
  return db;
}

DocRef<Txn> _txnRef(Cocoon db, Id id) =>
    db.collection(accounts).doc(id.accountId).collection(txns).doc(id.id);

Future<void> _measureCocoon(int size, List<Id> ids, int reps) async {
  final cold = <double>[];
  final warm = <double>[];
  final oneByOne = <double>[];
  final sqlOnly = <double>[];
  final oneStatement = <double>[];
  final decode = <double>[];

  final probe = await _openProbe(size);
  try {
    for (var rep = 0; rep < reps; rep++) {
      // Fresh instance 1: getAll cold (empty cache), then warm on the same
      // instance, then the executor-level floors over the probe connection.
      final db = await _openCocoon(size);
      try {
        final refs = [for (final id in ids) _txnRef(db, id)];

        var sw = Stopwatch()..start();
        final snaps = await db.getAll(refs);
        sw.stop();
        _expectAllFound(snaps, ids.length);
        cold.add(_ms(sw));

        sw = Stopwatch()..start();
        await db.getAll(refs);
        sw.stop();
        warm.add(_ms(sw));

        await _sqlOnly(probe, ids, sqlOnly, oneStatement);
        await _decodeOnly(probe, ids, decode);
      } finally {
        await db.close();
      }

      // Fresh instance 2: the rivals `gets` op, cold cache, exactly as the
      // harness runs it (one doc.get() per id).
      final fresh = await _openCocoon(size);
      try {
        final sw = Stopwatch()..start();
        var hits = 0;
        for (final id in ids) {
          if (await _txnRef(fresh, id).get() != null) {
            hits++;
          }
        }
        sw.stop();
        if (hits != ids.length) {
          throw StateError('gets: found $hits of ${ids.length}');
        }
        oneByOne.add(_ms(sw));
      } finally {
        await fresh.close();
      }
    }
  } finally {
    await probe.close();
  }

  _report('cocoon getAll', size, ids.length, {
    'getAllColdMs': _medianMs(cold),
    'getAllWarmMs': _medianMs(warm),
    'getsOneByOneMs': _medianMs(oneByOne),
    'getAllSqlOnlyMs': _medianMs(sqlOnly),
    'getAllOneStatementMs': _medianMs(oneStatement),
    'decodeMs': _medianMs(decode),
    'getAllColdRunsMs': cold,
    'getAllWarmRunsMs': warm,
    'getsOneByOneRunsMs': oneByOne,
  });
}

/// Times `getAll`'s own statements (chunked by [getAllChunkKeys], rows
/// discarded) and one single 500-key chunk — the round-trip + SQL floor
/// without decoding, and the fixed per-call cost with one chunk.
Future<void> _sqlOnly(
  SqliteDatabase probe,
  List<Id> ids,
  List<double> sqlOnly,
  List<double> oneStatement,
) async {
  var sw = Stopwatch()..start();
  await probe.readTransaction((reader) async {
    for (var start = 0; start < ids.length; start += getAllChunkKeys) {
      final chunk = ids.sublist(
        start,
        start + getAllChunkKeys > ids.length
            ? ids.length
            : start + getAllChunkKeys,
      );
      await reader.getAll(
        'SELECT p_account_id, id, data FROM txn WHERE (p_account_id, id) IN '
        '(VALUES ${List.filled(chunk.length, '(?, ?)').join(', ')})',
        [
          for (final id in chunk) ...[id.accountId, id.id],
        ],
      );
    }
  });
  sw.stop();
  sqlOnly.add(_ms(sw));

  // One chunk statement alone (500 keys), inside its own read transaction:
  // the BEGIN/END hops plus one statement.
  sw = Stopwatch()..start();
  await probe.readTransaction((reader) async {
    final chunk = ids.take(getAllChunkKeys).toList();
    await reader.getAll(
      'SELECT p_account_id, id, data FROM txn WHERE (p_account_id, id) IN '
      '(VALUES ${List.filled(chunk.length, '(?, ?)').join(', ')})',
      [
        for (final id in chunk) ...[id.accountId, id.id],
      ],
    );
  });
  sw.stop();
  oneStatement.add(_ms(sw));
}

/// Fetches the rows untimed, then times decoding every document once — the
/// decode floor of the same [ids].
Future<void> _decodeOnly(
  SqliteDatabase probe,
  List<Id> ids,
  List<double> decode,
) async {
  final rows = await probe.readTransaction((reader) async {
    final all = <Map<String, Object?>>[];
    for (var start = 0; start < ids.length; start += getAllChunkKeys) {
      final chunk = ids.sublist(
        start,
        start + getAllChunkKeys > ids.length
            ? ids.length
            : start + getAllChunkKeys,
      );
      all.addAll(
        await reader.getAll(
          'SELECT p_account_id, id, data FROM txn WHERE (p_account_id, id) IN '
          '(VALUES ${List.filled(chunk.length, '(?, ?)').join(', ')})',
          [
            for (final id in chunk) ...[id.accountId, id.id],
          ],
        ),
      );
    }
    return all;
  });
  if (rows.length != ids.length) {
    throw StateError('decode sample: ${rows.length} of ${ids.length}');
  }
  final blobs = [for (final row in rows) row['data']! as Uint8List];
  final sw = Stopwatch()..start();
  for (final bytes in blobs) {
    txns.decode(bytes);
  }
  sw.stop();
  decode.add(_ms(sw));
}

/// The drift reference: the same ids through drift's `isIn`, both as one
/// statement (its best single query) and chunked at 500 (the same statement
/// count as `getAll`'s).
Future<void> _measureDrift(int size, List<Id> ids, int reps) async {
  final db = AppDb(
    NativeDatabase.createInBackground(
      File('$tmpRoot/cocoon_rivals_drift_$size/drift.db'),
    ),
  );
  final single = <double>[];
  final chunked = <double>[];
  try {
    for (var rep = 0; rep < reps; rep++) {
      var sw = Stopwatch()..start();
      final rows = await (db.select(
        db.txnRows,
      )..where((t) => t.id.isIn([for (final id in ids) id.id]))).get();
      sw.stop();
      if (rows.length != ids.length) {
        throw StateError('drift isIn: ${rows.length} of ${ids.length}');
      }
      single.add(_ms(sw));

      sw = Stopwatch()..start();
      for (var start = 0; start < ids.length; start += getAllChunkKeys) {
        final chunk = ids.sublist(
          start,
          start + getAllChunkKeys > ids.length
              ? ids.length
              : start + getAllChunkKeys,
        );
        await (db.select(
          db.txnRows,
        )..where((t) => t.id.isIn([for (final id in chunk) id.id]))).get();
      }
      sw.stop();
      chunked.add(_ms(sw));
    }
  } finally {
    await db.close();
  }

  _report('drift isIn', size, ids.length, {
    'oneStatementMs': _medianMs(single),
    'chunked500Ms': _medianMs(chunked),
    'oneStatementRunsMs': single,
    'chunked500RunsMs': chunked,
  });
}

/// Statement-size sweep at probe level (rows discarded): what one
/// getAll-style statement costs as its key count grows. Informs the shipped
/// [getAllChunkKeys].
Future<void> _chunkSweep(int size, List<Id> ids, int reps) async {
  final probe = await _openProbe(size);
  try {
    for (final chunkSize in sweepChunkSizes) {
      final runs = <double>[];
      for (var rep = 0; rep < reps; rep++) {
        final sw = Stopwatch()..start();
        await probe.readTransaction((reader) async {
          for (var start = 0; start < ids.length; start += chunkSize) {
            final chunk = ids.sublist(
              start,
              start + chunkSize > ids.length ? ids.length : start + chunkSize,
            );
            await reader.getAll(
              'SELECT p_account_id, id, data FROM txn WHERE '
              '(p_account_id, id) IN '
              '(VALUES ${List.filled(chunk.length, '(?, ?)').join(', ')})',
              [
                for (final id in chunk) ...[id.accountId, id.id],
              ],
            );
          }
        });
        sw.stop();
        runs.add(_ms(sw));
      }
      stdout.writeln(
        'chunk $chunkSize: median ${_medianMs(runs).toStringAsFixed(2)} ms '
        '(${ids.length ~/ chunkSize + 1} statements, runs '
        '${[for (final r in runs) r.toStringAsFixed(2)]})',
      );
    }
  } finally {
    await probe.close();
  }
}

double _ms(Stopwatch sw) => sw.elapsedMicroseconds / 1000;

double _medianMs(List<double> values) {
  if (values.isEmpty) {
    throw StateError('no measurements');
  }
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

void _expectAllFound(List<DocSnapshot<Object>?> snaps, int count) {
  final found = snaps.where((snap) => snap != null).length;
  if (found != count) {
    throw StateError('getAll: found $found of $count documents');
  }
}

void _report(String engine, int size, int count, Map<String, Object?> metrics) {
  stdout.writeln(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'engine': engine, 'size': size, 'count': count, ...metrics}),
  );
}
