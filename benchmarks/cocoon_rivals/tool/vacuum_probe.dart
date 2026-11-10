/// One-shot step-20 probe: migrate a fresh copy of the old-format 1M rivals
/// file, then measure what the freelist holds and what a VACUUM (the same
/// compaction `backupTo` performs) reclaims. Prints JSON; deletes its copy.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/models.dart' show accounts, txns;
import 'package:sqlite3/sqlite3.dart' as raw;

Future<void> main() async {
  const oldOriginal =
      '/tmp/cocoon_rivals_run/cocoon_rivals_cocoon_1000000/cocoon.db';
  final scratch = Directory.systemTemp.createTempSync('cocoon_vacuum_');
  try {
    final copy = '${scratch.path}${Platform.pathSeparator}m.db';
    File(oldOriginal).copySync(copy);
    final sw = Stopwatch()..start();
    final db = await Cocoon.open(copy, collections: [accounts, txns]);
    final migrationMs = sw.elapsedMilliseconds;
    await db.close();
    final rawDb = raw.sqlite3.open(copy);
    final freePages =
        rawDb.select('PRAGMA freelist_count').first['freelist_count']! as int;
    final pageSize =
        rawDb.select('PRAGMA page_size').first['page_size']! as int;
    rawDb.close();
    final before = File(copy).lengthSync();
    final vacuum = raw.sqlite3.open(copy);
    final vacuumWatch = Stopwatch()..start();
    vacuum.execute('VACUUM');
    vacuumWatch.stop();
    vacuum.close();
    final after = File(copy).lengthSync();
    stdout.writeln(
      jsonEncode({
        'migrationMs': migrationMs,
        'migratedBytes': before,
        'freelistMB': (freePages * pageSize) / (1024 * 1024),
        'vacuumMs': vacuumWatch.elapsedMilliseconds,
        'vacuumedBytes': after,
      }),
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
