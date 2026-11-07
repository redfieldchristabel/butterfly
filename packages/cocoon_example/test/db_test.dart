/// End-to-end tests over a real SQLite database in a temp directory: every
/// generated adapter round-trips through the engine, documents written by an
/// older schema version decode with defaults, and queries run through the
/// generated typed handles.
library;

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_example/models.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late String dbPath;

  setUp(() async {
    dbPath = await tempDbPath();
  });

  tearDown(cleanUpTempDir);

  test('every field type round-trips through a real database', () async {
    final db = await Cocoon.open(dbPath, collections: [accounts, txns, splits]);
    final a1 = db.collection(accounts).doc('a1');
    await a1.set(accountFixture(name: 'Acme Holdings'));

    final txnRef = await a1.collection(txns).add(txnFixture());
    final splitRef = await txnRef
        .collection(splits)
        .add(splitFixture(label: 'rent', shareMinor: 700));

    // Reads through the engine give byte-identical values.
    final account = (await a1.get())!;
    expect(
      accounts.encode(account.data),
      accounts.encode(accountFixture(name: 'Acme Holdings')),
    );
    expect(account.ref.path.path, 'accounts/a1');

    final txn = (await txnRef.get())!;
    expect(txn.data.status, TxnStatus.posted);
    expect(txn.data.amountMinor, -4299);
    expect(txn.data.rate, 4.123456);
    expect(txn.data.labels, ['food', 'weekly']);
    expect(txn.data.memo, 'groceries');
    expect(txn.data.meta, {
      'card': 'visa-4242',
      'channel': 'web',
      'batch': 'b-17',
    });
    expect(txn.data.receipt, isNotNull);

    final split = (await splitRef.get())!;
    expect(split.data.label, 'rent');
    expect(split.data.shareMinor, 700);
    expect(split.ref.path.path, startsWith('accounts/a1/txns/'));

    await db.close();

    // Reopening the same file reads the same values from disk.
    final reopened = await Cocoon.open(
      dbPath,
      collections: [accounts, txns, splits],
    );
    final accountBack = (await reopened.collection(accounts).doc('a1').get())!;
    expect(
      accounts.encode(accountBack.data),
      accounts.encode(accountFixture(name: 'Acme Holdings')),
    );
    await reopened.close();
  });

  test(
    'a document written before a field existed decodes with defaults',
    () async {
      // 1. Write full-schema documents through the engine.
      final db = await Cocoon.open(
        dbPath,
        collections: [accounts, txns, splits],
      );
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(accountFixture(name: 'Acme Holdings'));
      await a1
          .collection(txns)
          .doc('t-old')
          .set(txnFixture(bookedOn: 20260110, currency: 'SGD'));
      final olderTxn = a1.collection(txns).doc('t-older');
      await olderTxn.set(txnFixture(bookedOn: 20260105));
      await db.close();

      // 2. Replace the blobs with what an older schema version wrote:
      //    t-old has fields 2-6 and 10 (no memo, labels, receipt) and
      //    t-older has fields 2-5 and 10 (also no rate).
      final rawDb = raw.sqlite3.open(dbPath);
      final update = rawDb.prepare('UPDATE txn SET data = ? WHERE path = ?');
      void overwrite(String path, void Function(WireWriter) write) {
        final writer = WireWriter();
        write(writer);
        update.execute([writer.toBytes(), path]);
      }

      overwrite('accounts/a1/txns/t-old', (w) {
        w.writeSint64(2, -1200);
        w.writeString(3, 'SGD');
        w.writeString(4, TxnStatus.pending.name);
        w.writeSint64(5, DateTime.utc(2026, 1, 10, 8).microsecondsSinceEpoch);
        w.writeDouble(6, 0.31);
        w.writeSint64(10, 20260110);
      });
      overwrite('accounts/a1/txns/t-older', (w) {
        w.writeSint64(2, 500);
        w.writeString(3, 'MYR');
        w.writeString(4, TxnStatus.posted.name);
        w.writeSint64(5, DateTime.utc(2026, 1, 5, 9).microsecondsSinceEpoch);
        w.writeSint64(10, 20260105);
      });
      update.close();
      rawDb.close();

      // 3. Reopen and read: missing fields fall back to defaults.
      final reopened = await Cocoon.open(
        dbPath,
        collections: [accounts, txns, splits],
      );
      final tOld =
          (await reopened
                  .collection(accounts)
                  .doc('a1')
                  .collection(txns)
                  .doc('t-old')
                  .get())!
              .data;
      expect(tOld.bookedOn, 20260110);
      expect(tOld.amountMinor, -1200);
      expect(tOld.currency, 'SGD');
      expect(tOld.status, TxnStatus.pending);
      expect(tOld.rate, 0.31);
      expect(tOld.memo, isNull);
      expect(tOld.receipt, isNull);
      expect(tOld.labels, isEmpty);
      expect(tOld.meta, isEmpty); // written before the field existed

      final tOlder =
          (await reopened
                  .collection(accounts)
                  .doc('a1')
                  .collection(txns)
                  .doc('t-older')
                  .get())!
              .data;
      // `rate` never existed in this blob: proto3 zero.
      expect(tOlder.rate, 0.0);

      await reopened.close();
      // The refs above prove the engine reads through the generated adapters;
      // nothing else to clean up here.
    },
  );

  test('queries run through the generated handles', () async {
    final db = await Cocoon.open(dbPath, collections: [accounts, txns, splits]);
    final a1 = db.collection(accounts).doc('a1');
    final a2 = db.collection(accounts).doc('a2');
    await a1.set(accountFixture(name: 'Alpha'));
    await a2.set(accountFixture(name: 'Beta'));

    Txn txn(int bookedOn, TxnStatus status) =>
        txnFixture(bookedOn: bookedOn, status: status);
    await a1.collection(txns).doc('t1').set(txn(20260101, TxnStatus.posted));
    await a1.collection(txns).doc('t2').set(txn(20260103, TxnStatus.failed));
    await a1.collection(txns).doc('t3').set(txn(20260105, TxnStatus.posted));
    await a2.collection(txns).doc('t4').set(txn(20260102, TxnStatus.posted));
    await a2.collection(txns).doc('t5').set(txn(20260104, TxnStatus.pending));

    // Enum equality + descending order: a collection-group query filtered by
    // status alone is served by the ['status', 'bookedOn'] index.
    final posted = await db
        .collectionGroup(txns)
        .where(Txn$.status.isEqualTo(TxnStatus.posted))
        .orderBy(Txn$.bookedOn, descending: true)
        .get();
    expect(posted.docs.map((d) => d.id), ['t3', 't4', 't1']);

    // A range over bookedOn with the parent scoped automatically.
    final recent = await a1
        .collection(txns)
        .where(Txn$.bookedOn.isGreaterThanOrEqualTo(20260102))
        .orderBy(Txn$.bookedOn, descending: true)
        .get();
    expect(recent.docs.map((d) => d.id), ['t3', 't2']);

    // Collection-group query filtered by the path param handle.
    final a2Txns = await db
        .collectionGroup(txns)
        .where(Txn$.accountId.isEqualTo('a2'))
        .orderBy(Txn$.bookedOn, descending: true)
        .get();
    expect(a2Txns.docs.map((d) => d.id), ['t5', 't4']);

    // Keyset pagination with the cursor the page hands back.
    final page1 = await a1
        .collection(txns)
        .orderBy(Txn$.bookedOn)
        .limit(2)
        .get();
    expect(page1.docs.map((d) => d.id), ['t1', 't2']);
    expect(page1.nextCursor, isNotNull);
    final page2 = await a1
        .collection(txns)
        .orderBy(Txn$.bookedOn)
        .limit(2)
        .startAfter(page1.nextCursor!)
        .get();
    expect(page2.docs.map((d) => d.id), ['t3']);
    expect(page2.nextCursor, isNull);
    expect(await a1.collection(txns).count(), 3);

    // Splits order by their own index, scoped to their txn.
    await a1
        .collection(txns)
        .doc('t3')
        .collection(splits)
        .doc('s1')
        .set(splitFixture(label: 'rent', shareMinor: 700));
    await a1
        .collection(txns)
        .doc('t3')
        .collection(splits)
        .doc('s2')
        .set(splitFixture(label: 'food', shareMinor: 300));
    await a1
        .collection(txns)
        .doc('t3')
        .collection(splits)
        .doc('s3')
        .set(splitFixture(label: 'transport', shareMinor: 1000));
    final ordered = await a1
        .collection(txns)
        .doc('t3')
        .collection(splits)
        .orderBy(Split$.shareMinor, descending: true)
        .get();
    expect(ordered.docs.map((d) => d.id), ['s3', 's1', 's2']);

    // Accounts query by their indexed name.
    final beta = await db
        .collection(accounts)
        .where(Account$.name.isEqualTo('Beta'))
        .get();
    expect(beta.docs.single.id, 'a2');

    await db.close();
  });

  test('deleting an account cascades to its whole subtree', () async {
    final db = await Cocoon.open(dbPath, collections: [accounts, txns, splits]);
    final a1 = db.collection(accounts).doc('a1');
    final a2 = db.collection(accounts).doc('a2');
    await a1.set(accountFixture(name: 'Alpha'));
    await a2.set(accountFixture(name: 'Beta'));
    await a1.collection(txns).doc('t1').set(txnFixture());
    await a1
        .collection(txns)
        .doc('t1')
        .collection(splits)
        .doc('s1')
        .set(splitFixture(label: 'rent', shareMinor: 700));
    await a2.collection(txns).doc('t4').set(txnFixture());

    await a1.delete();

    expect(await a1.get(), isNull);
    expect(await a1.collection(txns).doc('t1').get(), isNull);
    expect(
      await a1.collection(txns).doc('t1').collection(splits).doc('s1').get(),
      isNull,
    );
    // A sibling account and its documents survive.
    expect((await a2.get())!.data.name, 'Beta');
    expect(await a2.collection(txns).doc('t4').get(), isNotNull);

    await db.close();
  });
}
