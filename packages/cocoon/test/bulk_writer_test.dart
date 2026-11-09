import 'dart:async';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/naming.dart' show bulkTableName;
import 'package:cocoon/src/engine/schema_sql.dart' show createIndexSql;
import 'package:test/test.dart';

import 'support/models.dart';

/// Lets broadcast-stream deliveries and SQLite round trips land.
Future<void> settle([int ms = 25]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  Future<Cocoon> openDatabase({
    String name = 'bulk.db',
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
    dir = Directory.systemTemp.createTempSync('cocoon_bulk_test');
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

  DocRef<Txn> txnRef(Cocoon db, String id) =>
      db.collection(accounts).doc('a1').collection(txns).doc(id);

  /// The physical index names of the txn table, from sqlite_master.
  Future<Set<String>> storedIndexes(Cocoon db) async {
    final rows = await db.executor.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = 'txn'",
    );
    return {for (final row in rows) row['name']! as String};
  }

  /// The declared (non-scope) secondary index names of the txn adapter.
  Set<String> declaredSecondaryIndexes(Cocoon db) => {
    for (final index in db.registry.entryFor(txns).indexes) index.name,
  };

  group('BulkWriter', () {
    test('set, update and delete mix commits in call order', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');
      final t2 = txnRef(db, 't2');

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 10))
        ..set(t1, txnOf(100))
        ..update(t1, txnOf(200))
        ..set(t2, txnOf(300))
        ..delete(t2)
        ..set(t2, txnOf(400));
      await bulk.close();

      expect((await t1.get())!.data.amountMinor, 200);
      expect((await t2.get())!.data.amountMinor, 400);
    });

    test('a set queued in an earlier chunk satisfies a later update', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1))
        ..set(t1, txnOf(100));
      await bulk.flush();
      bulk.update(t1, txnOf(200));
      await bulk.close();

      expect((await t1.get())!.data.amountMinor, 200);
    });

    test('last write wins for the same document inside a chunk', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');
      final t2 = txnRef(db, 't2');
      final t3 = txnRef(db, 't3');

      final bulk = db.bulkWriter();
      bulk.set(t1, txnOf(100));
      bulk.set(t2, txnOf(300));
      bulk.set(t1, txnOf(200));
      await bulk.close();
      expect((await t1.get())!.data.amountMinor, 200);
      expect((await t2.get())!.data.amountMinor, 300);

      // The same mix through one-chunk-per-op chunks: every commit keeps
      // call order, so the last write still wins.
      final perOp = db.bulkWriter(const BulkWriterOptions(chunkSize: 1));
      perOp.set(t1, txnOf(500));
      perOp.set(t3, txnOf(600));
      perOp.set(t1, txnOf(400));
      await perOp.close();
      expect((await t1.get())!.data.amountMinor, 400);
      expect((await t3.get())!.data.amountMinor, 600);
    });

    test('a delete touching a written document or its ancestor commits in '
        'call order', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final t1 = a1.collection(txns).doc('t1');

      // [set t1, delete a1] in call order: the delete cascades, t1 is gone.
      // Call order is the contract — the delete must land after the set.
      await a1.set(const Account(name: 'Acme', active: true));
      final bulk = db.bulkWriter();
      bulk.set(t1, txnOf(100));
      bulk.delete(a1);
      await bulk.close();
      expect(await a1.get(), isNull);
      expect(await t1.get(), isNull);

      // The reverse order: the delete runs first, the set re-creates t1.
      final a2 = db.collection(accounts).doc('a2');
      final t2 = a2.collection(txns).doc('t2');
      await a2.set(const Account(name: 'Beta', active: true));
      final bulk2 = db.bulkWriter();
      bulk2.delete(a2);
      bulk2.set(t2, txnOf(200));
      await bulk2.close();
      expect(await a2.get(), isNull);
      expect((await t2.get())!.data.amountMinor, 200);
    });

    test('chunks commit in call order, one chunk per chunkSize rows', () async {
      final db = await openDatabase();
      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 3));
      for (var i = 0; i < 7; i++) {
        bulk.set(txnRef(db, 't$i'), txnOf(i * 100));
      }
      // Nothing has committed while the buffer is below the chunk size.
      expect(await db.changesSince(0), isEmpty);
      await bulk.close();

      expect(await db.changesSince(0), hasLength(7));
      for (var i = 0; i < 7; i++) {
        expect((await txnRef(db, 't$i').get())!.data.amountMinor, i * 100);
      }
    });

    test(
      'flush commits the queued operations; later ops keep buffering',
      () async {
        final db = await openDatabase();
        final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 100))
          ..set(txnRef(db, 't1'), txnOf(100))
          ..set(txnRef(db, 't2'), txnOf(200));
        await bulk.flush();

        expect((await txnRef(db, 't1').get())!.data.amountMinor, 100);
        expect((await txnRef(db, 't2').get())!.data.amountMinor, 200);
        expect(await db.changesSince(0), hasLength(2));

        bulk.set(txnRef(db, 't3'), txnOf(300));
        expect(await txnRef(db, 't3').get(), isNull); // still buffered
        await bulk.close();
        expect((await txnRef(db, 't3').get())!.data.amountMinor, 300);
      },
    );

    test(
      'an empty close is a no-op: no bulk meta table, no change rows',
      () async {
        final db = await openDatabase();
        final bulk = db.bulkWriter();
        await bulk.close();

        expect(await db.changesSince(0), isEmpty);
        final tables = await db.executor.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [bulkTableName],
        );
        expect(tables, isEmpty);
      },
    );

    test('close twice throws', () async {
      final db = await openDatabase();
      final bulk = db.bulkWriter()..set(txnRef(db, 't1'), txnOf(100));
      await bulk.close();
      expect(() => bulk.close(), throwsStateError);
    });

    test('using the writer after close throws', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');
      final bulk = db.bulkWriter();
      await bulk.close();

      expect(() => bulk.set(t1, txnOf(100)), throwsStateError);
      expect(() => bulk.update(t1, txnOf(100)), throwsStateError);
      expect(() => bulk.delete(t1), throwsStateError);
      expect(() => bulk.flush(), throwsStateError);
    });

    test('an adapter this database never registered is rejected at queue '
        'time', () async {
      final db = await openDatabase(collections: [accounts]);
      final t1 = db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .doc('t1'); // type-checked, but the txns adapter is unregistered

      final bulk = db.bulkWriter();
      expect(() => bulk.set(t1, txnOf(100)), throwsArgumentError);
      expect(() => bulk.update(t1, txnOf(100)), throwsArgumentError);
      expect(() => bulk.delete(t1), throwsArgumentError);
    });

    test('a failed chunk rolls back whole, and flush and close rethrow the '
        'failure', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');
      final missing = txnRef(db, 'missing');

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 10))
        ..set(t1, txnOf(100))
        ..update(missing, txnOf(200)); // fails the chunk
      await expectLater(bulk.flush(), throwsArgumentError);
      // The failed chunk rolled back: its set did not stick.
      expect(await t1.get(), isNull);

      await expectLater(bulk.close(), throwsArgumentError);
      expect(await t1.get(), isNull);
    });

    test('every committed chunk appends one change row per document, in '
        'order, matching the documents on disk', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');
      final t2 = txnRef(db, 't2');

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1))
        ..set(t1, txnOf(100))
        ..set(t2, txnOf(200))
        ..delete(t2);
      await bulk.close();

      final changes = await db.changesSince(0);
      expect(
        [for (final change in changes) '${change.op} ${change.path}'],
        [
          'ChangeOp.set accounts/a1/txns/t1',
          'ChangeOp.set accounts/a1/txns/t2',
          'ChangeOp.delete accounts/a1/txns/t2',
        ],
      );
      expect((await t1.get())!.data.amountMinor, 100);
      expect(await t2.get(), isNull);
    });

    test('every committed chunk delivers one watch event', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');
      await t1.set(txnOf(50));

      final events = <DocSnapshot<Txn>?>[];
      final sub = t1.watch().listen(events.add);
      await settle();
      final before = events.length;
      expect(before, 1); // the watch's initial snapshot

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 2));
      for (var i = 0; i < 4; i++) {
        bulk.set(t1, txnOf(100 + i));
      }
      await bulk.close();
      await settle();

      // Two chunks, each one commit event whose canonical bytes differ from
      // the last emission.
      expect(events.length, before + 2);
      expect(events.last!.data.amountMinor, 103);
      await sub.cancel();
    });

    test('get by id works during the load, with indexes deferred', () async {
      final db = await openDatabase();
      final t1 = txnRef(db, 't1');

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1))
        ..set(t1, txnOf(100));
      await bulk.flush();
      // The first chunk committed; the indexes are deferred and the writer
      // is still open. get() reads the row through the path index.
      expect((await t1.get())!.data.amountMinor, 100);
      await bulk.close();
    });

    test('Durability normal and full both honour the writer', () async {
      for (final durability in Durability.values) {
        final db = await openDatabase(
          name: 'bulk_${durability.name}.db',
          options: CocoonOptions(durability: durability),
        );
        final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 2));
        for (var i = 0; i < 5; i++) {
          bulk.set(txnRef(db, 't$i'), txnOf(i));
        }
        await bulk.close();
        expect(
          await db.collection(accounts).doc('a1').collection(txns).count(),
          5,
          reason: 'Durability.${durability.name}',
        );
      }
    });
  });

  group('BulkWriter deferred indexes', () {
    test('secondary indexes are absent during the load and present after '
        'close; the scope index is never dropped', () async {
      final db = await openDatabase();
      final secondary = declaredSecondaryIndexes(db);
      final scopeIndex = db.registry.entryFor(txns).scopeIndex.name;

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1))
        ..set(txnRef(db, 't1'), txnOf(100));
      await bulk.flush(); // the first chunk committed: indexes dropped

      var indexes = await storedIndexes(db);
      expect(indexes, isNot(containsAll(secondary)));
      expect(indexes, contains(scopeIndex));
      // The meta table records every dropped index with its DDL.
      final rows = await db.executor.getAll(
        'SELECT tbl, index_name, sql FROM $bulkTableName',
      );
      expect({for (final row in rows) row['index_name']! as String}, secondary);

      await bulk.close();

      indexes = await storedIndexes(db);
      expect(indexes, containsAll(secondary));
      expect(indexes, contains(scopeIndex));
      expect(await db.executor.getAll('SELECT * FROM $bulkTableName'), isEmpty);
      // The data survived the drop/rebuild.
      expect((await txnRef(db, 't1').get())!.data.amountMinor, 100);
    });

    test('a query needing a deferred index waits for close, then returns the '
        'right rows', () async {
      final db = await openDatabase();
      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1));
      bulk.set(txnRef(db, 't1'), txnOf(100));
      bulk.set(
        txnRef(db, 't2'),
        txnOf(200).copyWith(status: TxnStatus.pending),
      );
      await bulk.flush();

      // The (accountId, -bookedOn) index is deferred: the latest-first query
      // holds until the writer closes.
      var completed = false;
      final query = db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .orderBy(txnBookedOn, descending: true)
          .get();
      unawaited(
        query.then<void>((_) {
          completed = true;
        }),
      );
      await settle(50);
      expect(completed, isFalse, reason: 'the query must wait for close');

      await bulk.close();
      final page = await query;
      expect(completed, isTrue);
      expect([for (final doc in page.docs) doc.id], ['t2', 't1']);
    });

    test('a query served by the scope index runs during the load', () async {
      final db = await openDatabase();
      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1));
      bulk.set(txnRef(db, 't1'), txnOf(100));
      bulk.set(txnRef(db, 't2'), txnOf(200));
      await bulk.flush();

      // The scope index (p_account_id, id) is never deferred; the id-ordered
      // query runs against the committed prefix without waiting.
      final page = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .query()
          .limit(10)
          .get();
      expect([for (final doc in page.docs) doc.id], ['t1', 't2']);
      await bulk.close();
    });

    test('no deferral below the cross-over: a pre-filled table keeps its '
        'indexes while a smaller load runs', () async {
      final db = await openDatabase();
      for (var i = 0; i < 6; i++) {
        await txnRef(db, 'seed$i').set(txnOf(i));
      }

      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 2));
      for (var i = 0; i < 4; i++) {
        bulk.set(txnRef(db, 'new$i'), txnOf(100 + i));
      }
      await bulk.flush();

      // 4 buffered rows < 6 stored rows: the writer keeps the indexes.
      expect(
        await storedIndexes(db),
        containsAll(declaredSecondaryIndexes(db)),
      );
      final rows = await db.executor.getAll(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [bulkTableName],
      );
      expect(rows, isEmpty, reason: 'nothing was ever deferred');

      await bulk.close();
      expect(
        await db.collection(accounts).doc('a1').collection(txns).count(),
        10,
      );
    });

    test('a failed chunk still rebuilds the indexes at close', () async {
      final db = await openDatabase();
      final secondary = declaredSecondaryIndexes(db);
      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1))
        ..set(txnRef(db, 't1'), txnOf(100));
      await bulk.flush(); // deferral committed with chunk 1
      bulk.update(txnRef(db, 'nope'), txnOf(200)); // chunk 2 fails
      await expectLater(bulk.close(), throwsArgumentError);

      // close() rebuilt the deferred indexes before rethrowing.
      expect(await storedIndexes(db), containsAll(secondary));
      expect(await db.executor.getAll('SELECT * FROM $bulkTableName'), isEmpty);
      expect((await txnRef(db, 't1').get())!.data.amountMinor, 100);
    });

    test('crash recovery: a reopened database rebuilds the indexes the meta '
        'rows record, before the app sees it', () async {
      final path = '${dir.path}${Platform.pathSeparator}crash.db';
      final secondary = <String>{};

      // Load and "crash": drop the indexes mid-load, abandon the writer.
      var db = await Cocoon.open(path, collections: [accounts, txns, splits]);
      openDbs.add(db);
      secondary.addAll(declaredSecondaryIndexes(db));
      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1))
        ..set(txnRef(db, 't1'), txnOf(100));
      await bulk.flush();
      expect(await storedIndexes(db), isNot(containsAll(secondary)));
      await db.close();
      openDbs.remove(db);

      // Reopen: recovery runs inside the open transaction.
      db = await Cocoon.open(path, collections: [accounts, txns, splits]);
      openDbs.add(db);
      expect(await storedIndexes(db), containsAll(secondary));
      expect(await db.executor.getAll('SELECT * FROM $bulkTableName'), isEmpty);
      expect((await txnRef(db, 't1').get())!.data.amountMinor, 100);
      // And the rebuilt index serves queries again.
      final page = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .orderBy(txnBookedOn, descending: true)
          .get();
      expect([for (final doc in page.docs) doc.id], ['t1']);
    });

    test(
      'crash recovery: leftover meta rows are applied under the current '
      'schema (an index the app no longer declares is not resurrected)',
      () async {
        final path = '${dir.path}${Platform.pathSeparator}stale.db';
        final db = await Cocoon.open(
          path,
          collections: [accounts, txns, splits],
        );
        openDbs.add(db);
        final entry = db.registry.entryFor(txns);
        final declared = declaredSecondaryIndexes(db);
        final keepName = declared.first;
        final keepDdl = createIndexSql(
          entry.table,
          entry.indexes.firstWhere((index) => index.name == keepName),
        );
        await db.close();
        openDbs.remove(db);

        // Simulate a crash plus a schema change: leave meta rows for one still
        // declared index and one index the reopened database no longer
        // declares, with both indexes physically dropped.
        const staleName = 'cx_txn_stale';
        final raw = await Cocoon.open(
          path,
          collections: [accounts, txns, splits],
        );
        openDbs.add(raw);
        await raw.executor.writeTransaction((tx) async {
          // The crashed writer had created the meta table before it dropped
          // the indexes.
          await tx.execute(
            'CREATE TABLE IF NOT EXISTS $bulkTableName '
            '(tbl TEXT NOT NULL, index_name TEXT NOT NULL, sql TEXT NOT NULL)',
          );
          await tx.execute('DROP INDEX IF EXISTS "$keepName"');
          await tx.execute('DROP INDEX IF EXISTS "$staleName"');
          await tx.execute(
            'INSERT INTO $bulkTableName (tbl, index_name, sql) VALUES (?, ?, ?)',
            [
              entry.table,
              staleName,
              'CREATE INDEX IF NOT EXISTS $staleName ON txn (f_currency)',
            ],
          );
          await tx.execute(
            'INSERT INTO $bulkTableName (tbl, index_name, sql) VALUES (?, ?, ?)',
            [entry.table, keepName, keepDdl],
          );
        });
        await raw.close();
        openDbs.remove(raw);

        final reopened = await Cocoon.open(
          path,
          collections: [accounts, txns, splits],
        );
        openDbs.add(reopened);
        final indexes = await storedIndexes(reopened);
        expect(indexes, contains(keepName), reason: 'declared: rebuilt');
        expect(
          indexes,
          isNot(contains(staleName)),
          reason: 'stale: not rebuilt',
        );
        expect(
          await reopened.executor.getAll('SELECT * FROM $bulkTableName'),
          isEmpty,
        );
      },
    );

    test(
      'closing the database fails a query still waiting for a writer',
      () async {
        final db = await openDatabase();
        final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1))
          ..set(txnRef(db, 't1'), txnOf(100));
        await bulk.flush();

        final query = db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .orderBy(txnBookedOn, descending: true)
            .get();
        // The listener attaches before the close, so the failure lands here
        // instead of surfacing unhandled.
        final checked = expectLater(query, throwsStateError);
        await expectLater(db.close(), completes);
        openDbs.remove(db);
        await checked;
      },
    );
  });
}
