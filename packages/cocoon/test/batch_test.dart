import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/sqlite_executor.dart' show SqliteExecutor;
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/spy_executor.dart';

/// Lets broadcast-stream deliveries and SQLite round trips land.
Future<void> settle([int ms = 25]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  Future<Cocoon> openDatabase({
    String name = 'batch.db',
    CocoonOptions options = const CocoonOptions(),
    List<CollectionAdapter<Object?>>? collections,
  }) async {
    final opened = await Cocoon.open(
      '${dir.path}${Platform.pathSeparator}$name',
      collections: collections ?? [accounts, txns, splits],
      options: options,
    );
    openDbs.add(opened);
    return opened;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_batch_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  Txn txnOf(int amountMinor) => Txn(
    bookedOn: 20260115,
    amountMinor: amountMinor,
    rate: 1.0,
    currency: 'MYR',
    status: TxnStatus.posted,
    createdAt: DateTime.utc(2026, 1, 15),
  );

  group('WriteBatch', () {
    test('set, update and delete mix commits in call order', () async {
      final db = await openDatabase();
      final t1 = db.collection(accounts).doc('a1').collection(txns).doc('t1');
      final t2 = db.collection(accounts).doc('a1').collection(txns).doc('t2');

      final batch = db.batch()
        ..set(t1, txnOf(100))
        // Satisfied by the set queued earlier in the same batch.
        ..update(t1, txnOf(200))
        ..set(t2, txnOf(300))
        ..delete(t2)
        ..set(t2, txnOf(400));
      await batch.commit();

      expect((await t1.get())!.data.amountMinor, 200);
      expect((await t2.get())!.data.amountMinor, 400);
    });

    test('a batch update fails when the document does not exist', () async {
      final db = await openDatabase();
      final missing = db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .doc('missing');

      final batch = db.batch()..update(missing, txnOf(100));
      await expectLater(batch.commit(), throwsArgumentError);
      expect(await missing.get(), isNull);
    });

    test('a set earlier in the batch satisfies a later update; a delete in '
        'between fails it and rolls the whole batch back', () async {
      final db = await openDatabase();
      final t1 = db.collection(accounts).doc('a1').collection(txns).doc('t1');

      final ok = db.batch()
        ..set(t1, txnOf(100))
        ..update(t1, txnOf(200));
      await ok.commit();
      expect((await t1.get())!.data.amountMinor, 200);

      final gone = db.batch()
        ..delete(t1)
        ..update(t1, txnOf(300));
      await expectLater(gone.commit(), throwsArgumentError);
      // The failed batch rolled back: the delete did not stick.
      expect((await t1.get())!.data.amountMinor, 200);
    });

    test('a batch update of an EXISTING document lands on disk, not just '
        'in the cache', () async {
      // Regression: the old update statement's bind order was shifted, so
      // the UPDATE silently matched nothing and only the hot cache showed
      // the new value.
      final file = '${dir.path}${Platform.pathSeparator}cold.db';
      Txn txnOf(int amountMinor) => Txn(
        bookedOn: 20260115,
        amountMinor: amountMinor,
        rate: 1.0,
        currency: 'MYR',
        status: TxnStatus.posted,
        createdAt: DateTime.utc(2026, 1, 15),
      );
      final writer = await Cocoon.open(file, collections: [accounts, txns]);
      await writer
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .doc('t1')
          .set(txnOf(100));
      await writer.close();

      final updater = await Cocoon.open(file, collections: [accounts, txns]);
      openDbs.add(updater);
      final t1 = updater
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .doc('t1');
      await (updater.batch()..update(t1, txnOf(200))).commit();
      await updater.close();

      // Cache-cold: a third instance reads what is actually on disk.
      final reader = await Cocoon.open(file, collections: [accounts, txns]);
      openDbs.add(reader);
      expect(
        (await reader
                .collection(accounts)
                .doc('a1')
                .collection(txns)
                .doc('t1')
                .get())!
            .data
            .amountMinor,
        200,
      );
      await reader.close();
    });

    test('a failing batch leaves nothing: no rows, no cache effects, no watch '
        'event, no change rows', () async {
      final db = await openDatabase();
      final t0 = db.collection(accounts).doc('a1').collection(txns).doc('t0');
      final t9 = db.collection(accounts).doc('a1').collection(txns).doc('t9');

      await t0.set(txnOf(100));
      final events = <DocSnapshot<Txn>?>[];
      final sub = t0.watch().listen(events.add);
      await settle();
      final eventsBefore = events.length;
      expect(eventsBefore, 1); // the watch's initial snapshot
      final cacheBefore = db.debugCacheLength;
      final changesBefore = await db.changesSince(0);

      final batch = db.batch()
        ..set(t9, txnOf(200))
        ..update(t0, txnOf(300)) // fine, t0 exists
        ..update(
          db.collection(accounts).doc('a1').collection(txns).doc('nope'),
          txnOf(400),
        ); // fails the batch
      await expectLater(batch.commit(), throwsArgumentError);

      expect(await t9.get(), isNull);
      expect((await t0.get())!.data.amountMinor, 100);
      expect(db.debugCacheLength, cacheBefore);
      await settle();
      expect(events.length, eventsBefore); // nothing for the failed batch
      expect(await db.changesSince(0), changesBefore);
      await sub.cancel();
    });

    test(
      'every queued operation appends one change row, in call order',
      () async {
        final db = await openDatabase();
        final t1 = db.collection(accounts).doc('a1').collection(txns).doc('t1');
        final t2 = db.collection(accounts).doc('a1').collection(txns).doc('t2');

        await (db.batch()
              ..set(t1, txnOf(100))
              ..update(t1, txnOf(200))
              ..set(t2, txnOf(300))
              ..delete(t2))
            .commit();

        final changes = await db.changesSince(0);
        expect(
          [for (final change in changes) '${change.op} ${change.path}'],
          [
            'ChangeOp.set accounts/a1/txns/t1',
            'ChangeOp.set accounts/a1/txns/t1',
            'ChangeOp.set accounts/a1/txns/t2',
            'ChangeOp.delete accounts/a1/txns/t2',
          ],
        );
      },
    );

    test('one batch commit delivers one watch event', () async {
      final db = await openDatabase();
      final t1 = db.collection(accounts).doc('a1').collection(txns).doc('t1');

      final events = <DocSnapshot<Txn>?>[];
      final sub = t1.watch().listen(events.add);
      await settle();
      final eventsBefore = events.length;
      expect(eventsBefore, 1); // the watch's initial snapshot

      await (db.batch()
            ..set(t1, txnOf(100))
            ..update(t1, txnOf(200)))
          .commit();
      await settle();
      expect(events.length, eventsBefore + 1);
      expect(events.last!.data.amountMinor, 200);
      await sub.cancel();
    });

    test('a batch delete cascades to the whole subtree', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final t1 = a1.collection(txns).doc('t1');
      final s1 = t1.collection(splits).doc('s1');
      await a1.set(const Account(name: 'Acme', active: true));
      await t1.set(txnOf(100));
      await s1.set(const Split(label: 'half', shareMinor: 50));

      await (db.batch()..delete(a1)).commit();

      expect(await a1.get(), isNull);
      expect(await t1.get(), isNull);
      expect(await s1.get(), isNull);
      final ops = <String>{
        for (final change in await db.changesSince(0))
          '${change.op} ${change.path}',
      };
      expect(
        ops,
        containsAll(<String>[
          'ChangeOp.delete accounts/a1',
          'ChangeOp.delete accounts/a1/txns/t1',
          'ChangeOp.delete accounts/a1/txns/t1/splits/s1',
        ]),
      );
    });

    test(
      'an adapter this database never registered is rejected at queue time',
      () async {
        final other = await openDatabase(
          name: 'other.db',
          collections: [accounts, txns, splits],
        );
        // A database opened without the txns adapter: its registry knows no
        // `accounts/{accountId}/txns` collection.
        final db = await openDatabase(collections: [accounts]);
        final t1 = other
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .doc('t1');

        final batch = db.batch();
        expect(() => batch.set(t1, txnOf(100)), throwsArgumentError);
        expect(() => batch.update(t1, txnOf(100)), throwsArgumentError);
        expect(() => batch.delete(t1), throwsArgumentError);
        expect(batch.ops, isEmpty);
      },
    );

    test(
      'an empty commit is a no-op: no transaction, no change rows',
      () async {
        final spy = SpyExecutor(
          SqliteExecutor(
            SqliteDatabase(path: '${dir.path}${Platform.pathSeparator}spy.db'),
          ),
        );
        final db = await Cocoon.openWith(spy, collections: [accounts, txns]);
        openDbs.add(db);

        // Only statements from here on belong to the batch: the open's
        // reconcile DDL ran before this mark.
        final mark = spy.statements.length;
        await db.batch().commit();

        expect(spy.statements.sublist(mark), isEmpty);
        expect(await db.changesSince(0), isEmpty);

        // The batch stayed usable for real work afterwards.
        final batch = db.batch()
          ..set(
            db.collection(accounts).doc('a1'),
            const Account(name: 'Acme', active: true),
          );
        await batch.commit();
        expect(
          (await db.collection(accounts).doc('a1').get())!.data.name,
          'Acme',
        );
      },
    );

    test(
      'commit twice throws, and a committed batch refuses new ops',
      () async {
        final db = await openDatabase();
        final a1 = db.collection(accounts).doc('a1');
        final batch = db.batch()
          ..set(a1, const Account(name: 'Acme', active: true));
        await batch.commit();

        await expectLater(batch.commit(), throwsStateError);
        expect(
          () => batch.set(a1, const Account(name: 'Again', active: false)),
          throwsStateError,
        );
        expect(() => batch.delete(a1), throwsStateError);
        // The duplicate commit wrote nothing: the first commit's value stands.
        expect((await a1.get())!.data.name, 'Acme');
      },
    );
  });
}
