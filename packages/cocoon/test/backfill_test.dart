/// Backfill-migration tests over a real SQLite database in a temp directory:
/// a pending `BackfillMigration` sets a newly added required field on every
/// existing document — batched, one change row per document, progress
/// reported, and a failing stub rolls the whole open back. Every read below
/// happens cold-cache (a fresh instance or a reopened one), never through a
/// cache the migration could have warmed.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:test/test.dart';

// -- The evolving Staff model ------------------------------------------------

/// The old shape: `name` and `staffId`, no field the backfills set.
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
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(StaffV1 value) {
    final writer = WireWriter()
      ..writeString(1, value.name)
      ..writeString(2, value.staffId);
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

enum StaffKind { basic, gold }

/// The shape for the "rewrite + backfill in one version" test: `staffId`
/// (String, #2) was rewritten to `staffNo` (int, #4), and `title` (String,
/// #3) is added and backfilled — its stub must see the REWRITTEN number.
class StaffRewritten {
  const StaffRewritten({
    required this.name,
    required this.title,
    required this.staffNo,
  });

  final String name;
  final String title;
  final int staffNo;
}

final class StaffRewrittenAdapter extends CollectionAdapter<StaffRewritten> {
  StaffRewrittenAdapter();

  @override
  String get model => 'Staff';

  @override
  final pattern = CollectionPattern.parse('staff');

  @override
  List<FieldColumn<StaffRewritten, Object?>> get columns => [
    FieldColumn.text<StaffRewritten, String>('name', read: (s) => s.name),
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(StaffRewritten value) {
    final writer = WireWriter()
      ..writeString(1, value.name)
      ..writeString(3, value.title)
      ..writeSint64(4, value.staffNo);
    return writer.toBytes();
  }

  @override
  StaffRewritten decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var title = '';
    var staffNo = 0;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 3:
          title = reader.readString();
        case 4:
          staffNo = reader.readSint64();
        default:
          reader.skip(tag.type);
      }
    }
    return StaffRewritten(name: name, title: title, staffNo: staffNo);
  }
}

/// The new shape: `title` (String, #3), `since` (DateTime, #4) and `kind`
/// (enum, #5) are added and required — old documents would read '', the
/// epoch and `StaffKind.basic`.
class StaffV2 {
  const StaffV2({
    required this.name,
    required this.staffId,
    required this.title,
    required this.since,
    required this.kind,
  });

  final String name;
  final String staffId;
  final String title;
  final DateTime since;
  final StaffKind kind;
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
    FieldColumn.text<StaffV2, String>('title', read: (s) => s.title),
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(StaffV2 value) {
    final writer = WireWriter()
      ..writeString(1, value.name)
      ..writeString(2, value.staffId)
      ..writeString(3, value.title)
      ..writeSint64(4, value.since.toUtc().microsecondsSinceEpoch)
      ..writeString(5, value.kind.name);
    return writer.toBytes();
  }

  @override
  StaffV2 decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var staffId = '';
    var title = '';
    var since = DateTime.utc(1970);
    var kind = StaffKind.basic;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 2:
          staffId = reader.readString();
        case 3:
          title = reader.readString();
        case 4:
          since = DateTime.fromMicrosecondsSinceEpoch(
            reader.readSint64(),
            isUtc: true,
          );
        case 5:
          kind = StaffKind.values.byName(reader.readString());
        default:
          reader.skip(tag.type);
      }
    }
    return StaffV2(
      name: name,
      staffId: staffId,
      title: title,
      since: since,
      kind: kind,
    );
  }
}

/// The generated shape of the version-3 backfill list: one stub per added
/// required field, each deriving its value from other fields of the decoded
/// old document.
final staffBackfills = CocoonMigration(
  version: 3,
  backfills: [
    BackfillMigration<StaffV2>(
      model: 'Staff',
      fieldName: 'title',
      fieldNumber: 3,
      fieldType: 'String',
      wire: MigrationWireType.text,
      backfill: (doc) => '${doc.name} <${doc.staffId}>',
    ),
    BackfillMigration<StaffV2>(
      model: 'Staff',
      fieldName: 'since',
      fieldNumber: 4,
      fieldType: 'DateTime',
      wire: MigrationWireType.sint64,
      backfill: (doc) => DateTime.utc(
        int.tryParse(doc.staffId.length > 1 ? doc.staffId.substring(1) : '0') ??
            0,
        1,
        2,
      ),
    ),
    BackfillMigration<StaffV2>(
      model: 'Staff',
      fieldName: 'kind',
      fieldNumber: 5,
      fieldType: 'enum:StaffKind',
      wire: MigrationWireType.text,
      backfill: (doc) =>
          doc.staffId.endsWith('7') ? StaffKind.gold : StaffKind.basic,
    ),
  ],
);

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_backfill_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  test(
    'a pending backfill sets the added fields on every existing document',
    () async {
      final old = await Cocoon.open(
        dbPath(),
        collections: [StaffV1Adapter()],
        schemaVersion: 2,
      );
      await old
          .collection(StaffV1Adapter())
          .doc('s1')
          .set(const StaffV1(name: 'Ada', staffId: 's2017'));
      await old
          .collection(StaffV1Adapter())
          .doc('s2')
          .set(const StaffV1(name: 'Grace', staffId: 's1988'));
      final seqBefore = await old.lastChangeSeq();
      await old.close();

      final db = await Cocoon.open(
        dbPath(),
        collections: [StaffV2Adapter()],
        schemaVersion: 3,
        migrations: [staffBackfills],
      );
      openDbs.add(db);

      final s1 = (await db.collection(StaffV2Adapter()).doc('s1').get())!.data;
      expect(s1.name, 'Ada');
      expect(s1.title, 'Ada <s2017>');
      expect(s1.since, DateTime.utc(2017, 1, 2));
      expect(s1.kind, StaffKind.gold);
      final s2 = (await db.collection(StaffV2Adapter()).doc('s2').get())!.data;
      expect(s2.title, 'Grace <s1988>');
      expect(s2.since, DateTime.utc(1988, 1, 2));
      expect(s2.kind, StaffKind.basic);

      // One change row per backfilled document.
      final changes = await db.changesSince(seqBefore);
      expect(
        [for (final c in changes) (c.path.split('/').last, c.op.name)],
        [('s1', 'set'), ('s2', 'set')],
      );

      // Cold-cache proof: a second instance reads the backfilled values from
      // disk, not from anything the migration left behind.
      await db.close();
      openDbs.remove(db);
      final reopened = await Cocoon.open(
        dbPath(),
        collections: [StaffV2Adapter()],
        schemaVersion: 3,
        migrations: [staffBackfills],
      );
      openDbs.add(reopened);
      final reread =
          (await reopened.collection(StaffV2Adapter()).doc('s1').get())!.data;
      expect(reread.title, 'Ada <s2017>');
      expect(reread.since, DateTime.utc(2017, 1, 2));
      // Reopening is a no-op: the version matches, no further change rows.
      expect((await reopened.changesSince(seqBefore)).length, 2);
    },
  );

  test('progress reports every processed document', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    for (var i = 0; i < 600; i++) {
      await old
          .collection(StaffV1Adapter())
          .doc('s$i')
          .set(StaffV1(name: 'n$i', staffId: 's${2000 + i}'));
    }
    await old.close();

    final progress = <(int, int)>[];
    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV2Adapter()],
      schemaVersion: 3,
      migrations: [staffBackfills],
      onMigrationProgress: (done, total) => progress.add((done, total)),
    );
    openDbs.add(db);
    expect(progress.first, (0, 600));
    expect(progress.last, (600, 600));
    expect(progress, contains((500, 600)));
    var checked = 0;
    for (final doc in (await db.collection(StaffV2Adapter()).get()).docs) {
      final id = int.parse(doc.id.substring(1));
      expect(doc.data.title, 'n$id <s${2000 + id}>');
      checked++;
    }
    expect(checked, 600);
  });

  test('a bare document that predates every field is backfilled too', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: 's1'));
    await old.close();

    // A document with only `name` on the wire — the backfills must still set
    // the added fields (a field rewrite would skip it; a backfill does not).
    final raw = SqliteDatabase(path: dbPath());
    final bare = WireWriter()..writeString(1, 'Old');
    await raw.execute('INSERT INTO staff (id, data, f_name) VALUES (?, ?, ?)', [
      's0',
      bare.toBytes(),
      'Old',
    ]);
    await raw.close();

    final db = await Cocoon.open(
      dbPath(),
      collections: [StaffV2Adapter()],
      schemaVersion: 3,
      migrations: [staffBackfills],
    );
    openDbs.add(db);
    final s0 = (await db.collection(StaffV2Adapter()).doc('s0').get())!.data;
    expect(s0.name, 'Old');
    expect(s0.staffId, '');
    expect(s0.title, 'Old <>');
    expect(s0.since, DateTime.utc(0, 1, 2)); // '' parses as 0
    expect(s0.kind, StaffKind.basic);
  });

  test(
    'a backfill next to a type rewrite: the stub sees the rewritten document',
    () async {
      // v3 rewrites staffId (String, #2) -> staffNo (int, #4) AND backfills
      // title (String, #3). The stub must read the REWRITTEN number.
      final old = await Cocoon.open(
        dbPath(),
        collections: [StaffV1Adapter()],
        schemaVersion: 2,
      );
      await old
          .collection(StaffV1Adapter())
          .doc('s1')
          .set(const StaffV1(name: 'Ada', staffId: '4112'));
      await old.close();

      final db = await Cocoon.open(
        dbPath(),
        collections: [StaffRewrittenAdapter()],
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
                toName: 'staffNo',
                toNumber: 4,
                toType: 'int',
                toWire: MigrationWireType.sint64,
                convert: int.parse,
              ),
            ],
            backfills: [
              BackfillMigration<StaffRewritten>(
                model: 'Staff',
                fieldName: 'title',
                fieldNumber: 3,
                fieldType: 'String',
                wire: MigrationWireType.text,
                backfill: (doc) => 'no ${doc.staffNo}',
              ),
            ],
          ),
        ],
      );
      openDbs.add(db);
      final s1 =
          (await db.collection(StaffRewrittenAdapter()).doc('s1').get())!.data;
      expect(s1.title, 'no 4112'); // the rewritten staffNo, not the old string
      expect(s1.staffNo, 4112);
      expect(s1.name, 'Ada');
    },
  );

  test('a throwing backfill stub rolls the whole open back', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: 's1'));
    final seqBefore = await old.lastChangeSeq();
    await old.close();

    await expectLater(
      Cocoon.open(
        dbPath(),
        collections: [StaffV2Adapter()],
        schemaVersion: 3,
        migrations: [
          CocoonMigration(
            version: 3,
            backfills: [
              BackfillMigration<StaffV2>(
                model: 'Staff',
                fieldName: 'title',
                fieldNumber: 3,
                fieldType: 'String',
                wire: MigrationWireType.text,
                backfill: (doc) => throw StateError('not implemented yet'),
              ),
            ],
          ),
        ],
      ),
      throwsStateError,
    );

    // Nothing changed on disk: version, data and change log are the old ones.
    final reopened = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    openDbs.add(reopened);
    expect(
      (await reopened.collection(StaffV1Adapter()).doc('s1').get())!.data.name,
      'Ada',
    );
    expect(await reopened.changesSince(seqBefore), isEmpty);
  });

  test('a null backfill value fails the open with the field named', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: 's1'));
    await old.close();

    await expectLater(
      Cocoon.open(
        dbPath(),
        collections: [StaffV2Adapter()],
        schemaVersion: 3,
        migrations: [
          CocoonMigration(
            version: 3,
            backfills: [
              BackfillMigration<StaffV2>(
                model: 'Staff',
                fieldName: 'title',
                fieldNumber: 3,
                fieldType: 'String',
                wire: MigrationWireType.text,
                backfill: (doc) => null,
              ),
            ],
          ),
        ],
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'toString',
          contains('Staff.title'),
        ),
      ),
    );

    // The rollback left the old data untouched.
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
      's1',
    );
  });

  test('a backfill value of the wrong type fails the open', () async {
    final old = await Cocoon.open(
      dbPath(),
      collections: [StaffV1Adapter()],
      schemaVersion: 2,
    );
    await old
        .collection(StaffV1Adapter())
        .doc('s1')
        .set(const StaffV1(name: 'Ada', staffId: 's1'));
    await old.close();

    await expectLater(
      Cocoon.open(
        dbPath(),
        collections: [StaffV2Adapter()],
        schemaVersion: 3,
        migrations: [
          CocoonMigration(
            version: 3,
            backfills: [
              BackfillMigration<StaffV2>(
                model: 'Staff',
                fieldName: 'title',
                fieldNumber: 3,
                fieldType: 'String',
                wire: MigrationWireType.text,
                backfill: (doc) => 42, // not a String
              ),
            ],
          ),
        ],
      ),
      throwsA(isA<TypeError>()),
    );
  });

  test('a backfill for an unregistered model is refused', () async {
    await expectLater(
      Cocoon.open(
        dbPath(),
        collections: const [],
        schemaVersion: 1,
        migrations: [staffBackfills],
      ),
      throwsArgumentError,
    );
  });
}
