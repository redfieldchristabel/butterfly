/// Step 16's measurement: `backupTo` and `restoreBackup` on the rivals
/// dataset, with single writes running concurrently with the backup.
///
/// One run at one size; scratch files live in `/tmp/cocoon_step16_scratch`
/// and are deleted again at the end (pass `--keep` to inspect them):
///
/// ```sh
/// cd benchmarks/cocoon_rivals
/// dart run tool/backup_measure.dart --size 1000000
/// ```
///
/// The flow is the app's own: build the rivals dataset, load it through
/// `db.bulkWriter()`, close and reopen (steady state), then time one
/// `backupTo` while single writes hammer one account (every write timed;
/// the percentiles cover exactly the writes that both started and finished
/// inside the backup's wall time), and time one `Cocoon.restoreBackup` onto
/// a fresh path. Nothing is averaged — the step asks for single runs.
library;

import 'dart:io';
import 'dart:math';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_rivals/dataset.dart';
import 'package:cocoon_rivals/models.dart';

/// The nearest-rank percentile of [sortedMicros] (ascending).
int _percentile(List<int> sortedMicros, double fraction) {
  if (sortedMicros.isEmpty) {
    return 0;
  }
  final rank = min(
    sortedMicros.length,
    max(1, (fraction * sortedMicros.length).ceil()),
  );
  return sortedMicros[rank - 1];
}

/// The size of `<path><suffix>` when it exists, else `0`.
int _sidecarBytes(String path, String suffix) {
  final file = File('$path$suffix');
  return file.existsSync() ? file.lengthSync() : 0;
}

Future<void> main(List<String> args) async {
  var size = 1000000;
  var dir = '/tmp/cocoon_step16_scratch';
  var keep = false;
  String? flag;
  for (final arg in args) {
    if (flag != null) {
      // The value of the previous --size/--dir flag (space-separated form).
      if (flag == '--size') {
        size = int.parse(arg);
      } else {
        dir = arg;
      }
      flag = null;
      continue;
    }
    if (arg == '--keep') {
      keep = true;
    } else if (arg == '--size' || arg == '--dir') {
      flag = arg;
    } else if (arg.startsWith('--size=')) {
      size = int.parse(arg.substring('--size='.length));
    } else if (arg.startsWith('--dir=')) {
      dir = arg.substring('--dir='.length);
    } else {
      stderr.writeln('unknown argument: $arg');
      exitCode = 2;
      return;
    }
  }

  final scratch = Directory(dir);
  if (scratch.existsSync()) {
    scratch.deleteSync(recursive: true);
  }
  scratch.createSync(recursive: true);

  final buildSw = Stopwatch()..start();
  final data = BenchDataset.build(txnCount: size);
  buildSw.stop();
  stdout.writeln(
    'dataset built: $size txns, ${buildSw.elapsed.inMilliseconds} ms',
  );

  final dbPath = '${scratch.path}/cocoon.db';
  var db = await Cocoon.open(dbPath, collections: [accounts, txns]);

  final importSw = Stopwatch()..start();
  final bulk = db.bulkWriter();
  for (var i = 0; i < data.accounts.length; i++) {
    bulk.set(
      db.collection(accounts).doc('a${i.toString().padLeft(2, '0')}'),
      data.accounts[i],
    );
  }
  for (var i = 0; i < data.txns.length; i++) {
    final benchTxn = data.txns[i];
    bulk.set(
      db
          .collection(accounts)
          .doc(benchTxn.accountId)
          .collection(txns)
          .doc(benchTxn.id),
      benchTxn.txn,
    );
    if (i % 100000 == 99999) {
      await bulk.flush(); // bound the queue; the writer would chunk anyway
    }
  }
  await bulk.close();
  importSw.stop();
  stdout.writeln('bulk import: ${importSw.elapsed.inMilliseconds} ms');

  // Steady state: close (which checkpoints the WAL away) and reopen, so the
  // backup measures a settled database, not a just-imported one.
  await db.close();
  db = await Cocoon.open(dbPath, collections: [accounts, txns]);
  final sourceInstanceId = db.instanceId;

  // Single writes hammering one account while the backup runs; every write
  // is timed against one shared clock so only writes fully inside the
  // backup's wall time count.
  final clock = Stopwatch()..start();
  final writeWindows = <(int, int)>[]; // (start us, end us) on [clock]
  var stopWrites = false;
  Future<void> writing() async {
    for (var live = 0; !stopWrites; live++) {
      final start = clock.elapsedMicroseconds;
      await db
          .collection(accounts)
          .doc('a00')
          .collection(txns)
          .doc('live-$live')
          .set(
            Txn(
              bookedOn: 20260101,
              amountMinor: live,
              currency: 'MYR',
              status: TxnStatus.posted,
              memo: 'live-$live',
            ),
          );
      writeWindows.add((start, clock.elapsedMicroseconds));
    }
  }

  final writer = writing();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final backupStart = clock.elapsedMicroseconds;
  final backupSw = Stopwatch()..start();
  final backupPath = '${scratch.path}/backup.db';
  final info = await db.backupTo(backupPath);
  backupSw.stop();
  final backupEnd = clock.elapsedMicroseconds;
  stopWrites = true;
  await writer;

  final overlapped = [
    for (final (start, end) in writeWindows)
      if (start >= backupStart && end <= backupEnd) end - start,
  ]..sort();
  final dbBytes = File(dbPath).lengthSync();
  final walBytes = _sidecarBytes(dbPath, '-wal');
  final shmBytes = _sidecarBytes(dbPath, '-shm');
  final sourceBytes = dbBytes + walBytes + shmBytes;

  // Restore onto a fresh path (the source stays open: restoreBackup only
  // refuses a Cocoon holding the TARGET open).
  final restorePath = '${scratch.path}/restored.db';
  final restoreSw = Stopwatch()..start();
  await Cocoon.restoreBackup(
    backup: backupPath,
    path: restorePath,
    collections: [accounts, txns],
  );
  restoreSw.stop();

  final restored = await Cocoon.open(
    restorePath,
    collections: [accounts, txns],
  );
  final restoredTxns = await restored
      .collection(accounts)
      .doc('a00')
      .collection(txns)
      .count();
  final restoredSeq = await restored.lastChangeSeq();
  final restoredInstanceId = restored.instanceId;
  await restored.close();
  await db.close();

  final restoredBytes = File(restorePath).lengthSync();
  stdout.writeln(
    '--- backup (rivals dataset, $size txns, Durability.full) ---',
  );
  stdout.writeln('backupTo:     ${backupSw.elapsed.inMilliseconds} ms');
  stdout.writeln(
    'backup size:  ${info.bytes} bytes (source db $dbBytes + wal $walBytes '
    '+ shm $shmBytes = $sourceBytes bytes)',
  );
  stdout.writeln(
    'single writes inside the backup window: ${overlapped.length}, '
    'p50 ${(_percentile(overlapped, 0.5) / 1000).toStringAsFixed(2)} ms, '
    'p95 ${(_percentile(overlapped, 0.95) / 1000).toStringAsFixed(2)} ms',
  );
  stdout.writeln('--- restore ---');
  stdout.writeln(
    'restoreBackup: ${restoreSw.elapsed.inMilliseconds} ms '
    '(restored file $restoredBytes bytes)',
  );
  stdout.writeln(
    'restored a00/txns count: $restoredTxns; '
    'restored lastChangeSeq == backup: ${restoredSeq == info.lastChangeSeq}; '
    'instance id changed: ${restoredInstanceId != sourceInstanceId}',
  );
  if (keep) {
    stdout.writeln('scratch kept at ${scratch.path}');
  } else {
    scratch.deleteSync(recursive: true);
    stdout.writeln('scratch deleted');
  }
}
