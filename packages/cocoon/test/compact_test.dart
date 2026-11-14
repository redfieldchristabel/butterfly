/// Post-upgrade compaction tests over a real SQLite database in a temp
/// directory: the open that rebuilds a format-1 file compacts it once (a
/// `VACUUM`) when the upgrade left more than a fifth of the file on the
/// freelist — never on a normal open, never when disabled, and a failing
/// `VACUUM` must leave the open successful with the data intact.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/naming.dart';
import 'package:cocoon/src/engine/sqlite_executor.dart' show SqliteExecutor;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:sqlite_async/sqlite_async.dart';
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/spy_executor.dart';
import 'support/open_db.dart';

/// The format-1 DDL pieces: the internal tables predate the shared helpers.
String _oldMetaSql() =>
    'CREATE TABLE IF NOT EXISTS $metaTableName '
    '(key TEXT PRIMARY KEY, value TEXT NOT NULL)';

String _oldChangesSql() =>
    'CREATE TABLE IF NOT EXISTS $changesTableName (\n'
    '  seq INTEGER PRIMARY KEY AUTOINCREMENT,\n'
    '  tbl TEXT NOT NULL,\n'
    '  path TEXT NOT NULL,\n'
    "  op TEXT NOT NULL CHECK (op IN ('set','delete')),\n"
    '  at INTEGER NOT NULL\n'
    ')';

/// The exact format-1 DDL of the `txn` table (path first, UNIQUE).
const _oldTxnCreate =
    'CREATE TABLE IF NOT EXISTS txn (\n'
    '  path TEXT NOT NULL UNIQUE,\n'
    '  id TEXT NOT NULL,\n'
    '  p_account_id TEXT NOT NULL,\n'
    '  data BLOB NOT NULL,\n'
    "  f_booked_on INTEGER NOT NULL CHECK (typeof(f_booked_on) = 'integer'),\n"
    "  f_amount_minor INTEGER NOT NULL CHECK (typeof(f_amount_minor) = 'integer'),\n"
    "  f_currency TEXT NOT NULL CHECK (typeof(f_currency) = 'text')\n"
    ')';

Uint8List _txnBytes(int i, {int padding = 0}) {
  final writer = WireWriter()
    ..writeInt64(1, 20260101 + i)
    ..writeSint64(2, 100 + i)
    ..writeString(4, 'MYR');
  if (padding > 0) {
    // A padded `memo`: keeps the stored rows big so the freelist share is
    // deterministic without an enormous row count.
    writer.writeString(7, 'm' * padding);
  }
  return writer.toBytes();
}

/// A data-only adapter for the migrated `txn` table: no field columns and no
/// secondary indexes, so the open's reconciliation adds nothing and the
/// freelist the upgrade left behind is exactly the rebuild's. A richer
/// adapter would consume the freed pages for its own indexes and make the
/// share test-dependent.
final class LegacyTxnAdapter extends CollectionAdapter<Txn> {
  LegacyTxnAdapter();

  @override
  String get model => 'Txn';

  @override
  final pattern = CollectionPattern.parse('accounts/{accountId}/txns');

  @override
  List<FieldColumn<Txn, Object?>> get columns => const [];

  @override
  List<IndexDef> get indexes => const [];

  @override
  Uint8List encode(Txn value) => _txnBytes(value.bookedOn - 20260101);

  @override
  Txn decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var bookedOn = 0;
    var amountMinor = 0;
    String? memo;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          bookedOn = reader.readInt64();
        case 2:
          amountMinor = reader.readSint64();
        case 7:
          memo = reader.readString();
        default:
          reader.skip(tag.type);
      }
    }
    return Txn(
      bookedOn: bookedOn,
      amountMinor: amountMinor,
      rate: 0,
      currency: 'MYR',
      status: TxnStatus.pending,
      createdAt: DateTime.utc(1970),
      memo: memo,
    );
  }
}

/// Builds a format-1 file with [txnRows] transactions under one account.
/// [bulkRows] adds a big table WITHOUT the path column (a legacy table this
/// Cocoon never registers): its pages dilute the freelist share below the
/// compaction threshold.
Future<void> buildOldFormatFile(
  String path, {
  required int txnRows,
  int bulkRows = 0,
  int bulkPayloadBytes = 0,
  int padding = 0,
}) async {
  final db = raw.sqlite3.open(path);
  try {
    db.execute(_oldMetaSql());
    db.execute(_oldChangesSql());
    db.execute(_oldTxnCreate);
    if (bulkRows > 0) {
      db.execute('CREATE TABLE bulk (id TEXT NOT NULL, payload BLOB NOT NULL)');
    }
    db.execute(
      'CREATE TABLE IF NOT EXISTS account ('
      '  path TEXT NOT NULL UNIQUE,'
      '  id TEXT NOT NULL,'
      '  data BLOB NOT NULL,'
      "  f_name TEXT NOT NULL CHECK (typeof(f_name) = 'text'),"
      "  f_active INTEGER NOT NULL CHECK (typeof(f_active) = 'integer')"
      ')',
    );
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS cx_txn_scope '
      'ON txn (p_account_id ASC, id ASC)',
    );
    db.execute('BEGIN');
    try {
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
      for (var i = 0; i < txnRows; i++) {
        db.execute(
          'INSERT INTO txn (path, id, p_account_id, data, f_booked_on, '
          'f_amount_minor, f_currency) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            'accounts/a1/txns/t$i',
            't$i',
            'a1',
            _txnBytes(i, padding: padding),
            20260101 + i,
            100 + i,
            'MYR',
          ],
        );
      }
      for (var i = 0; i < bulkRows; i++) {
        db.execute('INSERT INTO bulk (id, payload) VALUES (?, ?)', [
          'b$i',
          Uint8List(bulkPayloadBytes),
        ]);
      }
      db.execute('INSERT INTO _cocoon_meta (key, value) VALUES (?, ?)', [
        instanceIdMetaKey,
        'old-instance',
      ]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

({int free, int pages}) _freelist(String path) {
  final db = raw.sqlite3.open(path);
  try {
    return (
      free: db.select('PRAGMA freelist_count').first['freelist_count']! as int,
      pages: db.select('PRAGMA page_count').first['page_count']! as int,
    );
  } finally {
    db.close();
  }
}

/// A spy-wrapped real executor over [path], for opens the tests must observe
/// (or sabotage) statement by statement.
SpyExecutor _spiedExecutor(String path) =>
    SpyExecutor(SqliteExecutor(SqliteDatabase(path: path)));

void main() {
  late Directory dir;

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_compact_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test(
    'an upgrade open with a big freelist compacts once, after the commit',
    () async {
      final path = dbPath();
      await buildOldFormatFile(path, txnRows: 400, padding: 900);

      final spy = _spiedExecutor(path);
      final db = await Cocoon.openWith(
        spy,
        collections: [accounts, LegacyTxnAdapter()],
      );
      try {
        expect(spy.statements, contains('VACUUM'));
        // Nothing ran after the compaction: the open ends with the PRAGMA
        // checks and the one VACUUM.
        expect(spy.statements.last, 'VACUUM');

        final after = _freelist(path);
        // Compacted: a fifth of the file at most is reclaimable now.
        expect(after.free * 5, lessThanOrEqualTo(after.pages));

        // The data survived the upgrade and the compaction.
        final a1 = db.collection(accounts).doc('a1');
        expect(
          (await a1.get())!.data,
          const Account(name: 'Acme', active: true),
        );
        final txnsRef = a1.collection(LegacyTxnAdapter());
        expect(await txnsRef.count(), 400);
        final t7 = await txnsRef.doc('t7').get();
        expect(t7!.data.amountMinor, 107);
        expect(t7.data.memo, 'm' * 900);
      } finally {
        await db.close();
      }
    },
  );

  test('a normal open never compacts, however large its freelist', () async {
    final path = dbPath();
    await buildOldFormatFile(path, txnRows: 400, padding: 900);
    // Upgrade once WITHOUT compaction, so the file carries the freelist.
    final upgraded = await openCocoon(
      path,
      collections: [accounts, LegacyTxnAdapter()],
      options: const CocoonOptions(compactAfterUpgrade: false),
    );
    final share = _freelist(path);
    expect(share.free * 5, greaterThan(share.pages));
    await upgraded.close();

    final spy = _spiedExecutor(path);
    final db = await Cocoon.openWith(
      spy,
      collections: [accounts, LegacyTxnAdapter()],
    );
    try {
      // The format is current, so this open is a normal one: no compaction.
      expect(spy.statements, isNot(contains('VACUUM')));
      expect(_freelist(path).free, share.free);
    } finally {
      await db.close();
    }
  });

  test('compactAfterUpgrade: false leaves the freelist alone', () async {
    final path = dbPath();
    await buildOldFormatFile(path, txnRows: 400, padding: 900);

    final spy = _spiedExecutor(path);
    final db = await Cocoon.openWith(
      spy,
      collections: [accounts, LegacyTxnAdapter()],
      options: const CocoonOptions(compactAfterUpgrade: false),
    );
    try {
      expect(spy.statements, isNot(contains('VACUUM')));
      final after = _freelist(path);
      expect(after.free * 5, greaterThan(after.pages));
      expect(
        await db
            .collection(accounts)
            .doc('a1')
            .collection(LegacyTxnAdapter())
            .count(),
        400,
      );
    } finally {
      await db.close();
    }
  });

  test('a small freelist share stays uncompacted', () async {
    final path = dbPath();
    // The upgrade frees a few pages, but a big legacy table without the path
    // column dilutes the share below a fifth of the file.
    await buildOldFormatFile(
      path,
      txnRows: 2,
      bulkRows: 4000,
      bulkPayloadBytes: 1024,
    );

    final spy = _spiedExecutor(path);
    final db = await Cocoon.openWith(
      spy,
      collections: [accounts, LegacyTxnAdapter()],
    );
    try {
      expect(spy.statements, isNot(contains('VACUUM')));
      final after = _freelist(path);
      expect(after.free * 5, lessThanOrEqualTo(after.pages));
    } finally {
      await db.close();
    }
  });

  test(
    'a failing VACUUM leaves the open successful and the data intact',
    () async {
      final path = dbPath();
      await buildOldFormatFile(path, txnRows: 400, padding: 900);

      final spy = _spiedExecutor(path);
      final failures = <Object>[];
      spy.onStatement = (sql) async {
        if (sql == 'VACUUM') {
          // The disk-full shape: VACUUM needs about the file size in free
          // space, and SQLite gives up.
          throw StateError('disk I/O error: not enough free space');
        }
      };
      final db = await Cocoon.openWith(
        spy,
        collections: [accounts, LegacyTxnAdapter()],
        options: CocoonOptions(onCompactionFailed: failures.add),
      );
      try {
        // The open SUCCEEDED; the failure was reported, not thrown.
        expect(failures, hasLength(1));
        expect(failures.single, isA<StateError>());
        expect(spy.statements, contains('VACUUM'));

        final a1 = db.collection(accounts).doc('a1');
        expect(
          (await a1.get())!.data,
          const Account(name: 'Acme', active: true),
        );
        expect(await a1.collection(LegacyTxnAdapter()).count(), 400);

        // The file keeps the upgrade's (uncompacted) shape and its freelist;
        // the next open does not retry (normal open), a backup would compact.
        final after = _freelist(path);
        expect(after.free * 5, greaterThan(after.pages));
      } finally {
        await db.close();
      }
    },
  );
}
