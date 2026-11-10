import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/sqlite_executor.dart';
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/spy_executor.dart';

/// Every [getAll] behaviour from the step: ordering (with duplicates and
/// missing ids), cache-first trips, per-table chunked statements, the one
/// read transaction per call, and read-your-writes inside a transaction.
void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({
    CocoonOptions options = const CocoonOptions(),
    SpyExecutor? spy,
    List<CollectionAdapter<Object?>>? collections,
  }) async {
    final executor = spy ?? SqliteExecutor(SqliteDatabase(path: dbPath()));
    final opened = await Cocoon.openWith(
      executor,
      collections: collections ?? [accounts, txns, splits],
      options: options,
    );
    openDbs.add(opened);
    return opened;
  }

  /// A fresh instance over the file written so far: same path, empty cache —
  /// the step-20 lesson that read behaviour must be proven cold too.
  Future<Cocoon> reopen() async {
    await openDbs.removeLast().close();
    return openDatabase();
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_getall_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  Txn txnOf(int bookedOn) => Txn(
    bookedOn: bookedOn,
    amountMinor: 1000,
    rate: 1.0,
    currency: 'MYR',
    status: TxnStatus.posted,
    createdAt: DateTime.utc(2026, 1, 15, 10, 30),
  );

  /// Writes [ids] as txns of [accountId] through one batch (the cache
  /// entries left behind are the encoded bytes, like every write leaves).
  Future<void> writeTxns(
    Cocoon db,
    String accountId,
    Iterable<String> ids,
  ) async {
    final batch = db.batch();
    for (final id in ids) {
      batch.set(
        db.collection(accounts).doc(accountId).collection(txns).doc(id),
        txnOf(20260101),
      );
    }
    await batch.commit();
  }

  CollectionRef<Txn> txnsOf(Cocoon db, String accountId) =>
      db.collection(accounts).doc(accountId).collection(txns);

  int readCount(SpyExecutor spy, String table) =>
      spy.statements.where((sql) => sql.contains('FROM $table WHERE')).length;

  test(
    'answers in refs order with nulls for missing ids and duplicates',
    () async {
      final db = await openDatabase();
      await writeTxns(db, 'a1', ['t1', 't2', 't3']);
      final a1 = txnsOf(db, 'a1');

      final snaps = await db.getAll([
        a1.doc('t2'),
        a1.doc('nope'),
        a1.doc('t2'),
        a1.doc('t1'),
      ]);

      expect(snaps, hasLength(4));
      expect(snaps[0]!.id, 't2');
      expect(snaps[1], isNull);
      // Every position is answered, duplicates included.
      expect(snaps[2]!.id, 't2');
      expect(snaps[3]!.id, 't1');
    },
  );

  test(
    'answers from the cache without SQL when every document is hot',
    () async {
      final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
      final db = await openDatabase(spy: spy);
      await writeTxns(db, 'a1', ['t1', 't2']);
      // The writes cached their encoded bytes; getAll must decode and promote
      // them exactly like get() does, and reach SQLite for nothing.
      spy.statements.clear();

      final hot = await db.getAll([
        txnsOf(db, 'a1').doc('t1'),
        txnsOf(db, 'a1').doc('t2'),
      ]);
      expect(hot[0]!.data.amountMinor, 1000);
      expect(hot[1]!.data.amountMinor, 1000);
      expect(spy.statements, isEmpty);

      // Only the miss goes to SQL, and the first call promoted decoded values
      // so the follow-up stays cache-only too.
      final withMiss = await db.getAll([
        txnsOf(db, 'a1').doc('t1'),
        txnsOf(db, 'a1').doc('nope'),
        txnsOf(db, 'a1').doc('t2'),
      ]);
      expect(withMiss[0]!.data.amountMinor, 1000);
      expect(withMiss[1], isNull);
      expect(withMiss[2]!.data.amountMinor, 1000);
      expect(readCount(spy, 'txn'), 1);

      await db.getAll([txnsOf(db, 'a1').doc('t1')]);
      expect(readCount(spy, 'txn'), 1);
    },
  );

  test('fetches cold-cache misses across parents and tables', () async {
    final db = await openDatabase();
    await writeTxns(db, 'a1', ['t1', 't2']);
    await writeTxns(db, 'a2', ['t5']);
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true));
    final cold = await reopen();

    final snaps = await cold.getAll([
      txnsOf(cold, 'a1').doc('t2'),
      txnsOf(cold, 'a2').doc('t5'),
      txnsOf(cold, 'a1').doc('gone'),
      cold.collection(accounts).doc('a1'),
    ]);

    expect(snaps[0]!.id, 't2');
    expect(snaps[1]!.id, 't5');
    expect(snaps[2], isNull);
    expect(snaps[3]!.data, const Account(name: 'Acme', active: true));
    // Every fetched document populated the cache, like get() does.
    expect(cold.debugCacheLength, 3);
  });

  test(
    'one statement per table per chunk: different parents share a chunk',
    () async {
      final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
      final db = await openDatabase(
        spy: spy,
        options: const CocoonOptions(cacheSize: 0),
      );
      await writeTxns(db, 'a1', ['t1']);
      await writeTxns(db, 'a2', ['t5']);
      spy.statements.clear();

      final snaps = await db.getAll([
        txnsOf(db, 'a1').doc('t1'),
        txnsOf(db, 'a2').doc('t5'),
      ]);

      expect(snaps[0]!.id, 't1');
      expect(snaps[1]!.id, 't5');
      final reads = spy.statements
          .where((sql) => sql.contains('FROM txn WHERE'))
          .toList();
      expect(reads, hasLength(1));
      expect(reads.single, contains('(p_account_id, id) IN (VALUES'));
      expect(reads.single, contains(', data'));
    },
  );

  test('a root collection keys by id alone', () async {
    final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
    final db = await openDatabase(
      spy: spy,
      options: const CocoonOptions(cacheSize: 0),
    );
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true));
    spy.statements.clear();

    final snaps = await db.getAll([
      db.collection(accounts).doc('a1'),
      db.collection(accounts).doc('nope'),
    ]);

    expect(snaps[0]!.data.name, 'Acme');
    expect(snaps[1], isNull);
    expect(readCount(spy, 'account'), 1);
    expect(
      spy.statements.firstWhere((sql) => sql.contains('FROM account WHERE')),
      contains('WHERE id IN (?, ?)'),
    );
  });

  test('exactly chunk size is one statement; chunk + 1 is two', () async {
    final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
    final db = await openDatabase(
      spy: spy,
      options: const CocoonOptions(cacheSize: 0),
    );
    final chunkKeys = Cocoon.getAllChunkKeys;
    final ids = [
      for (var i = 0; i < chunkKeys; i++) 't${i.toString().padLeft(4, '0')}',
    ];
    await writeTxns(db, 'a1', ids);

    spy.statements.clear();
    final snaps = await db.getAll([
      for (final id in ids) txnsOf(db, 'a1').doc(id),
    ]);
    expect(snaps, everyElement(isNotNull));
    expect(readCount(spy, 'txn'), 1);

    // One more reference spills into a second chunk — and the answer is
    // still complete and ordered.
    await writeTxns(db, 'a1', ['textra']);
    spy.statements.clear();
    final snaps2 = await db.getAll([
      for (final id in ids) txnsOf(db, 'a1').doc(id),
      txnsOf(db, 'a1').doc('textra'),
    ]);
    expect(snaps2, everyElement(isNotNull));
    expect(snaps2.last!.id, 'textra');
    expect(readCount(spy, 'txn'), 2);
  });

  test('every chunk runs in one read transaction; a concurrent writer lands '
      'after the snapshot', () async {
    final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
    final db = await openDatabase(
      spy: spy,
      options: const CocoonOptions(cacheSize: 0),
    );
    final chunkKeys = Cocoon.getAllChunkKeys;
    final ids = [
      for (var i = 0; i < chunkKeys + 1; i++)
        't${i.toString().padLeft(4, '0')}',
    ];
    await writeTxns(db, 'a1', ids);
    final first = txnsOf(db, 'a1').doc(ids.first);

    // Commit a write while the read is between its chunks. The read
    // transaction holds SQLite's write lock (sqlite_async opens reads with
    // BEGIN IMMEDIATE), so the concurrent writer — a second raw connection
    // on the same file, the only way to write during this instance's read —
    // can only commit after the read's snapshot closed. getAll must answer
    // with the old value, and the write must not be lost.
    final side = SqliteDatabase(path: dbPath());
    var writerStarted = false;
    late final Future<void> writerDone;
    final chunkReadsInsideReadTx = <bool>[];
    spy.onStatement = (sql) async {
      if (!sql.startsWith('SELECT p_account_id, id, data FROM txn')) {
        return;
      }
      chunkReadsInsideReadTx.add(spy.inReadTransaction);
      if (!writerStarted && chunkReadsInsideReadTx.length >= 2) {
        writerStarted = true;
        // Unawaited on purpose: awaiting it inside the read callback would
        // deadlock (the write waits for this read transaction to end).
        writerDone = side.writeTransaction((wtx) async {
          await wtx.execute(
            'UPDATE txn SET data = ?, f_booked_on = ? '
            'WHERE p_account_id = ? AND id = ?',
            [txns.encode(txnOf(20260202)), 20260202, 'a1', ids.first],
          );
        });
      }
    };
    spy.statements.clear();

    final snaps = await db.getAll([
      for (final id in ids) txnsOf(db, 'a1').doc(id),
    ]);
    expect(writerStarted, isTrue);
    await writerDone;
    await side.close();

    expect(snaps, everyElement(isNotNull));
    expect(snaps.first!.data.bookedOn, 20260101);

    // Structural proof of the one-snapshot rule: both chunk statements ran
    // inside ONE executor read transaction.
    expect(chunkReadsInsideReadTx, hasLength(2));
    expect(chunkReadsInsideReadTx, everyElement(isTrue));

    // A read after the snapshot sees the committed write.
    expect((await first.get())!.data.bookedOn, 20260202);
  });

  test(
    'tx.getAll sees the transaction own writes and flushes the buffer',
    () async {
      final db = await openDatabase();
      final a1 = txnsOf(db, 'a1');
      await a1.doc('t0').set(txnOf(20260101));
      final cachedBefore = db.debugCacheLength;

      await db.runTransaction((tx) async {
        final t1 = a1.doc('t1');
        final t2 = a1.doc('t2');
        await tx.set(t1, txnOf(20260101));
        await tx.set(t2, txnOf(20260101));
        // The buffered writes flush before the reads, exactly like tx.get.
        final snaps = await tx.getAll([t1, a1.doc('nope'), t2, a1.doc('t0')]);
        expect(snaps[0]!.data.amountMinor, 1000);
        expect(snaps[1], isNull);
        expect(snaps[2]!.data.amountMinor, 1000);
        expect(snaps[3]!.data.amountMinor, 1000);
        // Transaction reads never touch the shared cache; the writes stay
        // staged until the commit succeeds.
        expect(db.debugCacheLength, cachedBefore);
      });

      expect(db.debugCacheLength, cachedBefore + 2);
      expect((await a1.doc('t1').get())!.data.amountMinor, 1000);
    },
  );

  test('tx.getAll answers vanish on rollback, cache untouched', () async {
    final db = await openDatabase();
    final t1 = txnsOf(db, 'a1').doc('t1');

    await expectLater(
      db.runTransaction((tx) async {
        await tx.set(t1, txnOf(20260101));
        final snaps = await tx.getAll([t1]);
        expect(snaps.single!.data.amountMinor, 1000);
        throw StateError('rollback');
      }),
      throwsStateError,
    );

    expect(await t1.get(), isNull);
    expect(db.debugCacheLength, 0);
  });

  test('empty input answers without SQL', () async {
    final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
    final db = await openDatabase(spy: spy);
    spy.statements.clear();

    expect(await db.getAll<Txn>(const []), isEmpty);
    expect(await txnsOf(db, 'a1').getAll(const []), isEmpty);
    expect(spy.statements, isEmpty);
  });

  test('a fresh instance reads cold and populates its cache', () async {
    final db = await openDatabase();
    await writeTxns(db, 'a1', ['t1', 't2']);
    final cold = await reopen();

    expect(cold.debugCacheLength, 0);
    final snaps = await cold.getAll([
      txnsOf(cold, 'a1').doc('t1'),
      txnsOf(cold, 'a1').doc('t2'),
      // A duplicate on a cold cache shares the one fetch.
      txnsOf(cold, 'a1').doc('t1'),
    ]);
    expect(snaps[0]!.id, 't1');
    expect(snaps[1]!.id, 't2');
    expect(identical(snaps[2], snaps[0]), isTrue);
    expect(cold.debugCacheLength, 2);
    // The populated cache serves the next call.
    final again = await cold.getAll([txnsOf(cold, 'a1').doc('t1')]);
    expect(again.single!.data.amountMinor, 1000);
  });

  test('collection.getAll(ids) matches db.getAll of its refs', () async {
    final db = await openDatabase();
    await writeTxns(db, 'a1', ['t1', 't2']);

    final sugar = await txnsOf(db, 'a1').getAll(['t2', 'nope', 't1']);
    final refs = await db.getAll([
      txnsOf(db, 'a1').doc('t2'),
      txnsOf(db, 'a1').doc('nope'),
      txnsOf(db, 'a1').doc('t1'),
    ]);

    expect(sugar[0]!.id, refs[0]!.id);
    expect(sugar[1], isNull);
    expect(sugar[2]!.id, refs[2]!.id);
  });

  test('mixed collections answer through DocRef<Object>, one statement per '
      'table', () async {
    final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
    final db = await openDatabase(
      spy: spy,
      options: const CocoonOptions(cacheSize: 0),
    );
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true));
    await writeTxns(db, 'a1', ['t1']);
    spy.statements.clear();

    final snaps = await db.getAll<Object>([
      db.collection(accounts).doc('a1'),
      txnsOf(db, 'a1').doc('t1'),
      txnsOf(db, 'a1').doc('nope'),
    ]);

    expect(snaps[0]!.data, const Account(name: 'Acme', active: true));
    expect((snaps[1]!.data as Txn).amountMinor, 1000);
    expect(snaps[2], isNull);
    expect(readCount(spy, 'account'), 1);
    expect(readCount(spy, 'txn'), 1);
  });

  test('a reference whose adapter was not registered at open throws', () async {
    final db = await openDatabase(collections: [accounts]);
    final splitsPath = CollectionPattern.parse(
      'accounts/{accountId}/txns/{txnId}/splits',
    ).resolve({'accountId': 'a1', 'txnId': 't1'}).doc('s1');

    await expectLater(
      db.getAll([DocRef<Split>(db, splits, splitsPath)]),
      throwsArgumentError,
    );
  });

  test(
    'a reference whose path is not of its collection pattern throws',
    () async {
      final db = await openDatabase();
      // A txn path handed to the splits adapter: not a document of that
      // collection, so there is no scope key to fetch by.
      final broken = DocRef<Split>(db, splits, txnsOf(db, 'a1').doc('t9').path);

      await expectLater(db.getAll([broken]), throwsArgumentError);
    },
  );
}
