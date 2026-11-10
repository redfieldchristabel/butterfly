/// On-device migration tests over a real SQLite database in a temp directory:
/// `Cocoon.open` applies pending migrations once, in order, in one
/// transaction, logs one change row per rewritten document, and rolls the
/// whole open back when a conversion fails.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/naming.dart' show metaTableName;
import 'package:sqlite_async/sqlite_async.dart';
import 'package:test/test.dart';

// -- The evolving Staff model ------------------------------------------------

/// The old shape: `staffId` is a String at field number 2.
class StaffV1 {
  const StaffV1({required this.name, required this.staffId});

  final String name;
  final String staffId;
}

final class StaffV1Adapter extends CollectionAdapter<StaffV1> {
  StaffV1Adapter();

  @override
  String get model => 'Staff';

  @override
  final pattern = CollectionPattern.parse('staff');

  @override
  List<FieldColumn<StaffV1, Object?>> get columns => [
    FieldColumn.text<StaffV1, String>('name', read: (s) => s.name),
    FieldColumn.text<StaffV1, String>('staffId', read: (s) => s.staffId),
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(StaffV1 value) {
    final writer = WireWriter();
    writer.writeString(1, value.name);
    writer.writeString(2, value.staffId);
    return writer.toBytes();
  }

  @override
  StaffV1 decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var staffId = '';
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 2:
          staffId = reader.readString();
        default:
          reader.skip(tag.type);
      }
    }
    return StaffV1(name: name, staffId: staffId);
  }
}

/// The new shape: `staffId` is reserved, `staffUid` is an int at 3.
class StaffV2 {
  const StaffV2({required this.name, required this.staffUid});

  final String name;
  final int staffUid;
}

final class StaffV2Adapter extends CollectionAdapter<StaffV2> {
  StaffV2Adapter();

  @override
  String get model => 'Staff';

  @override
  final pattern = CollectionPattern.parse('staff');

  @override
  List<FieldColumn<StaffV2, Object?>> get columns => [
    FieldColumn.text<StaffV2, String>('name', read: (s) => s.name),
    FieldColumn.integer<StaffV2, int>('staffUid', read: (s) => s.staffUid),
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(StaffV2 value) {
    // Ints are written zigzag, exactly like the code generator emits them.
    final writer = WireWriter();
    writer.writeString(1, value.name);
    writer.writeSint64(3, value.staffUid);
    return writer.toBytes();
  }

  @override
  StaffV2 decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var staffUid = 0;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 3:
          staffUid = reader.readSint64();
        default:
          reader.skip(tag.type);
      }
    }
    return StaffV2(name: name, staffUid: staffUid);
  }
}

/// staffId (String, #2) -> staffUid (int, #3).
final staffMigration = CocoonMigration(
  version: 3,
  fields: [
    FieldMigration.typed<String, int>(
      model: 'Staff',
      fromName: 'staffId',
      fromNumber: 2,
      fromType: 'String',
      fromWire: MigrationWireType.text,
      toName: 'staffUid',
      toNumber: 3,
      toType: 'int',
      toWire: MigrationWireType.sint64,
      convert: (value) => int.parse(value),
    ),
  ],
);

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<int> storedVersion() async {
    final raw = SqliteDatabase(path: dbPath());
    final row = await raw.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      ['schema_version'],
    );
    await raw.close();
    return int.parse(row!['value']! as String);
  }

  Future<List<String>> staffColumns() async {
    final raw = SqliteDatabase(path: dbPath());
    final rows = await raw.getAll('PRAGMA table_info(staff)');
    await raw.close();
    return [for (final row in rows) row['name']! as String];
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_migration_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  test('a fresh database just stores the schema version', () async {
    var converted = 0;
    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV2Adapter()],
      schemaVersion: 3,
      migrations: [
        CocoonMigration(
          version: 3,
          fields: [
            FieldMigration.typed<String, int>(
              model: 'Staff',
              fromName: 'staffId',
              fromNumber: 2,
              fromType: 'String',
              fromWire: MigrationWireType.text,
              toName: 'staffUid',
              toNumber: 3,
              toType: 'int',
              toWire: MigrationWireType.sint64,
              convert: (value) {
                converted++;
                return 0;
              },
            ),
          ],
        ),
      ],
    );
    openDbs.add(db);
    expect(converted, 0);
    expect(await storedVersion(), 3);

    // Writing and reading work as usual after a versioned open.
    await db
        .collection(StaffV2Adapter())
        .doc('s1')
        .set(const StaffV2(name: 'Ada', staffUid: 7));
    expect(
      (await db.collection(StaffV2Adapter()).doc('s1').get())!.data.staffUid,
      7,
    );
  });

  test('a pending migration converts stored documents exactly once', () async {
    // 1. Write documents under the old schema and version.
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    final staff = old.collection(StaffV1Adapter());
    await staff.doc('s1').set(const StaffV1(name: 'Ada', staffId: '4112'));
    await staff.doc('s2').set(const StaffV1(name: 'Grace', staffId: '4113'));
    final seqBefore = await old.lastChangeSeq();
    await old.close();

    // 2. Reopen under the new schema with the migration.
    final adapter = StaffV2Adapter();
    final db = await Cocoon.open(
      dbPath(),
      collections: [adapter],
      schemaVersion: 3,
      migrations: [staffMigration],
    );
    openDbs.add(db);

    final s1 = (await db.collection(adapter).doc('s1').get())!.data;
    expect(s1.name, 'Ada');
    expect(s1.staffUid, 4112);
    final s2 = (await db.collection(adapter).doc('s2').get())!.data;
    expect(s2.name, 'Grace');
    expect(s2.staffUid, 4113);

    expect(await storedVersion(), 3);
    // The old column is gone, the new one carries the converted values, and
    // the untouched `name` column was rebuilt too.
    expect(await staffColumns(), ['id', 'data', 'f_name', 'f_staff_uid']);
    final raw = SqliteDatabase(path: dbPath());
    final columns = await raw.getAll(
      'SELECT id, f_staff_uid FROM staff ORDER BY id',
    );
    await raw.close();
    expect([for (final row in columns) row['f_staff_uid']], [4112, 4113]);

    // One change row per rewritten document (the setup's own rows, written
    // before `seqBefore`, are not included).
    final changes = await db.changesSince(seqBefore);
    expect(changes.map((c) => (c.collection, c.op.name)), [
      ('Staff', 'set'),
      ('Staff', 'set'),
    ]);

    // 3. Reopening is a no-op: the stored version already matches.
    final changesBefore = (await db.changesSince(0)).length;
    await db.close();
    openDbs.remove(db);
    final reopened = await Cocoon.open(
      dbPath(),
      collections: [adapter],
      schemaVersion: 3,
      migrations: [staffMigration],
    );
    openDbs.add(reopened);
    expect(
      (await reopened.collection(adapter).doc('s1').get())!.data.staffUid,
      4112,
    );
    expect((await reopened.changesSince(0)).length, changesBefore);
  });

  test('progress reports every processed document', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    final staff = old.collection(StaffV1Adapter());
    for (var i = 0; i < 600; i++) {
      await staff.doc('s$i').set(StaffV1(name: 'n$i', staffId: '${1000 + i}'));
    }
    await old.close();

    final progress = <(int, int)>[];
    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV2Adapter()],
      schemaVersion: 3,
      migrations: [staffMigration],
      onMigrationProgress: (done, total) => progress.add((done, total)),
    );
    openDbs.add(db);
    expect(progress.first, (0, 600));
    expect(progress.last, (600, 600));
    // Batches of 500: the report after the first batch hit 500.
    expect(progress, contains((500, 600)));
    var converted = 0;
    for (final doc in (await db.collection(StaffV2Adapter()).get()).docs) {
      expect(doc.data.staffUid, 1000 + int.parse(doc.id.substring(1)));
      converted++;
    }
    expect(converted, 600);
  });

  test('a failing conversion rolls the whole open back', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: 'not-a-number'));
    final seqBefore = await old.lastChangeSeq();
    await old.close();

    await expectLater(
      Cocoon.open(
        dbPath(),
        collections: [StaffV2Adapter()],
        schemaVersion: 3,
        migrations: [staffMigration],
      ),
      throwsFormatException,
    );

    // Nothing changed on disk: version, data and columns are the old ones.
    expect(await storedVersion(), 2);
    final reopened = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    openDbs.add(reopened);
    expect(
      (await reopened.collection(StaffV1Adapter()).doc('s1').get())!
          .data
          .staffId,
      'not-a-number',
    );
    expect(await staffColumns(), contains('f_staff_id'));
    expect(await reopened.changesSince(seqBefore), isEmpty);
  });

  test('a database newer than the app refuses to open', () async {
    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await db.close();
    await expectLater(
      Cocoon.open(dbPath(), collections: [StaffV1Adapter()], schemaVersion: 1),
      throwsA(
        isA<SchemaTooNewException>().having(
          (e) => e.toString(),
          'toString',
          contains('version 2'),
        ),
      ),
    );
  });

  test('a migration for an unregistered model is refused', () async {
    await expectLater(
      Cocoon.open(
        dbPath(),
        collections: const [],
        schemaVersion: 1,
        migrations: [staffMigration],
      ),
      throwsArgumentError,
    );
  });

  test('documents without the old field are left untouched', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: '4112'));
    final seqBefore = await old.lastChangeSeq();
    await old.close();

    // A document that predates the field entirely: only field 1 on the wire.
    final raw = SqliteDatabase(path: dbPath());
    final bare = WireWriter()..writeString(1, 'Old');
    await raw.execute(
      'INSERT INTO staff (id, data, f_name, f_staff_id) '
      "VALUES ('s0', ?, 'Old', 'legacy')",
      [bare.toBytes()],
    );
    await raw.close();

    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV2Adapter()],
      schemaVersion: 3,
      migrations: [staffMigration],
    );
    openDbs.add(db);
    final s0 = (await db.collection(StaffV2Adapter()).doc('s0').get())!;
    expect(s0.data.name, 'Old');
    expect(s0.data.staffUid, 0); // the new field's zero value
    final changes = await db.changesSince(seqBefore);
    expect(
      [for (final c in changes) c.path.split('/').last],
      ['s1'], // only s1 was rewritten
    );
  });

  test('several pending versions run in order, in one pass', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 1,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: '4112'));
    await old.close();

    // v2: staffId (String, #2) -> staffUid (int, #3).
    // v3: staffUid (int, #3) -> staffNo (double, #4).
    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV3Adapter()],
      schemaVersion: 3,
      migrations: [
        CocoonMigration(
          version: 2,
          fields: [
            FieldMigration.typed<String, int>(
              model: 'Staff',
              fromName: 'staffId',
              fromNumber: 2,
              fromType: 'String',
              fromWire: MigrationWireType.text,
              toName: 'staffUid',
              toNumber: 3,
              toType: 'int',
              toWire: MigrationWireType.sint64,
              convert: int.parse,
            ),
          ],
        ),
        CocoonMigration(
          version: 3,
          fields: [
            FieldMigration.typed<int, double>(
              model: 'Staff',
              fromName: 'staffUid',
              fromNumber: 3,
              fromType: 'int',
              fromWire: MigrationWireType.sint64,
              toName: 'staffNo',
              toNumber: 4,
              toType: 'double',
              toWire: MigrationWireType.float64,
              convert: (value) => value.toDouble(),
            ),
          ],
        ),
      ],
    );
    openDbs.add(db);
    final s1 = (await db.collection(StaffV3Adapter()).doc('s1').get())!;
    expect(s1.data.name, 'Ada');
    expect(s1.data.staffNo, 4112.0);
    expect(await storedVersion(), 3);
  });

  test('keepChanges: false migrates without writing change rows', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: '4112'));
    final seqBefore = await old.lastChangeSeq();
    await old.close();

    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV2Adapter()],
      schemaVersion: 3,
      migrations: [staffMigration],
      options: const CocoonOptions(keepChanges: false),
    );
    openDbs.add(db);
    expect(
      (await db.collection(StaffV2Adapter()).doc('s1').get())!.data.staffUid,
      4112,
    );
    expect(await db.changesSince(seqBefore), isEmpty);
  });
}

/// The shape after two pending versions: `staffNo` is a double at 4.
class StaffV3 {
  const StaffV3({required this.name, required this.staffNo});

  final String name;
  final double staffNo;
}

final class StaffV3Adapter extends CollectionAdapter<StaffV3> {
  StaffV3Adapter();

  @override
  String get model => 'Staff';

  @override
  final pattern = CollectionPattern.parse('staff');

  @override
  List<FieldColumn<StaffV3, Object?>> get columns => [
    FieldColumn.text<StaffV3, String>('name', read: (s) => s.name),
    FieldColumn.real<StaffV3, double>('staffNo', read: (s) => s.staffNo),
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(StaffV3 value) {
    final writer = WireWriter();
    writer.writeString(1, value.name);
    writer.writeDouble(4, value.staffNo);
    return writer.toBytes();
  }

  @override
  StaffV3 decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var staffNo = 0.0;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 4:
          staffNo = reader.readDouble();
        default:
          reader.skip(tag.type);
      }
    }
    return StaffV3(name: name, staffNo: staffNo);
  }
}
