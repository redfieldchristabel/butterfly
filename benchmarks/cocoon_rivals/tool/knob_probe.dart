// The 1M-scale commit-cost knob probe behind the "1M knobs, isolated" table
// in IMPORT.md: is the per-chunk superlinearity the page cache or the WAL
// checkpoint churn? Fresh db per configuration.
//
// usage: dart run tool/knob_probe.dart <chunks|single> [pragma] [pragma]
import 'dart:io';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart' as raw;

final rng = math.Random(7);

List<List<Object?>> chunkRows(int start, int n) => [
  for (var i = 0; i < n; i++)
    [
      'accounts/a${((start + i) % 20).toString().padLeft(2, '0')}/txns/'
          't${(start + i).toString().padLeft(9, '0')}',
      't${(start + i).toString().padLeft(9, '0')}',
      'a${((start + i) % 20).toString().padLeft(2, '0')}',
      List<int>.generate(480, (b) => rng.nextInt(256)),
      20240601 + rng.nextInt(28),
      'posted',
    ],
];

void main(List<String> args) {
  final mode = args[0]; // chunks | single
  final size = 1000000;
  final dir = Directory.systemTemp.createTempSync('cocoon_1m_probe_');
  try {
    final path = '${dir.path}/probe.db';
    final db = raw.sqlite3.open(path);
    db.execute('PRAGMA journal_mode = wal');
    db.execute('PRAGMA synchronous = FULL');
    db.execute('PRAGMA journal_size_limit = 6291456');
    if (args.length > 1) {
      db.execute(args[1]); // e.g. 'PRAGMA cache_size = -65536'
    }
    if (args.length > 2) {
      db.execute(args[2]); // e.g. 'PRAGMA wal_autocheckpoint = 0'
    }
    db.execute('''
      CREATE TABLE txn (
        path TEXT NOT NULL UNIQUE,
        id TEXT NOT NULL,
        p_account_id TEXT NOT NULL,
        data BLOB NOT NULL,
        f_booked_on INTEGER NOT NULL,
        f_status TEXT NOT NULL
      )
    ''');
    db.execute(
      'CREATE UNIQUE INDEX cx_txn_scope ON txn (p_account_id ASC, id ASC)',
    );
    db.execute(
      'CREATE INDEX cx_txn_1 ON txn (p_account_id ASC, f_booked_on DESC)',
    );
    db.execute(
      'CREATE INDEX cx_txn_2 ON txn (f_status ASC, f_booked_on ASC)',
    );
    db.execute('CREATE INDEX cx_txn_3 ON txn (f_booked_on ASC)');
    final upsert = 'INSERT INTO txn (path, id, p_account_id, data, '
        'f_booked_on, f_status) VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(path) DO UPDATE SET id = excluded.id, '
        'p_account_id = excluded.p_account_id, data = excluded.data, '
        'f_booked_on = excluded.f_booked_on, f_status = excluded.f_status';
    final stmt = db.prepare(upsert);

    final sw = Stopwatch()..start();
    if (mode == 'chunks') {
      for (var c = 0; c < size ~/ 1000; c++) {
        db.execute('BEGIN IMMEDIATE');
        for (final row in chunkRows(c * 1000, 1000)) {
          stmt.execute(row);
        }
        db.execute('COMMIT');
      }
    } else {
      db.execute('BEGIN IMMEDIATE');
      for (var c = 0; c < size ~/ 1000; c++) {
        for (final row in chunkRows(c * 1000, 1000)) {
          stmt.execute(row);
        }
      }
      db.execute('COMMIT');
    }
    sw.stop();
    final wal = File('$path-wal').lengthSync();
    final dbf = File(path).lengthSync();
    stdout.writeln(
      '[$mode ${args.length > 1 ? args[1] : ''} '
      '${args.length > 2 ? args[2] : ''}] ${sw.elapsedMilliseconds} ms, '
      'db ${(dbf / 1048576).round()} MB, wal ${(wal / 1048576).round()} MB',
    );
    stmt.close();
    db.close();
  } finally {
    dir.deleteSync(recursive: true);
  }
}
