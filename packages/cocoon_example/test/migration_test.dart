/// End-to-end schema migration test over a real SQLite database: a database
/// written by the v1 schema (where `Txn.bookedOn` was a String at field
/// number 1) migrates to the generated v2 adapters when opened with the
/// generated `cocoonMigrations` list, exactly once, with progress reported
/// and the query indexes rebuilt.
library;

import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_example/cocoon_migrations/migrations.dart'
    show cocoonMigrations;
import 'package:cocoon_example/cocoon_schema.g.dart' show cocoonSchemaVersion;
import 'package:cocoon_example/models.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:test/test.dart';

import 'support.dart';

/// The v1 shape of [Txn]: `bookedOn` was an ISO date String at field number
/// 1 (`2026-11-07`). Every other field is unchanged in v2.
class TxnV1 {
  const TxnV1({
    required this.bookedOn,
    required this.amountMinor,
    required this.currency,
    required this.status,
    required this.createdAt,
    required this.rate,
    this.memo,
    this.labels = const [],
    this.receipt,
  });

  final String bookedOn;
  final int amountMinor;
  final String currency;
  final TxnStatus status;
  final DateTime createdAt;
  final double rate;
  final String? memo;
  final List<String> labels;
  final Uint8List? receipt;
}

/// The v1 adapter: `bookedOn` encoded as text at number 1, everything else
/// byte-for-byte like the generated v2 codec.
final class TxnV1Adapter extends CollectionAdapter<TxnV1> {
  @override
  String get model => 'Txn';

  @override
  final pattern = CollectionPattern.parse('accounts/{accountId}/txns');

  @override
  List<FieldColumn<TxnV1, Object?>> get columns => [
    FieldColumn.text<TxnV1, String>('bookedOn', read: (t) => t.bookedOn),
    FieldColumn.enumerated<TxnV1, TxnStatus>(
      'status',
      read: (t) => t.status,
      values: TxnStatus.values,
    ),
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(const ['accountId', '-bookedOn']),
    IndexDef.fromFields(const ['status', 'bookedOn']),
  ];

  @override
  Uint8List encode(TxnV1 value) {
    final writer = WireWriter();
    writer.writeString(1, value.bookedOn);
    writer.writeSint64(2, value.amountMinor);
    writer.writeString(3, value.currency);
    writer.writeString(4, value.status.name);
    writer.writeSint64(5, value.createdAt.toUtc().microsecondsSinceEpoch);
    writer.writeDouble(6, value.rate);
    final memo = value.memo;
    if (memo != null) {
      writer.writeString(7, memo);
    }
    writer.writeMessage(8, (nested) {
      var i = 1;
      for (final label in value.labels) {
        nested.writeString(i, label);
        i++;
      }
    });
    final receipt = value.receipt;
    if (receipt != null) {
      writer.writeBytes(9, receipt);
    }
    return writer.toBytes();
  }

  @override
  TxnV1 decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var bookedOn = '';
    var amountMinor = 0;
    var currency = '';
    var status = TxnStatus.values.first;
    var createdAt = DateTime.utc(1970);
    var rate = 0.0;
    String? memo;
    var labels = const <String>[];
    Uint8List? receipt;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          bookedOn = reader.readString();
        case 2:
          amountMinor = reader.readSint64();
        case 3:
          currency = reader.readString();
        case 4:
          status = TxnStatus.values.byName(reader.readString());
        case 5:
          createdAt = DateTime.fromMicrosecondsSinceEpoch(
            reader.readSint64(),
            isUtc: true,
          );
        case 6:
          rate = reader.readDouble();
        case 7:
          memo = reader.readString();
        case 8:
          final labelsReader = reader.readMessage();
          final items = <String>[];
          while (!labelsReader.isAtEnd) {
            labelsReader.readTag();
            items.add(labelsReader.readString());
          }
          labels = items;
        case 9:
          receipt = reader.readBytes();
        default:
          reader.skip(tag.type);
      }
    }
    return TxnV1(
      bookedOn: bookedOn,
      amountMinor: amountMinor,
      currency: currency,
      status: status,
      createdAt: createdAt,
      rate: rate,
      memo: memo,
      labels: labels,
      receipt: receipt,
    );
  }
}

void main() {
  late String dbPath;

  setUp(() async {
    dbPath = await tempDbPath();
  });

  tearDown(cleanUpTempDir);

  test('a database written by the v1 schema migrates on open', () async {
    // 1. Write documents under the v1 schema and version.
    final old = await Cocoon.open(
      dbPath,
      collections: [accounts, TxnV1Adapter(), splits],
      schemaVersion: 1,
    );
    final oldA1 = old.collection(accounts).doc('a1');
    await oldA1.set(accountFixture(name: 'Acme Holdings'));
    final v1Txns = oldA1.collection(TxnV1Adapter());
    await v1Txns
        .doc('t1')
        .set(
          TxnV1(
            bookedOn: '2026-11-07',
            amountMinor: -4299,
            currency: 'MYR',
            status: TxnStatus.posted,
            createdAt: DateTime.utc(2026, 1, 15, 12, 0, 30, 250, 999),
            rate: 4.123456,
            memo: 'groceries',
            labels: const ['food', 'weekly'],
            receipt: Uint8List.fromList(const [9, 8, 7, 0, 255]),
          ),
        );
    await v1Txns
        .doc('t2')
        .set(
          TxnV1(
            bookedOn: '2026-01-10',
            amountMinor: 1200,
            currency: 'SGD',
            status: TxnStatus.pending,
            createdAt: DateTime.utc(2026, 1, 10, 8),
            rate: 0.31,
          ),
        );
    final seqBefore = await old.lastChangeSeq();
    await old.close();

    // 2. Reopen with the generated adapters and the generated migration
    //    list: the pending step rewrites both documents inside the open.
    expect(cocoonSchemaVersion, 3);
    expect(cocoonMigrations, hasLength(1));
    final progress = <(int, int)>[];
    final db = await Cocoon.open(
      dbPath,
      collections: [accounts, txns, splits],
      schemaVersion: cocoonSchemaVersion,
      migrations: cocoonMigrations,
      onMigrationProgress: (done, total) => progress.add((done, total)),
    );

    final a1 = db.collection(accounts).doc('a1');
    final t1 = (await a1.collection(txns).doc('t1').get())!.data;
    expect(t1.bookedOn, 20261107); // '2026-11-07' converted
    expect(t1.amountMinor, -4299);
    expect(t1.currency, 'MYR');
    expect(t1.status, TxnStatus.posted);
    expect(t1.createdAt, DateTime.utc(2026, 1, 15, 12, 0, 30, 250, 999));
    expect(t1.rate, 4.123456);
    expect(t1.memo, 'groceries');
    expect(t1.labels, ['food', 'weekly']);
    expect(t1.receipt, Uint8List.fromList(const [9, 8, 7, 0, 255]));

    final t2 = (await a1.collection(txns).doc('t2').get())!.data;
    expect(t2.bookedOn, 20260110); // '2026-01-10' converted
    expect(t2.amountMinor, 1200);
    expect(t2.memo, isNull);
    expect(t2.labels, isEmpty);
    expect(t2.receipt, isNull);

    // The rewritten `bookedOn` column is an integer column now, carrying the
    // converted values; the query indexes were rebuilt after the rewrite.
    final rawDb = raw.sqlite3.open(dbPath);
    final columnType = rawDb
        .select(
          "SELECT type FROM pragma_table_info('txn') "
          "WHERE name = 'f_booked_on'",
        )
        .single['type'];
    expect(columnType, 'INTEGER');
    expect(
      [
        // Path order within one concrete collection is id order.
        for (final row in rawDb.select(
          'SELECT f_booked_on FROM txn ORDER BY id',
        ))
          row['f_booked_on'],
      ],
      [20261107, 20260110],
    );
    final txnIndexes = [
      for (final row in rawDb.select(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'txn'",
      ))
        row['name']! as String,
    ];
    expect(txnIndexes, contains('cx_txn_scope'));
    expect(
      txnIndexes.where(
        (name) => name.startsWith('cx_txn_') && name != 'cx_txn_scope',
      ),
      hasLength(2), // both declared query indexes were rebuilt
    );
    rawDb.close();

    // One change row per rewritten document.
    final changes = await db.changesSince(seqBefore);
    expect(changes.map((c) => c.path), [
      'accounts/a1/txns/t1',
      'accounts/a1/txns/t2',
    ]);

    // Progress covers the two documents of the migrated table.
    expect(progress.first, (0, 2));
    expect(progress.last, (2, 2));
    await db.close();

    // 3. Reopening the migrated database is a no-op: the version matches, so
    //    no conversion runs and no new change rows appear.
    final reopened = await Cocoon.open(
      dbPath,
      collections: [accounts, txns, splits],
      schemaVersion: cocoonSchemaVersion,
      migrations: cocoonMigrations,
    );
    expect(
      (await reopened
              .collection(accounts)
              .doc('a1')
              .collection(txns)
              .doc('t1')
              .get())!
          .data
          .bookedOn,
      20261107,
    );
    expect((await reopened.changesSince(seqBefore)).length, changes.length);
    await reopened.close();

    // 4. The database is at version 2: an app declaring v1 refuses to open.
    await expectLater(
      Cocoon.open(
        dbPath,
        collections: [accounts, txns, splits],
        schemaVersion: 1,
      ),
      throwsA(isA<SchemaTooNewException>()),
    );
  });
}
