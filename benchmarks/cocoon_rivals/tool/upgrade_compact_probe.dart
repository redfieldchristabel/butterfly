/// One-shot step-23 probe: what a storage-format upgrade leaves on the
/// freelist and what the post-upgrade compaction (`CocoonOptions.compactAfterUpgrade`)
/// reclaims, on a fresh copy of the old-format 1M rivals file and on a small
/// file. Prints JSON; deletes its copies. The originals are never opened for
/// writing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/models.dart'
    show Account, Txn, TxnStatus, accounts, txns;
import 'package:sqlite3/sqlite3.dart' as raw;

const oldOriginal =
    '/tmp/cocoon_rivals_run/cocoon_rivals_cocoon_1000000/cocoon.db';

Future<void> main() async {
  final scratch = Directory.systemTemp.createTempSync('cocoon_compact_');
  try {
    // -- 1M, upgraded WITHOUT compaction: what the file looks like right
    // after the format migration, before anything reclaims the freelist.
    final manualCopy = '${scratch.path}${Platform.pathSeparator}manual.db';
    File(oldOriginal).copySync(manualCopy);
    final upgradeWatch = Stopwatch()..start();
    final db = await Cocoon.open(
      manualCopy,
      collections: [accounts, txns],
      options: const CocoonOptions(compactAfterUpgrade: false),
    );
    final upgradeMs = upgradeWatch.elapsedMilliseconds;
    await db.close();
    final upgradedBytes = File(manualCopy).lengthSync();
    final freelist = _freelist(manualCopy);

    // The compaction the engine now runs after such an upgrade, timed.
    final vacuum = raw.sqlite3.open(manualCopy);
    final vacuumWatch = Stopwatch()..start();
    vacuum.execute('VACUUM');
    vacuumWatch.stop();
    vacuum.close();
    final vacuumedBytes = File(manualCopy).lengthSync();
    File(manualCopy).deleteSync();

    // -- 1M, the default open: upgrade + automatic compaction, end to end.
    final autoCopy = '${scratch.path}${Platform.pathSeparator}auto.db';
    File(oldOriginal).copySync(autoCopy);
    final autoWatch = Stopwatch()..start();
    final auto = await Cocoon.open(autoCopy, collections: [accounts, txns]);
    final autoOpenMs = autoWatch.elapsedMilliseconds;
    await auto.close();
    final autoBytes = File(autoCopy).lengthSync();
    final autoFreelist = _freelist(autoCopy);
    File(autoCopy).deleteSync();

    // -- small file: a fresh current-format file with one account and 400
    // txns, downgraded to the old layout by hand (path column back, format
    // row deleted), then the same default open.
    final smallPath = '${scratch.path}${Platform.pathSeparator}small.db';
    await _buildSmallFile(smallPath);
    final beforeSmall = File(smallPath).lengthSync();
    final smallFreelist = _freelist(smallPath);
    final smallWatch = Stopwatch()..start();
    final smallDb = await Cocoon.open(smallPath, collections: [accounts, txns]);
    final smallOpenMs = smallWatch.elapsedMilliseconds;
    final count = await smallDb
        .collection(accounts)
        .doc('a1')
        .collection(txns)
        .count();
    await smallDb.close();
    final afterSmall = File(smallPath).lengthSync();

    stdout.writeln(
      jsonEncode({
        'oneM': {
          'upgradeMs': upgradeMs,
          'upgradedBytes': upgradedBytes,
          'freelistMB': freelist.freeMB,
          'freelistShare': freelist.share,
          'vacuumMs': vacuumWatch.elapsedMilliseconds,
          'vacuumedBytes': vacuumedBytes,
          'autoOpenMs': autoOpenMs,
          'autoBytes': autoBytes,
          'autoFreelistShare': autoFreelist.share,
        },
        'small': {
          'beforeBytes': beforeSmall,
          'freelistShare': smallFreelist.share,
          'openMs': smallOpenMs,
          'docs': count,
          'afterBytes': afterSmall,
        },
      }),
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

({int freeMB, double share}) _freelist(String path) {
  final db = raw.sqlite3.open(path);
  try {
    final free =
        db.select('PRAGMA freelist_count').first['freelist_count']! as int;
    final pages = db.select('PRAGMA page_count').first['page_count']! as int;
    final pageSize = db.select('PRAGMA page_size').first['page_size']! as int;
    return (
      freeMB: (free * pageSize) ~/ (1024 * 1024),
      share: pages == 0 ? 0 : free / pages,
    );
  } finally {
    db.close();
  }
}

/// A current-format file with one account and 400 txns, downgraded to the
/// pre-step-20 layout by raw SQL (the `path` column back, filled from the
/// scope key; the format row deleted), so the next open sees an old file.
Future<void> _buildSmallFile(String path) async {
  final db = await Cocoon.open(path, collections: [accounts, txns]);
  final batch = db.batch();
  batch.set(
    db.collection(accounts).doc('a1'),
    Account(
      name: 'Acme',
      openedAt: DateTime.utc(2020),
      balanceMinor: 0,
      active: true,
    ),
  );
  for (var i = 0; i < 400; i++) {
    batch.set(
      db.collection(accounts).doc('a1').collection(txns).doc('t$i'),
      Txn(
        bookedOn: 20260101 + i,
        amountMinor: 100 + i,
        currency: 'MYR',
        status: TxnStatus.pending,
        memo: 'm' * 900,
      ),
    );
  }
  await batch.commit();
  await db.close();

  final rawDb = raw.sqlite3.open(path);
  try {
    final columns = rawDb
        .select('PRAGMA table_info(txn)')
        .map((row) => row['name']! as String)
        .where((name) => name != 'path')
        .toList();
    final collist = columns.join(', ');
    rawDb.execute('BEGIN');
    rawDb.execute(
      'CREATE TABLE old_txn ('
      'path TEXT NOT NULL UNIQUE, $collist'
      ')',
    );
    rawDb.execute(
      "INSERT INTO old_txn (path, $collist) SELECT 'accounts/' || "
      "p_account_id || '/txns/' || id, $collist FROM txn",
    );
    rawDb.execute('DROP TABLE txn');
    rawDb.execute('ALTER TABLE old_txn RENAME TO txn');
    rawDb.execute(
      'CREATE UNIQUE INDEX cx_txn_scope ON txn (p_account_id ASC, id ASC)',
    );
    rawDb.execute("DELETE FROM _cocoon_meta WHERE key = 'format_version'");
    rawDb.execute('COMMIT');
    rawDb.execute('VACUUM');
  } finally {
    rawDb.close();
  }
}
