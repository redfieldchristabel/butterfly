import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/backup.dart'
    show BackupOperations, BackupRestoreStep;
import 'package:cocoon/src/engine/naming.dart' show bulkTableName;
import 'package:cocoon/src/engine/sqlite_executor.dart' show SqliteExecutor;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;
import 'package:test/test.dart';

import 'support/models.dart';

final List<CollectionAdapter<Object?>> allCollections = [
  accounts,
  txns,
  splits,
];

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String p([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase(
    String path, {
    CocoonOptions options = const CocoonOptions(),
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
  }) async {
    final db = await Cocoon.open(
      path,
      collections: allCollections,
      options: options,
      schemaVersion: schemaVersion,
      migrations: migrations,
    );
    openDbs.add(db);
    return db;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_backup_test');
  });

  tearDown(() async {
    BackupOperations.debugFailBeforeStep = null;
    for (final db in openDbs) {
      await db.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  Account account(String id, {String note = 'note'}) =>
      Account(name: 'account-$id', active: true, note: note);

  Txn txn(int i) => Txn(
    bookedOn: 20260101 + (i % 300),
    amountMinor: i * 10,
    rate: 1.5,
    currency: 'MYR',
    status: TxnStatus.values[i % TxnStatus.values.length],
    createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
    memo: 'memo-$i',
  );

  Future<void> seed(Cocoon db, {int txnsPerAccount = 5}) async {
    for (var a = 0; a < 3; a++) {
      final accountRef = db.collection(accounts).doc('a$a');
      await accountRef.set(account('a$a'));
      for (var t = 0; t < txnsPerAccount; t++) {
        await accountRef.collection(txns).doc('t$a-$t').set(txn(a * 100 + t));
      }
    }
  }

  group('backupTo', () {
    test('writes a self-contained, verifiable backup with metadata', () async {
      final db = await openDatabase(p(), schemaVersion: 1);
      await seed(db);
      await db.collection(accounts).doc('lonely').set(account('lonely'));
      final seq = await db.lastChangeSeq();

      final backupPath = p('backup.db');
      final info = await db.backupTo(backupPath);

      expect(info.path, backupPath);
      expect(info.bytes, File(backupPath).lengthSync());
      expect(info.formatVersion, backupFormatVersion);
      expect(info.schemaVersion, 1);
      expect(info.lastChangeSeq, seq);
      expect(info.cocoonVersion, cocoonLibraryVersion);
      expect(
        info.createdAt,
        isA<DateTime>().having((v) => v.isUtc, 'isUtc', true),
      );
      expect(
        DateTime.now().toUtc().difference(info.createdAt).inMinutes,
        lessThanOrEqualTo(1),
      );

      // One single file, in rollback-journal mode, no sidecars: the VACUUM
      // INTO output is portable and compacted.
      expect(
        File('$backupPath-wal').existsSync(),
        isFalse,
        reason: 'a backup must be a single self-contained file',
      );
      expect(File('$backupPath-shm').existsSync(), isFalse);
      final rawCopy = raw.sqlite3.open(backupPath);
      final journalMode = rawCopy
          .select('PRAGMA journal_mode')
          .first
          .values
          .first;
      rawCopy.close();
      expect(journalMode, 'delete');

      final inspected = await Cocoon.inspectBackup(backupPath);
      expect(inspected, info);
    });

    test('refuses an existing target unless overwrite, and overwrites '
        'atomically', () async {
      final db = await openDatabase(p());
      await seed(db);
      final backupPath = p('backup.db');
      final first = await db.backupTo(backupPath);
      final firstBytes = File(backupPath).lengthSync();

      await db.collection(accounts).doc('a0').set(account('a0', note: 'new'));

      await expectLater(
        db.backupTo(backupPath),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('overwrite'),
          ),
        ),
      );
      // The old backup is untouched by the refusal.
      expect(File(backupPath).lengthSync(), firstBytes);
      expect(
        (await Cocoon.inspectBackup(backupPath)).createdAt,
        first.createdAt,
      );

      final second = await db.backupTo(backupPath, overwrite: true);
      expect(second.createdAt.isAfter(first.createdAt), isTrue);
      expect(second.bytes, File(backupPath).lengthSync());
    });

    test('refuses to target the database file itself', () async {
      final dbPath = p();
      final db = await openDatabase(dbPath);
      await expectLater(db.backupTo(dbPath), throwsA(isA<ArgumentError>()));
      await expectLater(
        db.backupTo(dbPath, overwrite: true),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('needs a file-backed database', () async {
      final db = await Cocoon.openWith(
        SqliteExecutor(SqliteDatabase(path: p('custom.db'))),
        collections: allCollections,
      );
      openDbs.add(db);
      expect(() => db.backupTo(p('backup.db')), throwsA(isA<StateError>()));
    });

    test(
      'a failing backup leaves no file at the target and no partial',
      () async {
        final db = await openDatabase(p());
        await seed(db);
        final missingDir = '${dir.path}${Platform.pathSeparator}nope';
        final target = '$missingDir${Platform.pathSeparator}backup.db';

        await expectLater(db.backupTo(target), throwsA(anything));

        expect(Directory(missingDir).existsSync(), isFalse);
        expect(File(target).existsSync(), isFalse);
        expect(File('$target.partial').existsSync(), isFalse);
      },
    );

    test('works on a fresh, empty database', () async {
      final db = await openDatabase(p(), schemaVersion: 4);
      final backupPath = p('backup.db');
      final info = await db.backupTo(backupPath);
      expect(info.lastChangeSeq, 0);
      expect(info.schemaVersion, 4);

      final restoredPath = p('restored.db');
      await Cocoon.restoreBackup(
        backup: backupPath,
        path: restoredPath,
        collections: allCollections,
        schemaVersion: 4,
      );
      final restored = await openDatabase(restoredPath, schemaVersion: 4);
      expect((await restored.collection(accounts).get()).docs, isEmpty);
    });

    test('works with keepChanges: false (empty log)', () async {
      final db = await openDatabase(
        p(),
        options: const CocoonOptions(keepChanges: false),
      );
      await seed(db);
      expect(await db.lastChangeSeq(), 0);

      final backupPath = p('backup.db');
      final info = await db.backupTo(backupPath);
      expect(info.lastChangeSeq, 0);

      final restoredPath = p('restored.db');
      await Cocoon.restoreBackup(
        backup: backupPath,
        path: restoredPath,
        collections: allCollections,
      );
      final restored = await openDatabase(restoredPath);
      expect(
        (await restored.collection(accounts).query().get()).docs.length,
        3,
      );
      expect(
        (await restored.collectionGroup(txns).query().allowFullScan().get())
            .docs
            .length,
        15,
      );
      expect(await restored.changesSince(0), isEmpty);
    });
  });

  group('inspectBackup', () {
    test('a live Cocoon database file is not a backup', () async {
      final dbPath = p('plain.db');
      final db = await openDatabase(dbPath);
      await seed(db);
      await db.close();
      openDbs.clear();

      await expectLater(
        Cocoon.inspectBackup(dbPath),
        throwsA(isA<NotCocoonBackupException>()),
      );
    });

    test('an empty file is not a backup', () async {
      final emptyPath = p('empty.db');
      File(emptyPath).writeAsBytesSync(const <int>[]);
      await expectLater(
        Cocoon.inspectBackup(emptyPath),
        throwsA(isA<NotCocoonBackupException>()),
      );
    });

    test('garbage bytes are reported damaged', () async {
      final garbagePath = p('garbage.db');
      File(
        garbagePath,
      ).writeAsBytesSync(Uint8List(4096)..fillRange(0, 4096, 0x41));
      await expectLater(
        Cocoon.inspectBackup(garbagePath),
        throwsA(isA<BackupDamagedException>()),
      );
    });

    test('a truncated backup is reported damaged', () async {
      final db = await openDatabase(p());
      await seed(db);
      final backupPath = p('backup.db');
      await db.backupTo(backupPath);

      final bytes = File(backupPath).readAsBytesSync();
      final truncatedPath = p('truncated.db');
      File(
        truncatedPath,
      ).writeAsBytesSync(bytes.sublist(0, bytes.length - bytes.length ~/ 3));

      await expectLater(
        Cocoon.inspectBackup(truncatedPath),
        throwsA(isA<BackupDamagedException>()),
      );
    });

    test('a missing file is an ArgumentError', () async {
      await expectLater(
        Cocoon.inspectBackup(p('nope.db')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('restoreBackup', () {
    test('the restored data equals the source at backup time', () async {
      final dbPath = p();
      final db = await openDatabase(dbPath);
      await seed(db);
      await db
          .collection(accounts)
          .doc('a0')
          .collection(txns)
          .doc('t0-0')
          .collection(splits)
          .doc('s1')
          .set(const Split(label: 'food', shareMinor: 700));
      final backupPath = p('backup.db');
      await db.backupTo(backupPath);
      final seqAtBackup = (await Cocoon.inspectBackup(
        backupPath,
      )).lastChangeSeq;

      // Mutate the source after the backup: the restore must undo all of it.
      await db.collection(accounts).doc('a0').delete();
      await db.collection(accounts).doc('added').set(account('added'));
      await db.close();
      openDbs.clear();

      final info = await Cocoon.restoreBackup(
        backup: backupPath,
        path: dbPath,
        collections: allCollections,
      );
      expect(info.path, dbPath);

      final restored = await openDatabase(dbPath);
      final restoredAccounts = await restored
          .collection(accounts)
          .query()
          .get();
      expect(restoredAccounts.docs.map((s) => s.id), containsAll(['a0', 'a1']));
      expect(restoredAccounts.docs.map((s) => s.id), isNot(contains('added')));
      expect(
        (await restored.collectionGroup(txns).query().allowFullScan().get())
            .docs
            .length,
        15,
      );
      expect(
        (await restored.collectionGroup(splits).query().allowFullScan().get())
            .docs
            .map((s) => s.data.label),
        ['food'],
      );
      expect(await restored.lastChangeSeq(), seqAtBackup);
      expect(await restored.changesSince(0), isNotEmpty);
    });

    test(
      'refused while a Cocoon has the target open in this isolate',
      () async {
        final dbPath = p();
        final db = await openDatabase(dbPath);
        await seed(db);
        final backupPath = p('backup.db');
        await db.backupTo(backupPath);

        await expectLater(
          Cocoon.restoreBackup(
            backup: backupPath,
            path: dbPath,
            collections: allCollections,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('still open'),
            ),
          ),
        );
        // The open database file was not touched.
        expect(File(dbPath).existsSync(), isTrue);
        expect(File('$dbPath.restoring').existsSync(), isFalse);

        await db.close();
        openDbs.clear();
        await Cocoon.restoreBackup(
          backup: backupPath,
          path: dbPath,
          collections: allCollections,
        );
        final restored = await openDatabase(dbPath);
        expect(
          (await restored.collection(accounts).query().get()).docs.length,
          3,
        );
      },
    );

    test('refused while a Cocoon has the backup file open', () async {
      final db = await openDatabase(p());
      await seed(db);
      final backupPath = p('backup.db');
      await db.backupTo(backupPath);
      await db.close();
      openDbs.clear();

      // A backup file is a valid Cocoon database file; opening it makes it
      // ours, and a restore must not swap files under a live instance.
      final openBackup = await openDatabase(backupPath);
      await expectLater(
        Cocoon.restoreBackup(
          backup: backupPath,
          path: p('target.db'),
          collections: allCollections,
        ),
        throwsA(isA<StateError>()),
      );
      await openBackup.close();
      openDbs.clear();

      await Cocoon.restoreBackup(
        backup: backupPath,
        path: p('target.db'),
        collections: allCollections,
      );
      expect(File(p('target.db')).existsSync(), isTrue);
    });

    test(
      'a newer-schema backup is refused before the target is touched',
      () async {
        final db = await openDatabase(p(), schemaVersion: 5);
        await seed(db);
        final backupPath = p('backup.db');
        await db.backupTo(backupPath);
        await db.close();
        openDbs.clear();

        // An existing, older database at the target.
        final targetPath = p('target.db');
        final target = await openDatabase(targetPath, schemaVersion: 3);
        await target.collection(accounts).doc('keep').set(account('keep'));
        await target.close();
        openDbs.clear();
        final targetBytes = File(targetPath).readAsBytesSync();

        await expectLater(
          Cocoon.restoreBackup(
            backup: backupPath,
            path: targetPath,
            collections: allCollections,
            schemaVersion: 3,
          ),
          throwsA(
            isA<SchemaTooNewException>()
                .having((e) => e.storedVersion, 'storedVersion', 5)
                .having((e) => e.appVersion, 'appVersion', 3),
          ),
        );
        expect(
          File(targetPath).readAsBytesSync(),
          targetBytes,
          reason: 'the compatibility check must run before any file work',
        );
        expect(File('$targetPath.restoring').existsSync(), isFalse);
      },
    );

    test('an older-schema backup migrates at the next open', () async {
      final db = await openDatabase(p(), schemaVersion: 1);
      await seed(db);
      final backupPath = p('backup.db');
      await db.backupTo(backupPath);
      await db.close();
      openDbs.clear();

      final restoredPath = p('restored.db');
      await Cocoon.restoreBackup(
        backup: backupPath,
        path: restoredPath,
        collections: allCollections,
        schemaVersion: 2,
      );

      // Opening at version 2 applies the (empty) migration and stores v2;
      // opening the same file as v1 afterwards must refuse.
      final migrated = await openDatabase(
        restoredPath,
        schemaVersion: 2,
        migrations: const [CocoonMigration(version: 2, fields: [])],
      );
      expect(
        (await migrated.collectionGroup(txns).query().allowFullScan().get())
            .docs
            .length,
        15,
      );
      await migrated.close();
      openDbs.clear();

      await expectLater(
        Cocoon.open(
          restoredPath,
          collections: allCollections,
          schemaVersion: 1,
        ),
        throwsA(isA<SchemaTooNewException>()),
      );
    });

    test(
      'keepPrevious keeps the previous database; false removes it',
      () async {
        final dbPath = p();
        final db = await openDatabase(dbPath);
        await db.collection(accounts).doc('old').set(account('old'));
        final backupPath = p('backup.db');
        await db.backupTo(backupPath);
        await db.close();
        openDbs.clear();

        await Cocoon.restoreBackup(
          backup: backupPath,
          path: dbPath,
          collections: allCollections,
        );
        final beforePath = '$dbPath.before-restore';
        expect(File(beforePath).existsSync(), isTrue);
        final previous = await openDatabase(beforePath);
        expect(
          (await previous.collection(accounts).get()).docs.map((s) => s.id),
          ['old'],
        );
        await previous.close();
        openDbs.clear();

        // Replace the restored database again, this time without keeping the
        // previous file.
        final db2 = await openDatabase(dbPath);
        await db2.collection(accounts).doc('newer').set(account('newer'));
        await db2.close();
        openDbs.clear();

        await Cocoon.restoreBackup(
          backup: backupPath,
          path: dbPath,
          collections: allCollections,
          keepPrevious: false,
        );
        expect(File(beforePath).existsSync(), isFalse);
        final restored = await openDatabase(dbPath);
        expect(
          (await restored.collection(accounts).get()).docs.map((s) => s.id),
          ['old'],
        );
      },
    );

    test('stale WAL and SHM of the target are removed', () async {
      // Build a live WAL (db + -wal + -shm) and copy the whole set onto the
      // restore target, so the target carries sidecars from a different
      // database state than any backup.
      final sourcePath = p('live.db');
      final live = await openDatabase(
        sourcePath,
        options: const CocoonOptions(durability: Durability.normal),
      );
      await seed(live);
      final backupPath = p('backup.db');
      await live.backupTo(backupPath);

      final targetPath = p('target.db');
      for (final suffix in const ['', '-wal', '-shm']) {
        final source = File('$sourcePath$suffix');
        if (source.existsSync()) {
          await source.copy('$targetPath$suffix');
        }
      }
      await live.close();
      openDbs.clear();
      expect(
        File('$targetPath-wal').existsSync(),
        isTrue,
        reason: 'the test setup must have produced a stale WAL',
      );

      await Cocoon.restoreBackup(
        backup: backupPath,
        path: targetPath,
        collections: allCollections,
      );

      expect(File('$targetPath-wal').existsSync(), isFalse);
      expect(File('$targetPath-shm').existsSync(), isFalse);

      final restored = await openDatabase(targetPath);
      expect(
        (await restored.collectionGroup(txns).query().allowFullScan().get())
            .docs
            .length,
        15,
      );
      expect(
        (await restored.collection(accounts).query().get()).docs.length,
        3,
      );
    });

    test(
      'a failure at every step leaves the original database usable',
      () async {
        for (final step in BackupRestoreStep.values) {
          final dbPath = p('db-$step.db');
          final db = await openDatabase(dbPath);
          await db
              .collection(accounts)
              .doc('original')
              .set(account('original'));
          final backupPath = p('backup-$step.db');
          await db.backupTo(backupPath);
          await db.close();
          openDbs.clear();

          BackupOperations.debugFailBeforeStep = step;
          await expectLater(
            Cocoon.restoreBackup(
              backup: backupPath,
              path: dbPath,
              collections: allCollections,
            ),
            throwsA(isA<StateError>()),
          );
          expect(
            BackupOperations.debugFailBeforeStep,
            isNull,
            reason: 'the injection is consumed by one restore',
          );

          final original = await openDatabase(dbPath);
          expect(
            (await original.collection(accounts).get()).docs.map((s) => s.id),
            ['original'],
            reason: 'the original database must survive a failure at $step',
          );
          await original.close();
          openDbs.clear();
          expect(
            File('$dbPath.restoring').existsSync(),
            isFalse,
            reason: 'no restoring copy may survive a failed restore at $step',
          );
          expect(
            File('$dbPath.before-restore').existsSync(),
            isFalse,
            reason: 'the moved original must be back in place at $step',
          );
        }
      },
    );
  });

  group('instance id', () {
    test('created with the database and stable across reopens', () async {
      final dbPath = p();
      final db = await openDatabase(dbPath);
      final id = db.instanceId;
      expect(id, isNotEmpty);
      await db.close();
      openDbs.clear();

      final reopened = await openDatabase(dbPath);
      expect(reopened.instanceId, id);
    });

    test('differs between databases', () async {
      final one = await openDatabase(p('one.db'));
      final other = await openDatabase(p('other.db'));
      expect(one.instanceId, isNot(other.instanceId));
    });

    test('changes on restore and survives a normal reopen', () async {
      final dbPath = p();
      final db = await openDatabase(dbPath);
      await seed(db);
      final originalId = db.instanceId;
      final backupPath = p('backup.db');
      await db.backupTo(backupPath);
      await db.close();
      openDbs.clear();

      await Cocoon.restoreBackup(
        backup: backupPath,
        path: dbPath,
        collections: allCollections,
      );
      final restored = await openDatabase(dbPath);
      expect(restored.instanceId, isNot(originalId));

      await restored.close();
      openDbs.clear();
      final reopened = await openDatabase(dbPath);
      expect(reopened.instanceId, restored.instanceId);
    });

    test(
      'a sync watermark saved before a restore is detected as stale',
      () async {
        final dbPath = p();
        final db = await openDatabase(dbPath);
        await seed(db);
        final backupPath = p('backup.db');
        await db.backupTo(backupPath);

        // More commits after the backup push the watermark ahead of it.
        for (var i = 0; i < 5; i++) {
          await db.collection(accounts).doc('late-$i').set(account('late-$i'));
        }
        final savedWatermark = await db.lastChangeSeq();
        final savedInstanceId = db.instanceId;
        await db.close();
        openDbs.clear();

        await Cocoon.restoreBackup(
          backup: backupPath,
          path: dbPath,
          collections: allCollections,
        );
        final restored = await openDatabase(dbPath);

        expect(
          restored.instanceId,
          isNot(savedInstanceId),
          reason: 'the consumer must see a different instance id',
        );
        expect(
          await restored.lastChangeSeq(),
          lessThan(savedWatermark),
          reason: 'the saved watermark is ahead of the restored log',
        );
        // Within one instance the guarantee still holds: seq continues from
        // the backup's head, never reusing values the old instance assigned.
        await restored.collection(accounts).doc('after').set(account('after'));
        expect(await restored.lastChangeSeq(), lessThan(savedWatermark));
      },
    );
  });

  group('consistency', () {
    test(
      'a backup during continuous commits equals one committed state',
      () async {
        final dbPath = p();
        final db = await openDatabase(
          dbPath,
          options: const CocoonOptions(durability: Durability.normal),
        );
        // Anchor data committed before the backup starts.
        final anchors = db.batch();
        for (var i = 0; i < 50; i++) {
          anchors.set(
            db.collection(accounts).doc('anchor-$i'),
            account('anchor-$i', note: 'x' * 200),
          );
        }
        await anchors.commit();

        final committedBatches = <int>[];
        Future<void> writing() async {
          for (var b = 0; b < 1500; b++) {
            final writer = db.batch();
            for (var i = 0; i < 10; i++) {
              writer.set(
                db.collection(accounts).doc('w${b}_$i'),
                account('w${b}_$i', note: 'y' * 200),
              );
            }
            await writer.commit();
            committedBatches.add(b);
          }
        }

        final writer = writing();
        // Give the writer a head start so the vacuum lands mid-stream.
        while (committedBatches.length < 20) {
          await Future<void>.delayed(Duration.zero);
        }

        final backupPath = p('backup.db');
        final info = await db.backupTo(backupPath);
        // Let the writer finish, then stop it.
        await writer;
        expect(committedBatches.length, 1500);

        final restoredPath = p('restored.db');
        await Cocoon.restoreBackup(
          backup: backupPath,
          path: restoredPath,
          collections: allCollections,
        );
        final restored = await openDatabase(restoredPath);

        // The metadata's seq matches the copy's own change log.
        expect(await restored.lastChangeSeq(), info.lastChangeSeq);
        expect(info.lastChangeSeq, greaterThan(0));

        final restoredDocs = (await restored.collection(accounts).get()).docs
            .map((s) => s.id)
            .toSet();
        // The anchor is always present.
        for (var i = 0; i < 50; i++) {
          expect(restoredDocs.contains('anchor-$i'), isTrue);
        }
        // Every committed batch is all-or-none, and batches commit in order,
        // so the snapshot holds a prefix of them.
        final presentBatches = <int>[];
        for (final b in committedBatches) {
          final inSnapshot = [
            for (var i = 0; i < 10; i++) restoredDocs.contains('w${b}_$i'),
          ];
          if (inSnapshot.every((e) => e)) {
            presentBatches.add(b);
          } else {
            expect(
              inSnapshot.any((e) => e),
              isFalse,
              reason:
                  'a committed batch is either fully in the copy or not '
                  'at all (batch $b)',
            );
          }
        }
        expect(
          presentBatches,
          orderedEquals(List.generate(presentBatches.length, (i) => i)),
          reason: 'batches commit in order, so the snapshot is a prefix',
        );
        expect(
          presentBatches,
          isNotEmpty,
          reason: 'the snapshot must overlap the writer',
        );
        expect(
          committedBatches.length,
          greaterThan(presentBatches.length),
          reason: 'writes continued after the snapshot was taken',
        );
      },
    );

    test('a snapshot mid-bulk-load carries _cocoon_bulk and the restored '
        'copy rebuilds the indexes', () async {
      final dbPath = p();
      final db = await openDatabase(dbPath);
      final bulk = db.bulkWriter(const BulkWriterOptions(chunkSize: 10));
      for (var i = 0; i < 15; i++) {
        bulk.set(
          db.collection(accounts).doc('b$i'),
          account('b$i', note: 'z' * 200),
        );
      }
      await bulk.flush(); // chunk committed, indexes deferred, writer open

      final entry = db.registry.entries.singleWhere(
        (e) => e.adapter.model == 'Account',
      );
      final bulkRows = await db.executor.getAll(
        'SELECT index_name FROM $bulkTableName',
      );
      expect(
        bulkRows.map((r) => r['index_name']),
        contains(entry.indexes.first.name),
      );

      final backupPath = p('backup.db');
      await db.backupTo(backupPath);
      await bulk.close();
      await db.close();
      openDbs.clear();

      final restoredPath = p('restored.db');
      await Cocoon.restoreBackup(
        backup: backupPath,
        path: restoredPath,
        collections: allCollections,
      );
      final restored = await openDatabase(restoredPath);

      // Recovery-on-open rebuilt what the writer had deferred.
      final remainingBulk = await restored.executor.getAll(
        'SELECT index_name FROM $bulkTableName',
      );
      expect(remainingBulk, isEmpty);
      for (final index in entry.indexes) {
        final row = await restored.executor.getOptional(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
          [index.name],
        );
        expect(row, isNotNull, reason: '${index.name} must be rebuilt');
      }
      final queried = await restored
          .collectionGroup(accounts)
          .where(accountName.isEqualTo('account-b3'))
          .get();
      expect(queried.docs.map((s) => s.data.name), ['account-b3']);
      expect((await restored.collection(accounts).get()).docs.length, 15);
    });
  });
}
