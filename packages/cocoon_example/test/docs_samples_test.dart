/// Compiles and runs the code shapes the Cocoon docs pages and README show
/// (aggregates, groupBy keys, getAll, bulk loads, backups), so a sample that
/// stops compiling against the real API fails CI instead of shipping.
/// Update it together with the docs.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_example/models.dart';
import 'package:test/test.dart';

import 'support.dart' show accountFixture, txnFixture;

enum STxnStatus { pending, posted, failed }

class STxn {
  const STxn({
    required this.bookedOn,
    required this.amountMinor,
    required this.currency,
    required this.status,
    required this.createdAt,
    this.memo,
  });

  final int bookedOn; // yyyymmdd
  final int amountMinor; // minor units; mirrored-style column (no index)
  final String currency;
  final STxnStatus status;
  final DateTime createdAt;
  final String? memo;
}

final stxnBookedOn = FieldColumn.integer<STxn, int>(
  'bookedOn',
  read: (t) => t.bookedOn,
);
final stxnAmountMinor = FieldColumn.integer<STxn, int>(
  'amountMinor',
  read: (t) => t.amountMinor,
);
final stxnCurrency = FieldColumn.text<STxn, String>(
  'currency',
  read: (t) => t.currency,
);
final stxnStatus = FieldColumn.enumerated<STxn, STxnStatus>(
  'status',
  read: (t) => t.status,
  values: STxnStatus.values,
);
final stxnCreatedAt = FieldColumn.dateTime<STxn, DateTime>(
  'createdAt',
  read: (t) => t.createdAt,
);
final stxnMemo = FieldColumn.text<STxn, String?>(
  'memo',
  read: (t) => t.memo,
  nullable: true,
);
final stxnAccountId = ParamColumn(stxns.pattern, 'accountId');

final class STxnAdapter extends CollectionAdapter<STxn> {
  @override
  String get model => 'STxn';

  @override
  final pattern = CollectionPattern.parse('accounts/{accountId}/txns');

  @override
  List<FieldColumn<STxn, Object?>> get columns => [
    stxnBookedOn,
    stxnAmountMinor,
    stxnCurrency,
    stxnStatus,
    stxnCreatedAt,
    stxnMemo,
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['accountId', '-bookedOn']),
    IndexDef.fromFields(['status', 'bookedOn']),
  ];

  @override
  Uint8List encode(STxn value) {
    final writer = WireWriter();
    writer.writeInt64(1, value.bookedOn);
    writer.writeSint64(2, value.amountMinor);
    writer.writeString(3, value.currency);
    writer.writeString(4, value.status.name);
    writer.writeInt64(5, value.createdAt.toUtc().microsecondsSinceEpoch);
    final memo = value.memo;
    if (memo != null) writer.writeString(6, memo);
    return writer.toBytes();
  }

  @override
  STxn decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var bookedOn = 0;
    var amountMinor = 0;
    var currency = '';
    var status = STxnStatus.pending;
    var createdAt = DateTime.utc(1970);
    String? memo;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          bookedOn = reader.readInt64();
        case 2:
          amountMinor = reader.readSint64();
        case 3:
          currency = reader.readString();
        case 4:
          status = STxnStatus.values.byName(reader.readString());
        case 5:
          createdAt = DateTime.fromMicrosecondsSinceEpoch(
            reader.readInt64(),
            isUtc: true,
          );
        case 6:
          memo = reader.readString();
        default:
          reader.skip(tag.type);
      }
    }
    return STxn(
      bookedOn: bookedOn,
      amountMinor: amountMinor,
      currency: currency,
      status: status,
      createdAt: createdAt,
      memo: memo,
    );
  }
}

class SAccount {
  const SAccount({required this.name});
  final String name;
}

final saccountName = FieldColumn.text<SAccount, String>(
  'name',
  read: (a) => a.name,
);

final class SAccountAdapter extends CollectionAdapter<SAccount> {
  @override
  String get model => 'SAccount';

  @override
  final pattern = CollectionPattern.parse('accounts');

  @override
  List<FieldColumn<SAccount, Object?>> get columns => [saccountName];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(SAccount value) {
    final writer = WireWriter();
    writer.writeString(1, value.name);
    return writer.toBytes();
  }

  @override
  SAccount decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      if (tag.field == 1) {
        name = reader.readString();
      } else {
        reader.skip(tag.type);
      }
    }
    return SAccount(name: name);
  }
}

final stxns = STxnAdapter();
final saccounts = SAccountAdapter();

Directory? _tempDir;

Future<String> tempDbPath() async {
  _tempDir ??= await Directory.systemTemp.createTemp('cocoon_docs_scratch');
  return File(
    '${_tempDir!.path}/docs-${DateTime.now().microsecondsSinceEpoch}.db',
  ).path;
}

STxn stxn({
  int bookedOn = 20260115,
  int amountMinor = -4299,
  String currency = 'MYR',
  STxnStatus status = STxnStatus.posted,
}) => STxn(
  bookedOn: bookedOn,
  amountMinor: amountMinor,
  currency: currency,
  status: status,
  createdAt: DateTime.utc(2026, 1, 15, 12, 30),
);

void main() {
  tearDown(() async {
    final dir = _tempDir;
    _tempDir = null;
    await dir?.delete(recursive: true);
  });

  test('aggregate: count, sum, average, minOf, maxOf', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));
    await a1.collection(stxns).add(stxn(amountMinor: -100));
    await a1.collection(stxns).add(stxn(amountMinor: -300));
    await a1
        .collection(stxns)
        .add(stxn(amountMinor: 50, status: STxnStatus.pending));

    final snapshot = await a1
        .collection(stxns)
        .where(stxnBookedOn.isGreaterThanOrEqualTo(20260101))
        .aggregate([count(), sum(stxnAmountMinor), average(stxnAmountMinor)])
        .get();
    expect(snapshot.count, 3);
    expect(snapshot.getSum(stxnAmountMinor), -350);
    expect(snapshot.getAverage(stxnAmountMinor), closeTo(-116.66, 0.01));

    final extremes = await a1.collection(stxns).aggregate([
      minOf(stxnAmountMinor),
      maxOf(stxnAmountMinor),
    ]).get();
    expect(extremes.getMin(stxnAmountMinor), -300);
    expect(extremes.getMax(stxnAmountMinor), 50);

    // allowFullScan before aggregate, per the query rules.
    final any = await a1.collection(stxns).query().allowFullScan().aggregate([
      count(),
    ]).get();
    expect(any.count, 3);
    await db.close();
  });

  test('groupBy: key, bucket, paramKey, calendar keys, limit', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));
    for (final day in [1, 2, 3]) {
      await a1.collection(stxns).add(stxn(bookedOn: 20260100 + day));
    }
    final statusKey = key(stxnStatus);
    final monthKey = bucket(stxnBookedOn, width: 100);
    final groups = await a1
        .collection(stxns)
        .where(stxnBookedOn.isGreaterThanOrEqualTo(20260101))
        .groupBy([statusKey, monthKey])
        .aggregate([sum(stxnAmountMinor), count()])
        .get();
    for (final group in groups) {
      expect(group.key(monthKey) % 100, 0);
      group.key(statusKey);
      group.getSum(stxnAmountMinor);
      group.count;
    }
    final capped = await a1
        .collection(stxns)
        .groupBy([key(stxnStatus)])
        .aggregate([count()])
        .limit(1)
        .get();
    expect(capped.length, 1);

    final createdAtDay = day(
      stxnCreatedAt,
      utcOffset: const Duration(hours: 8),
    );
    final cal = await a1
        .collection(stxns)
        .groupBy([
          month(stxnCreatedAt, utcOffset: const Duration(hours: 8)),
          year(stxnCreatedAt, utcOffset: const Duration(hours: 8)),
          createdAtDay,
        ])
        .aggregate([count()])
        .get();
    expect(cal.single.key(createdAtDay), isA<int>());
    expect(cal.single.count, 3);

    final GroupKeySpec<STxn, String> parentKey = paramKey(stxnAccountId);
    final perParent = await db
        .collectionGroup(stxns)
        .query()
        .allowFullScan() // a collection group has no single index to anchor
        .groupBy([parentKey])
        .aggregate([count()])
        .get();
    expect(perParent.single.key(parentKey), 'a1');
    await db.close();
  });

  test('aggregate and groupBy watch()', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));
    final totals = await a1
        .collection(stxns)
        .aggregate([sum(stxnAmountMinor)])
        .watch()
        .first;
    expect(totals.getSum(stxnAmountMinor), 0);
    final groups = await a1
        .collection(stxns)
        .groupBy([key(stxnStatus)])
        .aggregate([count()])
        .watch()
        .first;
    expect(groups, isEmpty);
    await db.close();
  });

  test('bulkWriter: queue, flush, close, options', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));

    final bulk = db.bulkWriter(); // 10,000 rows per chunk; indexes deferred
    for (var i = 0; i < 12; i++) {
      bulk.set(a1.collection(stxns).doc('t$i'), stxn()); // synchronous
    }
    await bulk.flush();
    bulk.set(a1.collection(stxns).doc('tX'), stxn());
    bulk.delete(a1.collection(stxns).doc('t1'));
    await bulk.close();

    final tuned = db.bulkWriter(
      const BulkWriterOptions(chunkSize: 5, logChanges: false),
    );
    tuned.update(a1.collection(stxns).doc('t2'), stxn(amountMinor: -1));
    await tuned.close();
    final snaps = await a1.collection(stxns).getAll(['t2', 'nope']);
    expect(snaps.first!.data.amountMinor, -1);
    expect(snaps[1], isNull);
    await db.close();
  });

  test('getAll: collection, db, tx', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    final a2 = db.collection(saccounts).doc('a2');
    await a1.set(const SAccount(name: 'Acme'));
    await a2.set(const SAccount(name: 'Beta'));
    await a1.collection(stxns).add(stxn());
    final t1 = await a1.collection(stxns).add(stxn());

    final byIds = await a1.collection(stxns).getAll(['missing', t1.id, t1.id]);
    expect(byIds[0], isNull);
    expect(byIds[1]!.id, t1.id);
    expect(byIds[2]!.id, t1.id);

    final across = await db.getAll([
      a1.collection(stxns).doc(t1.id),
      a2.collection(stxns).doc('nope'),
    ]);
    expect(across[0], isNotNull);
    expect(across[1], isNull);

    await db.runTransaction((tx) async {
      final refs = [a1.collection(stxns).doc(t1.id)];
      final inTx = await tx.getAll(refs);
      expect(inTx.single!.id, t1.id);
      await tx.set(a1.collection(stxns).doc('fresh'), stxn());
      final uncommitted = await tx.getAll([a1.collection(stxns).doc('fresh')]);
      expect(uncommitted.single, isNotNull);
    });
    await db.close();
  });

  test('transactions: inside the body every access goes through tx', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));

    // WRONG (what the docs page warns about): a call on the database inside
    // the body. It fails immediately with TransactionMisuseError — naming
    // the operation and ending with a `Fix:` line — and rolls the body back.
    await expectLater(
      db.runTransaction((tx) async {
        await a1.set(const SAccount(name: 'Wrong'));
      }),
      throwsA(
        isA<TransactionMisuseError>()
            .having((error) => error.operation, 'operation', 'DocRef.set')
            .having((error) => error.message, 'message', contains('Fix: ')),
      ),
    );
    expect((await a1.get())!.data.name, 'Acme');

    // RIGHT: reads and writes through the transaction object.
    await db.runTransaction((tx) async {
      final snap = await tx.get(a1);
      await tx.set(a1, SAccount(name: '${snap!.data.name} updated'));
    });
    expect((await a1.get())!.data.name, 'Acme updated');
    await db.close();
  });

  test('batch: set/update/delete/commit', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));
    final t1 = await a1.collection(stxns).add(stxn());

    final batch = db.batch();
    batch.set(a1.collection(stxns).doc('t1'), stxn(amountMinor: -9));
    batch.update(t1, stxn(amountMinor: -8));
    batch.delete(a1.collection(stxns).doc('ghost'));
    await batch.commit();
    expect((await t1.get())!.data.amountMinor, -8);
    await db.close();
  });

  test('backupTo, inspectBackup, restoreBackup, instanceId', () async {
    final dir = await Directory.systemTemp.createTemp('cocoon_docs_scratch2');
    final file = '${dir.path}/bank.db';
    final backupPath = '${dir.path}/backup.db';
    var db = await Cocoon.open(file, collections: [saccounts, stxns]);
    final idBefore = db.instanceId;
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));
    final info = await db.backupTo(backupPath);
    expect(info.bytes, greaterThan(0));
    expect(info.lastChangeSeq, greaterThan(0));

    final known = await Cocoon.inspectBackup(backupPath);
    expect(known.cocoonVersion, isNotEmpty);
    expect(known.schemaVersion, isNull);

    await db.close();
    await Cocoon.restoreBackup(
      backup: backupPath,
      path: file,
      collections: [saccounts, stxns],
      keepPrevious: true,
    );
    db = await Cocoon.open(file, collections: [saccounts, stxns]);
    expect(await db.collection(saccounts).doc('a1').get(), isNotNull);
    expect(db.instanceId, isNot(idBefore));
    await db.close();
    expect(File('$file.before-restore').existsSync(), isTrue);
    await dir.delete(recursive: true);
  });

  test('the stacked @Index sample compiles and runs', () async {
    // The models.mdx / README shape: composites declared as stacked @Index
    // lines above the class. models.dart declares txns' and splits'
    // composites that way; the index serves the scoped newest-first query.
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [accounts, txns, splits],
    );
    final a1 = db.collection(accounts).doc('a1');
    await a1.set(accountFixture(name: 'Acme'));
    for (final day in [3, 1, 2]) {
      await a1.collection(txns).add(txnFixture(bookedOn: 20260100 + day));
    }
    final page = await a1
        .collection(txns)
        .orderBy(Txn$.bookedOn, descending: true)
        .get();
    expect(page.docs.map((snapshot) => snapshot.data.bookedOn).toList(), [
      20260103,
      20260102,
      20260101,
    ]);
    await db.close();
  });

  test('CocoonOptions knobs compile', () async {
    const options = CocoonOptions(
      durability: Durability.normal,
      cacheSize: 2000,
      keepChanges: false,
      changeRetention: ChangeRetention(
        maxChanges: 50000,
        maxAge: Duration(days: 30),
      ),
      pageCacheMiB: 64,
      tempStoreInMemory: true,
      walAutoCheckpointPages: 8000,
      compactAfterUpgrade: true,
      onCompactionFailed: _ignore,
      onMissingIndex: MissingIndexMode.scanAndWarn,
    );
    expect(options.durability, Durability.normal);
  });

  test('the debug scanAndWarn fallback fills db.missingIndexes', () async {
    // The queries.mdx shape: a query no declared index serves runs as a full
    // scan while asserts are on, and the report names the ready fix command.
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
      options: const CocoonOptions(
        onMissingIndex: MissingIndexMode.scanAndWarn,
      ),
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));
    await a1.collection(stxns).add(stxn());
    // amountMinor has a column but no index: the scopeless group query runs
    // as a full scan, and the report names the ready fix command.
    final page = await db
        .collectionGroup(stxns)
        .where(stxnAmountMinor.isEqualTo(100))
        .get();
    expect(page.docs, hasLength(0));
    final reports = db.missingIndexes;
    expect(reports, hasLength(1));
    expect(reports.single.model, 'STxn');
    expect(reports.single.fields, ['amountMinor']);
    expect(
      reports.single.fixCommand,
      'dart run cocoon_generator:index add STxn amountMinor',
    );
    await db.close();
  });

  test('change log primitives', () async {
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme'));
    final changes = await db.changesSince(0);
    expect(changes, isNotEmpty);
    final head = await db.lastChangeSeq();
    expect(await db.pruneChanges(upToSeq: head), changes.length);
    expect(await db.earliestChangeSeq(), head + 1);
    expect(db.instanceId, isNotEmpty);
    await db.close();
  });

  test('the isolates.mdx sample compiles and runs', () async {
    // The isolates docs page: the same database API in every isolate mode —
    // open with `auto` here (it exercises both inline and helper routing),
    // then read the routing counters the page's debug section shows.
    final db = await Cocoon.open(
      await tempDbPath(),
      collections: [saccounts, stxns],
      options: const CocoonOptions(
        isolate: CocoonIsolate.auto,
        autoThresholds: CocoonAutoThresholds(
          inlineRows: 200,
          inlineWriteOps: 500,
        ),
      ),
    );
    final a1 = db.collection(saccounts).doc('a1');
    await a1.set(const SAccount(name: 'Acme')); // inline: doc ops never move
    await a1.collection(stxns).add(stxn());
    final page = await a1.collection(stxns).query().limit(50).get();
    expect(page.docs, hasLength(1)); // inline: limit <= inlineRows
    final groups = await a1
        .collection(stxns)
        .groupBy([key(stxnStatus)])
        .aggregate([count()])
        .get();
    expect(groups, hasLength(1)); // small result, but uncapped: the helper
    final stats = db.isolateStats!;
    expect(stats.inlineCalls, greaterThan(0));
    expect(stats.helperCalls, greaterThan(0)); // the uncapped groupBy moved
    await db.close();
  });
}

void _ignore(Object error) {}
