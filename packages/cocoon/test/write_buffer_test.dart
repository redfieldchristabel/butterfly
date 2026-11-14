import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/naming.dart' show changesTableName;
import 'package:cocoon/src/engine/sqlite_executor.dart' show SqliteExecutor;
import 'package:cocoon/src/engine/write_buffer.dart' show writeFlushThreshold;
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
    String name = 'buffer.db',
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
    dir = Directory.systemTemp.createTempSync('cocoon_write_buffer_test');
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

  group('buffered transaction writes', () {
    test('reads see buffered sets inside the same transaction', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');

      await db.runTransaction((tx) async {
        await tx.set(a1.collection(txns).doc('t1'), txnOf(100));
        await tx.set(a1.collection(txns).doc('t2'), txnOf(200));
        expect(
          (await tx.get(a1.collection(txns).doc('t1')))!.data.amountMinor,
          100,
        );
        expect(
          (await tx.get(a1.collection(txns).doc('t2')))!.data.amountMinor,
          200,
        );
      });

      expect(
        (await a1.collection(txns).doc('t1').get())!.data.amountMinor,
        100,
      );
      expect(
        (await a1.collection(txns).doc('t2').get())!.data.amountMinor,
        200,
      );
    });

    test(
      'reads see buffered sets that already flushed at the threshold',
      () async {
        final db = await openDatabase();
        final a1 = db.collection(accounts).doc('a1');
        final first = a1.collection(txns).doc('t00000');
        final mid = a1.collection(txns).doc('t02000');

        await db.runTransaction((tx) async {
          for (var i = 0; i < writeFlushThreshold + 500; i++) {
            await tx.set(
              a1.collection(txns).doc('t${i.toString().padLeft(5, '0')}'),
              txnOf(i),
            );
          }
          // t00000 flushed with the first 2000-row batch; the read must
          // still see this transaction's value.
          expect((await tx.get(first))!.data.amountMinor, 0);
          expect((await tx.get(mid))!.data.amountMinor, 2000);
        });

        expect((await first.get())!.data.amountMinor, 0);
        expect((await mid.get())!.data.amountMinor, 2000);
        expect(
          await db
              .collection(accounts)
              .doc('a1')
              .collection(txns)
              .doc('t02499')
              .get(),
          isNotNull,
        );
      },
    );

    test(
      'a delete after a set in the same transaction removes the document',
      () async {
        final db = await openDatabase();
        final t1 = db.collection(accounts).doc('a1').collection(txns).doc('t1');

        await db.runTransaction((tx) async {
          await tx.set(t1, txnOf(100));
          await tx.delete(t1);
        });

        expect(await t1.get(), isNull);
        final ops = [
          for (final change in await db.changesSince(0))
            '${change.op} ${change.path}',
        ];
        expect(ops, [
          'ChangeOp.set accounts/a1/txns/t1',
          'ChangeOp.delete accounts/a1/txns/t1',
        ]);
      },
    );

    test(
      'a set after a delete in the same transaction recreates the document',
      () async {
        final db = await openDatabase();
        final t1 = db.collection(accounts).doc('a1').collection(txns).doc('t1');
        await t1.set(txnOf(100));

        await db.runTransaction((tx) async {
          await tx.delete(t1);
          await tx.set(t1, txnOf(200));
        });

        expect((await t1.get())!.data.amountMinor, 200);
        final ops = [
          for (final change in await db.changesSince(0))
            '${change.op} ${change.path}',
        ];
        expect(ops, [
          'ChangeOp.set accounts/a1/txns/t1', // the pre-transaction set
          'ChangeOp.delete accounts/a1/txns/t1',
          'ChangeOp.set accounts/a1/txns/t1',
        ]);
      },
    );

    test('a failure after the buffer flushed rolls everything back', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final t0 = a1.collection(txns).doc('t0');
      await t0.set(txnOf(-1));

      final events = <DocSnapshot<Txn>?>[];
      final sub = t0.watch().listen(events.add);
      await settle();
      final eventsBefore = events.length;
      final cacheBefore = await db.debugCacheLength;
      final changesBefore = await db.changesSince(0);

      await expectLater(
        db.runTransaction<void>((tx) async {
          for (var i = 0; i < writeFlushThreshold + 500; i++) {
            await tx.set(
              a1.collection(txns).doc('t${i.toString().padLeft(5, '0')}'),
              txnOf(i),
            );
          }
          throw StateError('boom');
        }),
        throwsStateError,
      );

      expect((await t0.get())!.data.amountMinor, -1);
      expect(await a1.collection(txns).doc('t00000').get(), isNull);
      expect(
        await a1
            .collection(txns)
            .doc('t${(writeFlushThreshold + 499).toString().padLeft(5, '0')}')
            .get(),
        isNull,
      );
      expect(await db.debugCacheLength, cacheBefore);
      await settle();
      expect(events.length, eventsBefore);
      expect(await db.changesSince(0), changesBefore);
      await sub.cancel();
    });

    test(
      'buffered writes flush as batched statements, not one per document',
      () async {
        final spy = SpyExecutor(
          SqliteExecutor(
            SqliteDatabase(path: '${dir.path}${Platform.pathSeparator}spy.db'),
          ),
        );
        final db = await Cocoon.openWith(spy, collections: [accounts, txns]);
        openDbs.add(db);
        final a1 = db.collection(accounts).doc('a1');

        final before = spy.statements.length;
        await db.runTransaction((tx) async {
          for (var i = 0; i < 2 * writeFlushThreshold + 1; i++) {
            await tx.set(
              a1.collection(txns).doc('t${i.toString().padLeft(5, '0')}'),
              txnOf(i),
            );
          }
        });
        final inTransaction = spy.statements.sublist(before);

        // 2 * 2000 + 1 sets: a flush at 2000, one at 4000 and the commit
        // flush of the last row — three batched upserts, three batched
        // change-row inserts, and nothing else (keepsChanges on).
        expect(
          inTransaction.where((sql) => sql.contains('ON CONFLICT')),
          hasLength(3),
        );
        expect(
          inTransaction.where((sql) => sql.contains(changesTableName)),
          hasLength(3),
        );
        expect(inTransaction, hasLength(6));
      },
    );
  });

  group('lazy cache decode', () {
    test(
      'a write caches the encoded bytes; the first read decodes them once',
      () async {
        final db = await openDatabase();
        final t1 = db.collection(accounts).doc('a1').collection(txns).doc('t1');
        // A local (non-UTC) instant: the stored wire bytes carry the
        // epoch micros, and decoding them is what produces UTC.
        final local = DateTime.fromMicrosecondsSinceEpoch(1770000000000000);
        expect(local.isUtc, isFalse);
        final value = Txn(
          bookedOn: 20260115,
          amountMinor: 100,
          rate: 1.5,
          currency: 'MYR',
          status: TxnStatus.posted,
          createdAt: local,
          memo: 'memo',
        );

        await t1.set(value);
        expect(await db.debugCacheLength, 1); // the write cached its bytes

        final first = await t1.get();
        expect(first!.data.createdAt.isUtc, isTrue);
        expect(
          first.data.createdAt.microsecondsSinceEpoch,
          local.microsecondsSinceEpoch,
        );
        expect(first.data, value);

        // The decode promoted the value; no second cache entry, and a
        // later read returns exactly what the stored bytes decode to.
        expect(await db.debugCacheLength, 1);
        final second = await t1.get();
        expect(second!.data, first.data);
        expect(second.data.createdAt.isUtc, isTrue);
      },
    );
  });

  group('sqlite pragmas', () {
    Future<int> pragmaValue(Cocoon db, String name) async {
      final rows = await db.executor.getAll('PRAGMA $name');
      return rows.single[name]! as int;
    }

    test(
      'the defaults apply the measured page-cache and temp-store pragmas',
      () async {
        final db = await openDatabase();
        // Readers keep SQLite's defaults: one big cache, not one per
        // pooled reader.
        expect(await pragmaValue(db, 'cache_size'), isNot(-65536));
        expect(await pragmaValue(db, 'temp_store'), isNot(2));
        expect(await pragmaValue(db, 'synchronous'), 2); // FULL
        // The cache, temp store and checkpoint interval are writer-only.
        Future<Object?> onWriter(String pragma) => db.executor.writeTransaction(
          (tx) async =>
              (await tx.getAll('PRAGMA $pragma')).single.values.single,
        );
        expect(await onWriter('cache_size'), -65536); // 64 MiB
        expect(await onWriter('temp_store'), 2); // MEMORY
        expect(await onWriter('wal_autocheckpoint'), 8000); // 32 MiB
        expect(await onWriter('journal_size_limit'), 4 * 1024 * 1024);
      },
    );

    test('Durability.normal opens with synchronous NORMAL', () async {
      final db = await openDatabase(
        options: const CocoonOptions(durability: Durability.normal),
      );
      expect(await pragmaValue(db, 'synchronous'), 1);
    });

    test('pageCacheMiB scales the cache, 0 keeps the SQLite default', () async {
      final small = await openDatabase(
        name: 'small.db',
        options: const CocoonOptions(pageCacheMiB: 8),
      );
      expect(
        await small.executor.writeTransaction(
          (tx) async =>
              (await tx.getAll('PRAGMA cache_size')).single.values.single,
        ),
        -8192,
      );

      final off = await openDatabase(
        name: 'off.db',
        options: const CocoonOptions(pageCacheMiB: 0),
      );
      expect(
        await off.executor.writeTransaction(
          (tx) async =>
              (await tx.getAll('PRAGMA cache_size')).single.values.single,
        ),
        isNot(-65536),
      );
    });

    test(
      'tempStoreInMemory: false leaves the temp store at its default',
      () async {
        final db = await openDatabase(
          name: 'tempfile.db',
          options: const CocoonOptions(tempStoreInMemory: false),
        );
        expect(await pragmaValue(db, 'temp_store'), isNot(2));
      },
    );

    test('walAutoCheckpointPages: 0 keeps the SQLite default', () async {
      final db = await openDatabase(
        name: 'waldefault.db',
        options: const CocoonOptions(walAutoCheckpointPages: 0),
      );
      final writer = await db.executor.writeTransaction(
        (tx) async => (await tx.getAll('PRAGMA wal_autocheckpoint')).single,
      );
      expect(writer['wal_autocheckpoint'], isNot(8000));
    });
  });
}
