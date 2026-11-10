import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/format_migration.dart';
import 'package:cocoon/src/engine/naming.dart';
import 'package:cocoon/src/engine/schema_sql.dart';
import 'package:cocoon/src/engine/sqlite_executor.dart' show SqliteExecutor;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;
import 'package:test/test.dart';

import 'support/models.dart';

/// The storage-format migration: a format-1 file (every collection table
/// carrying a redundant `path TEXT NOT NULL UNIQUE` column and its
/// autoindex) is rebuilt table by table inside the first open that touches
/// it — crash-safe, with a newer file refusing to open.
void main() {
  late Directory dir;
  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_format_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  // -- format-1 fixtures -----------------------------------------------------

  /// The exact format-1 DDL of the `txn` table (path first, UNIQUE).
  const oldTxnCreate =
      'CREATE TABLE IF NOT EXISTS txn (\n'
      '  path TEXT NOT NULL UNIQUE,\n'
      '  id TEXT NOT NULL,\n'
      '  p_account_id TEXT NOT NULL,\n'
      '  data BLOB NOT NULL,\n'
      "  f_booked_on INTEGER NOT NULL CHECK (typeof(f_booked_on) = 'integer'),\n"
      "  f_amount_minor INTEGER NOT NULL CHECK (typeof(f_amount_minor) = 'integer'),\n"
      "  f_currency TEXT NOT NULL CHECK (typeof(f_currency) = 'text')\n"
      ')';

  Uint8List oldTxnBytes(int bookedOn, int amountMinor, String currency) {
    final writer = WireWriter()
      ..writeInt64(1, bookedOn)
      ..writeSint64(2, amountMinor)
      ..writeString(4, currency);
    return writer.toBytes();
  }

  /// Builds a format-1 file: two accounts, two txns under the first, one
  /// change-log row per write, plus an UNREGISTERED legacy table still in
  /// the old shape.
  Future<void> buildOldFormatFile(String path) async {
    final db = raw.sqlite3.open(path);
    try {
      db.execute(createOldMetaSql());
      db.execute(createOldChangesSql());
      db.execute(oldTxnCreate);
      db.execute(
        'CREATE TABLE IF NOT EXISTS account (\n'
        '  path TEXT NOT NULL UNIQUE,\n'
        '  id TEXT NOT NULL,\n'
        '  data BLOB NOT NULL,\n'
        "  f_name TEXT NOT NULL CHECK (typeof(f_name) = 'text'),\n"
        "  f_active INTEGER NOT NULL CHECK (typeof(f_active) = 'integer')\n"
        ')',
      );
      // The unregistered table must survive the upgrade (rebuilt like any
      // other, not dropped).
      db.execute(
        'CREATE TABLE IF NOT EXISTS legacy (\n'
        '  path TEXT NOT NULL UNIQUE,\n'
        '  id TEXT NOT NULL,\n'
        '  note TEXT NOT NULL\n'
        ')',
      );
      db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS cx_txn_scope '
        'ON txn (p_account_id ASC, id ASC)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS cx_txn_deadbeefdeadbeef '
        'ON txn (f_booked_on ASC, id ASC)',
      );
      var seq = 0;
      void insertTxn(
        String path_,
        String id,
        String account,
        Uint8List data,
        int bookedOn,
        int amountMinor,
        String currency,
      ) {
        seq++;
        db.execute(
          'INSERT INTO txn (path, id, p_account_id, data, f_booked_on, '
          'f_amount_minor, f_currency) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [path_, id, account, data, bookedOn, amountMinor, currency],
        );
        db.execute(
          'INSERT INTO _cocoon_changes (tbl, path, op, at) '
          "VALUES ('txn', ?, 'set', 1700000000000000)",
          [path_],
        );
      }

      db.execute(
        'INSERT INTO account (path, id, data, f_name, f_active) '
        "VALUES ('accounts/a1', 'a1', ?, 'Acme', 1)",
        [
          (WireWriter()
                ..writeString(1, 'Acme')
                ..writeBool(2, true))
              .toBytes(),
        ],
      );
      db.execute(
        'INSERT INTO legacy (path, id, note) '
        "VALUES ('legacy/l1', 'l1', 'keep me')",
      );
      insertTxn(
        'accounts/a1/txns/t1',
        't1',
        'a1',
        oldTxnBytes(20260101, 100, 'MYR'),
        20260101,
        100,
        'MYR',
      );
      insertTxn(
        'accounts/a1/txns/t2',
        't2',
        'a1',
        oldTxnBytes(20260102, 250, 'USD'),
        20260102,
        250,
        'USD',
      );
      db.execute('INSERT INTO _cocoon_meta (key, value) VALUES (?, ?)', [
        instanceIdMetaKey,
        'old-instance',
      ]);
      expect(seq, 2);
    } finally {
      db.close();
    }
  }

  test(
    'an old-format file migrates on open with identical data and log',
    () async {
      final path = dbPath();
      await buildOldFormatFile(path);

      final db = await Cocoon.open(path, collections: [accounts, txns, splits]);
      try {
        // The documents are exactly what was stored.
        final a1 = db.collection(accounts).doc('a1');
        expect(
          (await a1.get())!.data,
          const Account(name: 'Acme', active: true),
        );
        final t1 = await a1.collection(txns).doc('t1').get();
        expect(t1!.data.amountMinor, 100);
        expect(t1.data.currency, 'MYR');
        final t2 = await a1.collection(txns).doc('t2').get();
        expect(t2!.data.amountMinor, 250);
        expect(t2.data.currency, 'USD');
        expect(await a1.collection(txns).count(), 2);

        // The change log survived untouched, paths included.
        final changes = await db.changesSince(0);
        expect([
          for (final c in changes) c.path,
        ], containsAll(['accounts/a1/txns/t1', 'accounts/a1/txns/t2']));

        // The rebuilt layout: no path column, no autoindex; the scope index
        // and the declared index are back.
        final rawDb = raw.sqlite3.open(path);
        try {
          final columns = [
            for (final row in rawDb.select('PRAGMA table_info(txn)'))
              row['name']! as String,
          ];
          expect(columns, isNot(contains('path')));
          expect(
            columns,
            containsAll(['id', 'p_account_id', 'data', 'f_booked_on']),
          );
          final indexNames = [
            for (final row in rawDb.select(
              "SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND tbl_name = 'txn'",
            ))
              row['name']! as String,
          ];
          expect(indexNames, contains('cx_txn_scope'));
          // The declared indexes are back by their fingerprinted names.
          final entry = SchemaRegistry.build([
            accounts,
            txns,
            splits,
          ]).entryFor(txns);
          for (final index in entry.indexes) {
            expect(indexNames, contains(index.name));
          }
          // The old fixture's undeclared index went with the shape change.
          expect(indexNames, isNot(contains('cx_txn_deadbeefdeadbeef')));
          expect(
            indexNames.where((name) => name.startsWith('sqlite_autoindex')),
            isEmpty,
          );
          // The unregistered legacy table was rebuilt for the new layout too.
          final legacyColumns = [
            for (final row in rawDb.select('PRAGMA table_info(legacy)'))
              row['name']! as String,
          ];
          expect(legacyColumns, isNot(contains('path')));
          expect(
            rawDb.select('SELECT id, note FROM legacy').single['note'],
            'keep me',
          );
          // The file now carries the current format version.
          expect(
            rawDb.select('SELECT value FROM _cocoon_meta WHERE key = ?', [
              formatVersionMetaKey,
            ]).single['value'],
            '$storageFormatVersion',
          );
        } finally {
          rawDb.close();
        }
      } finally {
        await db.close();
      }
    },
  );

  test(
    'a crash at each migration step rolls back; the next open finishes',
    () async {
      for (final step in FormatMigrationStep.values) {
        final path = dbPath('crash-${step.name}.db');
        await buildOldFormatFile(path);
        FormatMigrator.debugFailBeforeStep = step;
        await expectLater(
          Cocoon.open(path, collections: [accounts, txns, splits]),
          throwsA(isA<StateError>()),
        );
        expect(
          FormatMigrator.debugFailBeforeStep,
          isNull,
          reason: 'the injection must clear itself',
        );

        // Either the old or the new layout is on disk, and the next open
        // finishes the job with identical data.
        final db = await Cocoon.open(
          path,
          collections: [accounts, txns, splits],
        );
        try {
          final t2 = await db
              .collection(accounts)
              .doc('a1')
              .collection(txns)
              .doc('t2')
              .get();
          expect(t2!.data.amountMinor, 250, reason: 'step $step');
          expect(await db.changesSince(0), isNotEmpty, reason: 'step $step');
        } finally {
          await db.close();
        }
      }
    },
  );

  test('a newer storage format refuses to open', () async {
    final path = dbPath('newer.db');
    await buildOldFormatFile(path);
    // Migrate to the current format first, then pretend a newer app wrote it.
    final db = await Cocoon.open(path, collections: [accounts, txns, splits]);
    await db.close();
    final rawDb = raw.sqlite3.open(path);
    rawDb.execute('UPDATE _cocoon_meta SET value = ? WHERE key = ?', [
      '${storageFormatVersion + 1}',
      formatVersionMetaKey,
    ]);
    rawDb.close();

    await expectLater(
      Cocoon.open(path, collections: [accounts, txns, splits]),
      throwsA(
        isA<StorageFormatTooNewException>()
            .having(
              (e) => e.formatVersion,
              'formatVersion',
              storageFormatVersion + 1,
            )
            .having(
              (e) => e.maxSupported,
              'maxSupported',
              storageFormatVersion,
            ),
      ),
    );
  });

  test('progress reports the copied documents', () async {
    final path = dbPath('progress.db');
    await buildOldFormatFile(path);
    final reports = <(int, int)>[];
    final db = await Cocoon.open(
      path,
      collections: [accounts, txns, splits],
      onMigrationProgress: (done, total) => reports.add((done, total)),
    );
    await db.close();
    // Every collection table reported: 1 account row, 2 txn rows, 1 legacy.
    expect(reports.first, (0, 4));
    expect(reports.last.$1, 4);
    expect(reports.last.$2, 4);
  });

  test('a fresh file is stamped with the current format version', () async {
    final db = await Cocoon.open(dbPath('fresh.db'), collections: [accounts]);
    await db.close();
    final rawDb = raw.sqlite3.open(dbPath('fresh.db'));
    try {
      expect(
        rawDb.select('SELECT value FROM _cocoon_meta WHERE key = ?', [
          formatVersionMetaKey,
        ]).single['value'],
        '$storageFormatVersion',
      );
    } finally {
      rawDb.close();
    }
  });

  test(
    'restoreBackup of an older-format backup works and migrates at open',
    () async {
      // A live database in the CURRENT format, backed up.
      final livePath = dbPath('live.db');
      final db = await Cocoon.open(livePath, collections: [accounts, txns]);
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      final backupPath = dbPath('backup.db');
      await db.backupTo(backupPath);
      await db.close();

      // Rebuild the backup's tables into the OLD format, as if an older app
      // had written both files.
      void downgrade(String path) {
        final rawDb = raw.sqlite3.open(path);
        try {
          rawDb.execute('BEGIN');
          rawDb.execute('DROP TABLE IF EXISTS account');
          rawDb.execute(
            'CREATE TABLE account (\n'
            '  path TEXT NOT NULL UNIQUE,\n'
            '  id TEXT NOT NULL,\n'
            '  data BLOB NOT NULL,\n'
            "  f_name TEXT NOT NULL CHECK (typeof(f_name) = 'text'),\n"
            "  f_active INTEGER NOT NULL CHECK (typeof(f_active) = 'integer')\n"
            ')',
          );
          rawDb.execute(
            'INSERT INTO account (path, id, data, f_name, f_active) '
            "VALUES ('accounts/a1', 'a1', ?, 'Acme', 1)",
            [
              (WireWriter()
                    ..writeString(1, 'Acme')
                    ..writeBool(2, true))
                  .toBytes(),
            ],
          );
          rawDb.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS cx_account_scope '
            'ON account (id ASC)',
          );
          rawDb.execute('DELETE FROM _cocoon_meta WHERE key = ?', [
            formatVersionMetaKey,
          ]);
          rawDb.execute('COMMIT');
        } finally {
          rawDb.close();
        }
      }

      downgrade(backupPath);
      final restoredPath = dbPath('restored.db');
      await Cocoon.restoreBackup(
        backup: backupPath,
        path: restoredPath,
        collections: [accounts],
      );

      // The next open migrates the restored file; the data is intact.
      final restored = await Cocoon.open(restoredPath, collections: [accounts]);
      try {
        expect(
          (await restored.collection(accounts).doc('a1').get())!.data,
          const Account(name: 'Acme', active: true),
        );
      } finally {
        await restored.close();
      }
    },
  );

  test(
    'restoreBackup refuses a newer-format backup before touching anything',
    () async {
      final db = await Cocoon.open(dbPath('live2.db'), collections: [accounts]);
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      final backupPath = dbPath('backup2.db');
      await db.backupTo(backupPath);
      await db.close();

      final rawDb = raw.sqlite3.open(backupPath);
      rawDb.execute('UPDATE _cocoon_meta SET value = ? WHERE key = ?', [
        '${storageFormatVersion + 1}',
        formatVersionMetaKey,
      ]);
      rawDb.close();

      final targetPath = dbPath('target.db');
      await expectLater(
        Cocoon.restoreBackup(
          backup: backupPath,
          path: targetPath,
          collections: [accounts],
        ),
        throwsA(isA<StorageFormatTooNewException>()),
      );
      // Nothing was written to the target.
      expect(File(targetPath).existsSync(), isFalse);
    },
  );

  test('inspectBackup reports the storage format the backup carries', () async {
    final db = await Cocoon.open(dbPath('live3.db'), collections: [accounts]);
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true));
    final backupPath = dbPath('backup3.db');
    await db.backupTo(backupPath);
    await db.close();

    final info = await Cocoon.inspectBackup(backupPath);
    expect(info.storageFormatVersion, storageFormatVersion);
  });

  test('the SpyExecutor open path runs the same format check', () async {
    final path = dbPath('newer2.db');
    await buildOldFormatFile(path);
    final db = await Cocoon.open(path, collections: [accounts, txns, splits]);
    await db.close();
    final rawDb = raw.sqlite3.open(path);
    rawDb.execute('UPDATE _cocoon_meta SET value = ? WHERE key = ?', [
      '${storageFormatVersion + 1}',
      formatVersionMetaKey,
    ]);
    rawDb.close();

    final executor = SqliteExecutor(SqliteDatabase(path: path));
    try {
      await expectLater(
        Cocoon.openWith(executor, collections: [accounts, txns, splits]),
        throwsA(isA<StorageFormatTooNewException>()),
      );
    } finally {
      await executor.close();
    }
  });
}

// -- format-1 DDL pieces -----------------------------------------------------

String createOldMetaSql() =>
    'CREATE TABLE IF NOT EXISTS $metaTableName '
    '(key TEXT PRIMARY KEY, value TEXT NOT NULL)';

String createOldChangesSql() =>
    'CREATE TABLE IF NOT EXISTS $changesTableName (\n'
    '  seq INTEGER PRIMARY KEY AUTOINCREMENT,\n'
    '  tbl TEXT NOT NULL,\n'
    '  path TEXT NOT NULL,\n'
    "  op TEXT NOT NULL CHECK (op IN ('set','delete')),\n"
    '  at INTEGER NOT NULL\n'
    ')';
