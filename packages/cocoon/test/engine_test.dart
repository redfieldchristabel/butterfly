import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/executor.dart' show CocoonExecutor;
import 'package:cocoon/src/engine/naming.dart' show metaTableName;
import 'package:cocoon/src/engine/query.dart' show QueryOrder, planQuery;
import 'package:cocoon/src/engine/schema_sql.dart'
    show RegistryEntry, SchemaRegistry;
import 'package:cocoon/src/engine/sqlite_executor.dart';
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/spy_executor.dart';

final allTypesTxn = Txn(
  bookedOn: 20260115,
  amountMinor: -12345,
  rate: 3.75,
  currency: 'MYR',
  status: TxnStatus.posted,
  createdAt: DateTime.utc(2026, 1, 15, 10, 30),
  memo: 'groceries',
);

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({
    CocoonOptions options = const CocoonOptions(),
    List<CollectionAdapter<Object?>>? collections,
  }) async {
    final opened = await Cocoon.open(
      dbPath(),
      collections: collections ?? [accounts, txns, splits],
      options: options,
    );
    openDbs.add(opened);
    return opened;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_engine_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  group('open and reconcile', () {
    test(
      'open on a fresh file creates tables, scope and declared indexes',
      () async {
        final executor = SqliteExecutor(SqliteDatabase(path: dbPath()));
        openDbs.add(
          await Cocoon.openWith(
            executor,
            collections: [accounts, txns, splits],
          ),
        );

        final tables = await executor.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        );
        expect(
          tables.map((row) => row['name']),
          containsAll(['account', 'txn', 'split', metaTableName]),
        );

        final entry = SchemaRegistry.build([
          accounts,
          txns,
          splits,
        ]).byPattern(txns.pattern)!;
        final txnIndexes = await executor.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'txn'",
        );
        expect(
          txnIndexes.map((row) => row['name']),
          containsAll([
            entry.scopeIndex.name,
            ...entry.indexes.map((index) => index.name),
          ]),
        );
      },
    );

    test('reopen with no changes runs no DDL', () async {
      final db = await openDatabase();
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      await db.close();
      openDbs.remove(db);

      final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
      final reopened = await Cocoon.openWith(
        spy,
        collections: [accounts, txns, splits],
      );
      openDbs.add(reopened);
      expect(spy.ddlStatements, isEmpty);
      // The reconciler still read the stored shape.
      expect(
        spy.statements.any(
          (sql) => sql.contains('FROM $metaTableName WHERE key = ?'),
        ),
        isTrue,
      );
      // And the data survived.
      final snap = await reopened.collection(accounts).doc('a1').get();
      expect(snap!.data, const Account(name: 'Acme', active: true));
    });

    test('adding a field column backfills it from existing rows', () async {
      // v1: no memo column yet, but the wire already carries the field.
      final db = await openDatabase(
        collections: [accounts, txnsWithoutMemo, splits],
      );
      final a1 = db.collection(accounts).doc('a1');
      final t1 = await a1.collection(txnsWithoutMemo).add(allTypesTxn);
      final t2 = await a1
          .collection(txnsWithoutMemo)
          .add(
            Txn(
              bookedOn: 20260115,
              amountMinor: -12345,
              rate: 3.75,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2026, 1, 15, 10, 30),
            ),
          );
      await db.close();
      openDbs.remove(db);

      // v2: the memo column (and its index) appears; the reconciler adds the
      // column and backfills every row from the stored wire bytes.
      final reopened = await openDatabase();
      final roundtripped = await t1.get();
      expect(roundtripped!.data.memo, 'groceries');
      final nullMemo = await t2.get();
      expect(nullMemo!.data.memo, isNull);

      // The backfilled column is queryable through its index.
      final page = await reopened
          .collectionGroup(txns)
          .where(txnMemo.isEqualTo('groceries'))
          .get();
      expect(page.docs.map((d) => d.id), [t1.id]);
    });

    test(
      'dropping a field column drops its index but keeps documents',
      () async {
        final db = await openDatabase();
        final a1 = db.collection(accounts).doc('a1');
        await a1.collection(txns).add(allTypesTxn);
        await db.close();
        openDbs.remove(db);

        // Introspect the file before reopening it with the smaller adapter.
        final probe = SqliteExecutor(SqliteDatabase(path: dbPath()));
        final columns = await probe.getAll('PRAGMA table_info(txn)');
        expect(columns.map((row) => row['name']), contains('f_memo'));
        await probe.close();

        final reopened = await openDatabase(
          collections: [accounts, txnsWithoutMemo, splits],
        );

        final after = SqliteExecutor(SqliteDatabase(path: dbPath()));
        final columnsAfter = await after.getAll('PRAGMA table_info(txn)');
        expect(
          columnsAfter.map((row) => row['name']),
          isNot(contains('f_memo')),
        );
        final registry = SchemaRegistry.build([
          accounts,
          txnsWithoutMemo,
          splits,
        ]);
        final entry = registry.byPattern(txnsWithoutMemo.pattern)!;
        final indexNames = await after.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'txn' AND name LIKE 'cx_%'",
        );
        expect(
          indexNames.map((row) => row['name']),
          containsAll(entry.indexes.map((index) => index.name)),
        );
        await after.close();

        final snap = await reopened
            .collection(accounts)
            .doc('a1')
            .collection(txnsWithoutMemo)
            .get();
        expect(snap.docs, hasLength(1));
        expect(snap.docs.single.data.bookedOn, allTypesTxn.bookedOn);
      },
    );

    test('tables without a registered adapter are left alone', () async {
      final probe = SqliteExecutor(SqliteDatabase(path: dbPath()));
      await probe.execute('CREATE TABLE user_tooling (id TEXT)');
      await probe.close();

      final db = await openDatabase();
      final count = await db
          .collection(accounts)
          .orderBy(accountName)
          .allowFullScan()
          .count();
      expect(count, 0);
    });
  });

  group('document CRUD', () {
    test('set, get, re-set (upsert) and delete', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');

      await a1.set(const Account(name: 'Acme', active: true, note: 'first'));
      final snap = await a1.get();
      expect(snap, isNotNull);
      expect(snap!.id, 'a1');
      expect(snap.ref, a1);
      expect(
        snap.data,
        const Account(name: 'Acme', active: true, note: 'first'),
      );

      await a1.set(const Account(name: 'Acme', active: false));
      final updated = await a1.get();
      expect(updated!.data, const Account(name: 'Acme', active: false));

      expect(await db.collection(accounts).doc('missing').get(), isNull);

      await a1.delete();
      expect(await a1.get(), isNull);
    });

    test('add mints a UUIDv7 id and roundtrips every field type', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final ref = await a1.collection(txns).add(allTypesTxn);
      expect(
        ref.id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );

      final snap = await ref.get();
      expect(snap!.data, allTypesTxn);
      expect(snap.data.createdAt.isUtc, isTrue);

      // A local-time DateTime survives as the same instant, read back in UTC.
      final localInstant = DateTime(2026, 3, 1, 8, 15);
      final localRef = await a1
          .collection(txns)
          .add(
            Txn(
              bookedOn: 20260301,
              amountMinor: 5,
              rate: 1.0,
              currency: 'SGD',
              status: TxnStatus.pending,
              createdAt: localInstant,
            ),
          );
      final localSnap = await localRef.get();
      expect(
        localSnap!.data.createdAt.microsecondsSinceEpoch,
        localInstant.microsecondsSinceEpoch,
      );
      expect(localSnap.data.createdAt.isUtc, isTrue);
    });

    test('docRef.collection rejects a non-child adapter', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      expect(
        () => a1.collection(accounts),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('not a subcollection of accounts'),
          ),
        ),
      );
      expect(() => a1.collection(txns), returnsNormally);
    });

    test('db.collection rejects a subcollection adapter', () async {
      final db = await openDatabase();
      expect(
        () => db.collection(txns),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('doc(...).collection(...)'),
          ),
        ),
      );
    });

    test('unregistered adapters are rejected', () async {
      final db = await openDatabase(collections: [accounts, txns]);
      expect(() => db.collectionGroup(splits), throwsA(isA<ArgumentError>()));
      final a1 = db.collection(accounts).doc('a1');
      expect(() => a1.collection(splits), throwsA(isA<ArgumentError>()));
    });
  });

  group('scoping and collection groups', () {
    test('a1.txns never include a2.txns and vice versa', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final a2 = db.collection(accounts).doc('a2');
      final t1 = await a1.collection(txns).add(allTypesTxn);
      final t2 = await a2.collection(txns).add(allTypesTxn);

      final a1Page = await a1.collection(txns).get();
      expect(a1Page.docs.map((d) => d.id), [t1.id]);
      final a2Page = await a2.collection(txns).get();
      expect(a2Page.docs.map((d) => d.id), [t2.id]);
      expect(t1.id, isNot(t2.id));
    });

    test(
      'collection group queries cross parents and filter by param',
      () async {
        final db = await openDatabase();
        final a1 = db.collection(accounts).doc('a1');
        final a2 = db.collection(accounts).doc('a2');
        final t1 = await a1.collection(txns).add(allTypesTxn);
        final t2 = await a2.collection(txns).add(allTypesTxn);
        await a2.collection(txns).add(allTypesTxn.copyWith(currency: 'USD'));

        final everything = await db
            .collectionGroup(txns)
            .query()
            .allowFullScan()
            .get();
        expect(everything.docs, hasLength(3));

        // The param filter is served by the implicit (p_account_id, id) index.
        final a2Only = await db
            .collectionGroup(txns)
            .where(txnAccountId.isEqualTo('a2'))
            .get();
        expect(a2Only.docs.map((d) => d.id), contains(t2.id));
        expect(a2Only.docs.map((d) => d.id), isNot(contains(t1.id)));
        expect(a2Only.docs, hasLength(2));

        final usd = await db
            .collectionGroup(txns)
            .where(txnCurrency.isEqualTo('USD'))
            .get();
        expect(usd.docs, hasLength(1));
      },
    );

    test('collection groups can be ordered by a declared index', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final a2 = db.collection(accounts).doc('a2');
      final first = await a1
          .collection(txns)
          .add(
            Txn(
              bookedOn: 20260102,
              amountMinor: 1,
              rate: 1.5,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2026, 1, 1),
              memo: 'first',
            ),
          );
      final second = await a2
          .collection(txns)
          .add(
            Txn(
              bookedOn: 20260101,
              amountMinor: 2,
              rate: 1.5,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2026, 1, 1),
              memo: 'second',
            ),
          );

      final page = await db
          .collectionGroup(txns)
          .where(txnStatus.isEqualTo(TxnStatus.posted))
          .orderBy(txnBookedOn, descending: true)
          .get();
      expect(page.docs.map((d) => d.id), [first.id, second.id]);
    });
  });

  group('cascade delete', () {
    test('deletes the subtree but not prefix-siblings like a10', () async {
      final db = await openDatabase();
      final accountsRef = db.collection(accounts);
      final a1 = accountsRef.doc('a1');
      final a10 = accountsRef.doc('a10');
      await a1.set(const Account(name: 'one', active: true));
      await a10.set(const Account(name: 'ten', active: true));

      final t1 = await a1.collection(txns).add(allTypesTxn);
      final s1 = await t1
          .collection(splits)
          .add(const Split(label: 'main', shareMinor: 50));
      final t10 = await a10.collection(txns).add(allTypesTxn);
      final s10 = await t10
          .collection(splits)
          .add(const Split(label: 'main', shareMinor: 50));

      await a1.delete();

      expect(await a1.get(), isNull);
      expect(await t1.get(), isNull);
      expect(await s1.get(), isNull);
      // a10 is not a descendant of a1 despite the shared prefix.
      expect(await a10.get(), isNotNull);
      expect(await t10.get(), isNotNull);
      expect(await s10.get(), isNotNull);
    });

    test('cascade delete works inside a transaction', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final t1 = await a1.collection(txns).add(allTypesTxn);
      await t1
          .collection(splits)
          .add(const Split(label: 'main', shareMinor: 50));

      await db.runTransaction((tx) => tx.delete(a1));

      expect(
        await db.collectionGroup(splits).query().allowFullScan().count(),
        0,
      );
      expect(await t1.get(), isNull);
    });
  });

  group('transactions', () {
    test('reads see the transaction writes; commit persists them', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);

      await db.runTransaction((tx) async {
        final ref = await tx.add(txnsRef, allTypesTxn);
        final inside = await tx.get(ref);
        expect(inside, isNotNull);
        expect(inside!.data, allTypesTxn);
        await tx.set(ref, allTypesTxn.copyWith(status: TxnStatus.failed));
        final updated = await tx.get(ref);
        expect(updated!.data.status, TxnStatus.failed);
      });

      final after = await txnsRef.get();
      expect(after.docs.single.data.status, TxnStatus.failed);
    });

    test('an exception rolls back the database and the cache', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final existing = await txnsRef.add(allTypesTxn);

      // Prime the cache with the pre-transaction value.
      expect((await existing.get())!.data.status, TxnStatus.posted);
      final cachedLength = db.debugCacheLength;
      expect(cachedLength, greaterThan(0));

      await expectLater(
        db.runTransaction<String>((tx) async {
          await tx.set(
            existing,
            allTypesTxn.copyWith(status: TxnStatus.failed),
          );
          await tx.add(txnsRef, allTypesTxn.copyWith(currency: 'USD'));
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );

      // Database: the update and the add are gone.
      final snap = await existing.get();
      expect(snap!.data.status, TxnStatus.posted);
      expect(await txnsRef.count(), 1);
      // Cache: exactly the pre-transaction documents, pre-transaction values.
      expect(db.debugCacheLength, cachedLength);
      expect((await existing.get())!.data.status, TxnStatus.posted);
    });

    test('add and delete in one transaction', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      await db.runTransaction((tx) async {
        final ref = await tx.add(txnsRef, allTypesTxn);
        await tx.delete(ref);
      });
      expect(await txnsRef.count(), 0);
    });
  });

  group('cache', () {
    test('evicts least recently used documents at capacity', () async {
      final db = await openDatabase(options: const CocoonOptions(cacheSize: 3));
      final refs = <DocRef<Txn>>[];
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      for (var i = 0; i < 5; i++) {
        refs.add(await txnsRef.add(allTypesTxn.copyWith(amountMinor: i)));
      }
      for (final ref in refs) {
        final snap = await ref.get();
        expect(snap, isNotNull);
      }
      expect(db.debugCacheLength, 3);

      // Evicted or not, every read is correct.
      for (var i = 0; i < refs.length; i++) {
        final snap = await refs[i].get();
        expect(snap!.data.amountMinor, i);
      }
      expect(db.debugCacheLength, 3);
    });

    test('writes update and deletes evict cached documents', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final ref = await txnsRef.add(allTypesTxn);
      await txnsRef.add(allTypesTxn.copyWith(currency: 'USD'));
      await ref.get();
      expect(db.debugCacheLength, 2);

      await ref.set(allTypesTxn.copyWith(status: TxnStatus.failed));
      expect((await ref.get())!.data.status, TxnStatus.failed);

      await db.collection(accounts).doc('a1').delete();
      expect(db.debugCacheLength, 0);
      expect(await ref.get(), isNull);
    });

    test('cacheSize 0 disables the cache', () async {
      final db = await openDatabase(options: const CocoonOptions(cacheSize: 0));
      final ref = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .add(allTypesTxn);
      await ref.get();
      expect(db.debugCacheLength, 0);
      expect((await ref.get())!.data, allTypesTxn);
    });
  });

  group('filters', () {
    late DocRef<Txn> t1;
    late DocRef<Txn> t2;
    late DocRef<Txn> t3;

    setUp(() async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      Txn make({
        required int bookedOn,
        required int amountMinor,
        required String currency,
        required TxnStatus status,
        String? memo,
      }) => Txn(
        bookedOn: bookedOn,
        amountMinor: amountMinor,
        rate: 1.25,
        currency: currency,
        status: status,
        createdAt: DateTime.utc(2026, 1, 1),
        memo: memo,
      );
      t1 = await txnsRef.add(
        make(
          bookedOn: 20260101,
          amountMinor: 100,
          currency: 'MYR',
          status: TxnStatus.posted,
          memo: 'alpha',
        ),
      );
      t2 = await txnsRef.add(
        make(
          bookedOn: 20260102,
          amountMinor: -50,
          currency: 'USD',
          status: TxnStatus.pending,
        ),
      );
      t3 = await txnsRef.add(
        make(
          bookedOn: 20260102,
          amountMinor: 75,
          currency: 'MYR',
          status: TxnStatus.failed,
          memo: 'beta',
        ),
      );
    });

    Future<Set<String>> ids(CocoonQuery<Txn> query) async =>
        (await query.get()).docs.map((d) => d.id).toSet();

    test('isEqualTo', () async {
      final db = openDbs.single;
      expect(
        await ids(db.collectionGroup(txns).where(txnCurrency.isEqualTo('MYR'))),
        {t1.id, t3.id},
      );
    });

    test('isNotEqualTo (SQL semantics exclude NULLs)', () async {
      final db = openDbs.single;
      expect(
        await ids(
          db.collectionGroup(txns).where(txnMemo.isNotEqualTo('alpha')),
        ),
        {t3.id},
      );
      expect(
        await ids(
          db.collectionGroup(txns).where(txnCurrency.isNotEqualTo('MYR')),
        ),
        {t2.id},
      );
    });

    test(
      'isLessThan / isLessThanOrEqualTo (unindexed field, full scan)',
      () async {
        final db = openDbs.single;
        expect(
          await ids(
            db
                .collectionGroup(txns)
                .where(txnAmountMinor.isLessThan(75))
                .allowFullScan(),
          ),
          {t2.id},
        );
        expect(
          await ids(
            db
                .collectionGroup(txns)
                .where(txnAmountMinor.isLessThanOrEqualTo(75))
                .allowFullScan(),
          ),
          {t2.id, t3.id},
        );
      },
    );

    test('isGreaterThan / isGreaterThanOrEqualTo (unindexed field)', () async {
      final db = openDbs.single;
      expect(
        await ids(
          db
              .collectionGroup(txns)
              .where(txnAmountMinor.isGreaterThan(75))
              .allowFullScan(),
        ),
        {t1.id},
      );
      expect(
        await ids(
          db
              .collectionGroup(txns)
              .where(txnAmountMinor.isGreaterThanOrEqualTo(75))
              .allowFullScan(),
        ),
        {t1.id, t3.id},
      );
    });

    test('whereIn', () async {
      final db = openDbs.single;
      expect(
        await ids(
          db.collectionGroup(txns).where(txnCurrency.whereIn(['USD', 'EUR'])),
        ),
        {t2.id},
      );
      expect(
        () => txnCurrency.whereIn(List.generate(31, (i) => 'C$i')),
        throwsArgumentError,
      );
      expect(() => txnCurrency.whereIn([]), throwsArgumentError);
    });

    test('isNull / isNotNull', () async {
      final db = openDbs.single;
      expect(await ids(db.collectionGroup(txns).where(txnMemo.isNull())), {
        t2.id,
      });
      expect(await ids(db.collectionGroup(txns).where(txnMemo.isNotNull())), {
        t1.id,
        t3.id,
      });
    });

    test('rejects null equality and non-nullable null checks', () {
      expect(() => txnMemo.isEqualTo(null), throwsArgumentError);
      expect(() => txnCurrency.isNull(), throwsArgumentError);
      expect(() => txnCurrency.isNotNull(), throwsArgumentError);
    });

    test('a redundant param filter on a scoped query is allowed', () async {
      final db = openDbs.single;
      // eq {accountId, currency} is not a prefix of any declared index, so
      // the strict rule declines it; the opt-out makes the intent explicit.
      final page = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .where(txnAccountId.isEqualTo('a1'))
          .where(txnCurrency.isEqualTo('MYR'))
          .allowFullScan()
          .get();
      expect(page.docs.map((d) => d.id).toSet(), {t1.id, t3.id});
    });
  });

  group('ordering', () {
    test('default order is id ascending', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final ids = <String>[];
      for (var i = 0; i < 10; i++) {
        final ref = await txnsRef.add(allTypesTxn);
        ids.add(ref.id);
      }
      final page = await txnsRef.get();
      expect(page.docs.map((d) => d.id), ids);
    });

    test('descending and ascending order use the same index', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      Txn on(int bookedOn) => Txn(
        bookedOn: bookedOn,
        amountMinor: 1,
        rate: 1.5,
        currency: 'MYR',
        status: TxnStatus.posted,
        createdAt: DateTime.utc(2026, 1, 1),
        memo: 'b$bookedOn',
      );
      final first = await txnsRef.add(on(20260101));
      await txnsRef.add(on(20260201));
      final last = await txnsRef.add(on(20260301));

      final desc = await txnsRef.orderBy(txnBookedOn, descending: true).get();
      expect(desc.docs.first.id, last.id);
      expect(desc.docs.last.id, first.id);

      final asc = await txnsRef.orderBy(txnBookedOn).get();
      expect(asc.docs.first.id, first.id);
      expect(asc.docs.last.id, last.id);
    });

    test('ordering by a nullable column throws', () async {
      final db = await openDatabase();
      expect(
        () =>
            db.collection(accounts).doc('a1').collection(txns).orderBy(txnMemo),
        throwsArgumentError,
      );
    });

    test('ordering twice by the same column throws', () async {
      final db = await openDatabase();
      expect(
        () => db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .orderBy(txnBookedOn)
            .orderBy(txnBookedOn, descending: true),
        throwsArgumentError,
      );
    });

    test('unknown fields in filters and orders throw', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final stranger = FieldColumn.text<Txn, String>(
        'notAField',
        read: (t) => t.currency,
      );
      expect(() => txnsRef.where(stranger.isEqualTo('x')), throwsArgumentError);
      expect(() => txnsRef.orderBy(stranger), throwsArgumentError);
    });
  });

  group('pagination', () {
    Future<List<(String, Txn)>> seed({
      required int count,
      required String accountId,
    }) async {
      final db = openDbs.last;
      final seeded = <(String, Txn)>[];
      await db.runTransaction((tx) async {
        final txnsRef = db.collection(accounts).doc(accountId).collection(txns);
        for (var i = 0; i < count; i++) {
          final value = Txn(
            bookedOn: 20260101 + (i % 10),
            amountMinor: i,
            rate: 1.5,
            currency: 'MYR',
            status: TxnStatus.posted,
            createdAt: DateTime.utc(2026, 1, 1),
            memo: 'm$i',
          );
          final ref = await tx.add(txnsRef, value);
          seeded.add((ref.id, value));
        }
      });
      return seeded;
    }

    List<(String, Txn)> sortedByBookedOn(
      List<(String, Txn)> seeded, {
      required bool descending,
    }) {
      final sorted = [...seeded]
        ..sort((a, b) {
          final byDate = a.$2.bookedOn.compareTo(b.$2.bookedOn);
          final byId = a.$1.compareTo(b.$1);
          final asc = byDate != 0 ? byDate : byId;
          return descending ? -asc : asc;
        });
      return sorted;
    }

    test(
      '1,000 docs with ties: every doc exactly once, in order, both ways',
      () async {
        await openDatabase();
        final seeded = await seed(count: 1000, accountId: 'a1');
        final txnsRef = openDbs.single
            .collection(accounts)
            .doc('a1')
            .collection(txns);

        Future<List<String>> walk(CocoonQuery<Txn> query, int pageSize) async {
          final collected = <String>[];
          var cursor = query.limit(pageSize);
          while (true) {
            final page = await cursor.get();
            collected.addAll(page.docs.map((d) => d.id));
            final next = page.nextCursor;
            if (next == null) {
              break;
            }
            cursor = query.limit(pageSize).startAfter(next);
          }
          return collected;
        }

        final expectedDesc = sortedByBookedOn(seeded, descending: true);
        final descIds = await walk(
          txnsRef.orderBy(txnBookedOn, descending: true),
          137,
        );
        expect(descIds, hasLength(1000));
        expect(descIds.toSet(), hasLength(1000));
        expect(descIds, expectedDesc.map((e) => e.$1));

        final expectedAsc = sortedByBookedOn(seeded, descending: false);
        final ascIds = await walk(txnsRef.orderBy(txnBookedOn), 250);
        expect(ascIds, hasLength(1000));
        expect(ascIds, expectedAsc.map((e) => e.$1));
      },
    );

    test('cursors are reusable across page sizes', () async {
      await openDatabase();
      final seeded = await seed(count: 40, accountId: 'a1');
      final txnsRef = openDbs.single
          .collection(accounts)
          .doc('a1')
          .collection(txns);
      final expectedDesc = sortedByBookedOn(seeded, descending: true);

      final base = txnsRef.orderBy(txnBookedOn, descending: true);
      final firstPage = await base.limit(7).get();
      expect(firstPage.docs, hasLength(7));
      final secondPage = await base
          .limit(13)
          .startAfter(firstPage.nextCursor!)
          .get();
      expect(secondPage.docs, hasLength(13));
      expect(
        secondPage.docs.map((d) => d.id),
        expectedDesc.skip(7).take(13).map((e) => e.$1),
      );
    });

    test('a cursor from another query is rejected', () async {
      await openDatabase();
      await seed(count: 20, accountId: 'a1');
      final txnsRef = openDbs.single
          .collection(accounts)
          .doc('a1')
          .collection(txns);
      final page = await txnsRef
          .orderBy(txnBookedOn, descending: true)
          .limit(5)
          .get();

      // Same index, different sort direction: a different fingerprint.
      final other = txnsRef.orderBy(txnBookedOn);
      await expectLater(
        other.startAfter(page.nextCursor!).get(),
        throwsA(isA<CursorMismatchException>()),
      );
    });

    test('a scoped cursor cannot page another parent', () async {
      await openDatabase();
      await seed(count: 20, accountId: 'a1');
      await seed(count: 5, accountId: 'a2');
      final a1 = openDbs.single.collection(accounts).doc('a1');
      final a2 = openDbs.single.collection(accounts).doc('a2');
      final page = await a1
          .collection(txns)
          .orderBy(txnBookedOn, descending: true)
          .limit(5)
          .get();
      await expectLater(
        a2
            .collection(txns)
            .orderBy(txnBookedOn, descending: true)
            .startAfter(page.nextCursor!)
            .get(),
        throwsA(isA<CursorMismatchException>()),
      );
    });
  });

  group('count', () {
    test('counts matching documents under the index rule', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final seeded = <Txn>[];
      for (var i = 0; i < 30; i++) {
        final value = allTypesTxn.copyWith(
          status: i.isEven ? TxnStatus.posted : TxnStatus.pending,
          bookedOn: 20260101 + (i % 5),
        );
        seeded.add(value);
        await txnsRef.add(value);
      }
      int expected(bool Function(Txn) predicate) =>
          seeded.where(predicate).length;

      expect(await txnsRef.count(), 30);
      expect(
        await db
            .collectionGroup(txns)
            .where(txnCurrency.isEqualTo('MYR'))
            .count(),
        expected((t) => t.currency == 'MYR'),
      );
      // eq status + range bookedOn, no sort keys: the (status, bookedOn, id)
      // index serves it, with the range taking the slot after the prefix.
      expect(
        await db
            .collectionGroup(txns)
            .where(txnStatus.isEqualTo(TxnStatus.posted))
            .where(txnBookedOn.isGreaterThan(20260102))
            .count(),
        expected((t) => t.status == TxnStatus.posted && t.bookedOn > 20260102),
      );
    });

    test('count obeys the index rule', () async {
      final db = await openDatabase();
      final query = db.collectionGroup(txns).where(txnRate.isGreaterThan(0));
      await expectLater(query.count(), throwsA(isA<MissingIndexException>()));
      expect(await query.allowFullScan().count(), 0);
    });
  });

  group('EXPLAIN QUERY PLAN', () {
    void expectIndexed(List<Map<String, Object?>> plan) {
      for (final row in plan) {
        final detail = row['detail']! as String;
        if (detail.startsWith('SCAN') || detail.startsWith('SEARCH')) {
          expect(
            detail,
            contains('USING'),
            reason: 'Plan row without an index: $detail',
          );
        }
      }
    }

    RegistryEntry txnEntry() =>
        SchemaRegistry.build([accounts, txns, splits]).byPattern(txns.pattern)!;

    Future<List<Map<String, Object?>>> explainPlan(
      CocoonExecutor executor, {
      required RegistryEntry entry,
      required CollectionPath? scopePath,
      required List<QueryFilter> filters,
      required List<QueryOrder> orders,
      int? limit,
      String? cursor,
    }) async {
      final plan = planQuery(
        entry: entry,
        scopePath: scopePath,
        filters: filters,
        orders: orders,
        limit: limit,
        cursor: cursor,
        fullScan: false,
      );
      return executor.getAll('EXPLAIN QUERY PLAN ${plan.sql}', plan.args);
    }

    test('canonical scoped query seeks the declared index', () async {
      final executor = SqliteExecutor(SqliteDatabase(path: dbPath()));
      openDbs.add(
        await Cocoon.openWith(executor, collections: [accounts, txns, splits]),
      );

      final entry = txnEntry();
      final plan = await explainPlan(
        executor,
        entry: entry,
        scopePath: txns.pattern.resolve({'accountId': 'a1'}),
        filters: [txnBookedOn.isGreaterThanOrEqualTo(20260101)],
        orders: const [QueryOrder('bookedOn', descending: true)],
        limit: 50,
      );
      expect(plan, isNotEmpty);
      expectIndexed(plan);
      expect(
        plan.map((row) => row['detail']).join('\n'),
        contains(entry.indexes.first.name),
      );
    });

    test(
      'default order, param filter, reversed and mixed-direction scans',
      () async {
        final executor = SqliteExecutor(SqliteDatabase(path: dbPath()));
        openDbs.add(
          await Cocoon.openWith(
            executor,
            collections: [accounts, txns, splits],
          ),
        );

        final entry = txnEntry();

        // Scoped, default order: the scope index serves it.
        expectIndexed(
          await explainPlan(
            executor,
            entry: entry,
            scopePath: txns.pattern.resolve({'accountId': 'a1'}),
            filters: const [],
            orders: const [],
          ),
        );

        // Collection group with an explicit param filter.
        expectIndexed(
          await explainPlan(
            executor,
            entry: entry,
            scopePath: null,
            filters: [txnAccountId.isEqualTo('a1')],
            orders: const [QueryOrder('bookedOn', descending: true)],
          ),
        );

        // Reversed scan: ascending order over the descending index.
        expectIndexed(
          await explainPlan(
            executor,
            entry: entry,
            scopePath: txns.pattern.resolve({'accountId': 'a1'}),
            filters: const [],
            orders: const [QueryOrder('bookedOn')],
          ),
        );

        // Mixed-direction keyset (expanded OR form) still uses the index.
        final mixed = planQuery(
          entry: entry,
          scopePath: null,
          filters: const [],
          orders: const [
            QueryOrder('bookedOn'),
            QueryOrder('currency', descending: true),
          ],
          limit: 20,
          cursor: null,
          fullScan: false,
        );
        final cursor = CursorCodec.encode(mixed.fingerprint, [
          20260101,
          'MYR',
          'id1',
        ]);
        expectIndexed(
          await explainPlan(
            executor,
            entry: entry,
            scopePath: null,
            filters: const [],
            orders: const [
              QueryOrder('bookedOn'),
              QueryOrder('currency', descending: true),
            ],
            limit: 20,
            cursor: cursor,
          ),
        );
      },
    );
  });
}
