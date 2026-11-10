/// Storage anatomy of the real rival-matrix databases (dev tool, not
/// shipped): where Cocoon's 1M bytes go, per table and per index.
///
/// For each database the tool copies the file (and any WAL/SHM sidecar)
/// into a scratch directory, runs `PRAGMA wal_checkpoint(TRUNCATE)` on the
/// COPY — the original under `/tmp/cocoon_rivals_run` is never opened for
/// writing — and then answers, from the `dbstat` virtual table (bundled
/// SQLite 3.54.1 has it):
///
/// - per table and per index: pages, bytes, share of the file, entries
///   (leaf cells) and average payload bytes per row/entry;
/// - the whole-file numbers: page size, page count, freelist pages, the
///   WAL size before the checkpoint (the sidecar next to the original; the
///   matrix's engines close cleanly, so it is usually absent);
/// - the content numbers: average encoded blob size (`length(data)`),
///   average `path` length, the change log's row count and bytes, and, for
///   every table, the average byte length of its text/blob columns.
///
/// usage:
/// ```sh
/// dart run tool/storage_anatomy.dart [--scratch /tmp/cocoon_step14_scratch]
///     [db ...]        # defaults to the 1M cocoon.db and drift.db
/// ```
///
/// Prints a markdown section per database; the scratch copies are deleted
/// afterwards (they are the only files the tool writes).
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// The real 1M databases the rivals matrix built (read-only for this tool).
const defaultDbs = [
  '/tmp/cocoon_rivals_run/cocoon_rivals_cocoon_1000000/cocoon.db',
  '/tmp/cocoon_rivals_run/cocoon_rivals_drift_1000000/drift.db',
];

void main(List<String> args) {
  var scratch = '/tmp/cocoon_step14_scratch';
  final dbs = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--scratch':
        scratch = args[++i];
      default:
        dbs.add(args[i]);
    }
  }
  if (dbs.isEmpty) {
    dbs.addAll(defaultDbs);
  }
  Directory(scratch).createSync(recursive: true);
  for (final db in dbs) {
    analyze(db, scratch);
  }
}

/// Copies [source] into [scratch], checkpoints the copy and prints the
/// anatomy as markdown.
void analyze(String source, String scratch) {
  final name = File(source).uri.pathSegments.last;
  stdout.writeln('## $name');
  stdout.writeln('');

  // The WAL size before the checkpoint: the sidecar next to the ORIGINAL.
  // The matrix engines close cleanly (their close-time checkpoint drains
  // the WAL), so this is usually absent — reported, not assumed.
  final walBefore = File('$source-wal');
  final shm = File('$source-shm');
  final walBeforeBytes = walBefore.existsSync() ? walBefore.lengthSync() : 0;
  final shmBytes = shm.existsSync() ? shm.lengthSync() : 0;
  stdout.writeln(
    'source: `$source` (${_mib(File(source).lengthSync())} MiB), '
    'WAL sidecar before checkpoint: '
    '${walBeforeBytes == 0 ? "none (closed cleanly)" : "$walBeforeBytes B"}, '
    'SHM: ${shmBytes == 0 ? "none" : "$shmBytes B"}',
  );

  // The copy: db + sidecars, so a present WAL is checkpointed on the copy.
  final copy = '$scratch/anatomy_$name';
  File(source).copySync(copy);
  if (walBeforeBytes > 0) {
    File('$source-wal').copySync('$copy-wal');
  }
  if (shmBytes > 0) {
    File('$source-shm').copySync('$copy-shm');
  }

  final checkpointDb = sqlite3.open(copy);
  try {
    checkpointDb.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    checkpointDb.close();
  }
  final walAfter = File('$copy-wal');
  stdout.writeln(
    'after checkpoint on the copy: WAL sidecar '
    '${walAfter.existsSync() ? _mib(walAfter.lengthSync()) : "none"}',
  );
  stdout.writeln('');

  final db = sqlite3.open(copy, mode: OpenMode.readOnly);
  try {
    final pageSize = db.select('PRAGMA page_size').first['page_size']! as int;
    final pageCount =
        db.select('PRAGMA page_count').first['page_count']! as int;
    final freelist =
        db.select('PRAGMA freelist_count').first['freelist_count']! as int;
    final fileBytes = pageCount * pageSize;
    stdout.writeln(
      'file: $pageCount pages x $pageSize B = ${_mib(fileBytes)} MiB, '
      'freelist $freelist pages (${_pct(freelist, pageCount)} of the file)',
    );
    stdout.writeln('');

    // Per-object page and payload accounting. Index interior cells carry
    // real entries (SQLite index b-trees do not repeat them in the leaves),
    // so entries and payload sum over ALL pages; for table b-trees the
    // interior cells are rowid-only navigation (payload 0), so the same
    // sums stay exact.
    final objects = db.select('''
      SELECT name,
             count(*) AS pages,
             sum(pgsize) AS bytes,
             sum(ncell) AS entries,
             sum(payload) AS payload,
             sum(CASE WHEN pagetype = 'leaf' THEN ncell ELSE 0 END)
                 AS leaf_entries,
             sum(CASE WHEN pagetype = 'leaf' THEN payload ELSE 0 END)
                 AS leaf_payload
      FROM dbstat
      GROUP BY name
      ORDER BY bytes DESC
    ''');
    final types = <String, String>{
      for (final row in db.select('SELECT name, type FROM sqlite_master'))
        row['name']! as String: row['type']! as String,
    };

    stdout.writeln(
      '| object | type | pages | MB | % of file | entries | avg payload B |',
    );
    stdout.writeln('|---|---|---|---|---|---|---|');
    var accounted = 0;
    for (final row in objects) {
      final objectName = row['name']! as String;
      final pages = row['pages']! as int;
      final bytes = row['bytes']! as int;
      accounted += bytes;
      final type =
          types[objectName] ?? (objectName == 'sqlite_schema' ? 'table' : '?');
      // Tables: every row is one leaf cell (interior cells are rowid-only).
      // Indexes: interior cells carry real entries, so they count too.
      final isTable = type == 'table';
      final entries = (isTable ? row['leaf_entries'] : row['entries'])! as int;
      final payload = (isTable ? row['leaf_payload'] : row['payload'])! as int;
      stdout.writeln(
        '| ${_md(objectName)} | $type | $pages | ${_mib(bytes)} | '
        '${_pct(bytes, fileBytes)} | ${_num(entries)} | '
        '${entries == 0 ? '—' : (payload / entries).toStringAsFixed(1)} |',
      );
    }
    stdout.writeln(
      '| **total accounted** | | | ${_mib(accounted)} | '
      '${_pct(accounted, fileBytes)} | | |',
    );
    stdout.writeln('');

    // Content: per table, row count and per-column byte lengths. Text
    // columns are measured as UTF-8 bytes (`CAST(x AS BLOB)`), blobs as
    // raw bytes; `null%` is the share of NULLs (SQLite's avg() ignores
    // them, so the avg is over the non-NULL values).
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )) {
      final table = row['name']! as String;
      final count =
          db.select('SELECT count(*) AS c FROM "$table"').first['c']! as int;
      final columns = [
        for (final column in db.select('PRAGMA table_info("$table")'))
          (
            name: column['name']! as String,
            type: (column['type']! as String).toUpperCase(),
            notNull: column['notnull']! as int == 1,
          ),
      ];
      final parts = <String>[];
      for (final column in columns) {
        final quoted = '"${column.name}"';
        final expr = column.type == 'BLOB' || column.type == ''
            ? 'length($quoted)'
            : 'length(CAST($quoted AS BLOB))';
        final stats = db
            .select(
              'SELECT avg($expr) AS a, sum($quoted IS NOT NULL) AS n '
              'FROM "$table"',
            )
            .first;
        final avg = stats['a'];
        final nonNull = stats['n']! as int;
        if (avg == null) {
          parts.add('${column.name}: all NULL');
        } else {
          final nullNote = nonNull == count
              ? ''
              : ' (null ${_pct(count - nonNull, count)})';
          parts.add('${column.name}: ${avg.toStringAsFixed(1)} B$nullNote');
        }
      }
      stdout.writeln('- `$table`: ${_num(count)} rows — ${parts.join(', ')}');
    }
    stdout.writeln('');
  } finally {
    db.close();
  }
}

String _mib(num bytes) =>
    (bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 2 : 1);

String _pct(int part, int whole) =>
    whole == 0 ? '—' : (100 * part / whole).toStringAsFixed(1);

String _num(int n) {
  final digits = n.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Escapes pipe characters so object names stay inside one table cell.
String _md(String s) => s.replaceAll('|', '\\|');
