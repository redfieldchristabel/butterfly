import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

import 'support/models.dart';

Txn txn({
  required int bookedOn,
  String? memo,
  TxnStatus status = TxnStatus.posted,
}) => Txn(
  bookedOn: bookedOn,
  amountMinor: 100,
  rate: 1.5,
  currency: 'MYR',
  status: status,
  createdAt: DateTime.utc(2026, 1, 1),
  memo: memo,
);

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({CocoonOptions options = const CocoonOptions()}) {
    return Cocoon.open(
      dbPath(),
      collections: [accounts, txns, splits],
      options: options,
    ).then((opened) {
      openDbs.add(opened);
      return opened;
    });
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_changes_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  group('change log', () {
    test('set, add and delete append one row each, in commit order', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(const Account(name: 'Acme', active: true));
      final t1 = await a1.collection(txns).add(txn(bookedOn: 20260101));
      await t1.delete();

      final changes = await db.changesSince(0);
      expect(changes, hasLength(3));
      expect(changes.map((c) => c.op), [
        ChangeOp.set,
        ChangeOp.set,
        ChangeOp.delete,
      ]);
      expect(changes.map((c) => c.collection), ['Account', 'Txn', 'Txn']);
      expect(changes.map((c) => c.path), [
        'accounts/a1',
        'accounts/a1/txns/${t1.id}',
        'accounts/a1/txns/${t1.id}',
      ]);
      for (var i = 1; i < changes.length; i++) {
        expect(changes[i].seq, greaterThan(changes[i - 1].seq));
      }

      final now = DateTime.now().toUtc();
      for (final change in changes) {
        expect(change.at.isUtc, isTrue);
        expect(
          change.at.isBefore(now.add(const Duration(minutes: 1))),
          isTrue,
          reason: 'change.at must be the commit time',
        );
      }

      expect(await db.lastChangeSeq(), changes.last.seq);
      expect(await db.changesSince(changes.last.seq), isEmpty);
    });

    test('one transaction appends one row per document write', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final txnsRef = a1.collection(txns);
      await db.runTransaction((tx) async {
        await tx.set(a1, const Account(name: 'Acme', active: true));
        await tx.add(txnsRef, txn(bookedOn: 20260101));
        await tx.add(txnsRef, txn(bookedOn: 20260102));
      });

      final changes = await db.changesSince(0);
      expect(changes, hasLength(3));
      expect(changes.every((c) => c.op == ChangeOp.set), isTrue);
      expect(changes.map((c) => c.collection), ['Account', 'Txn', 'Txn']);
      for (var i = 1; i < changes.length; i++) {
        expect(changes[i].seq, greaterThan(changes[i - 1].seq));
      }
    });

    test('cascade delete logs one row per deleted document', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(const Account(name: 'Acme', active: true));
      final t1 = await a1.collection(txns).add(txn(bookedOn: 20260101));
      final t2 = await a1.collection(txns).add(txn(bookedOn: 20260102));
      final s1 = await t1
          .collection(splits)
          .add(const Split(label: 'main', shareMinor: 10));
      final before = await db.lastChangeSeq();
      expect(before, 4);

      await a1.delete();

      final changes = await db.changesSince(before);
      expect(changes, hasLength(4));
      expect(changes.every((c) => c.op == ChangeOp.delete), isTrue);
      expect(changes.map((c) => (c.collection, c.path)).toSet(), {
        ('Account', 'accounts/a1'),
        ('Txn', 'accounts/a1/txns/${t1.id}'),
        ('Txn', 'accounts/a1/txns/${t2.id}'),
        ('Split', 'accounts/a1/txns/${t1.id}/splits/${s1.id}'),
      });
    });

    test(
      'a rolled back transaction leaves no rows and emits no events',
      () async {
        final db = await openDatabase();
        final a1 = db.collection(accounts).doc('a1');
        await a1.set(const Account(name: 'Acme', active: true));
        final emissions = <DocSnapshot<Account>?>[];
        final sub = a1.watch().listen(emissions.add);
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(emissions, hasLength(1));
        final seqBefore = await db.lastChangeSeq();

        await expectLater(
          db.runTransaction<String>((tx) async {
            await tx.set(a1, const Account(name: 'Changed', active: true));
            throw StateError('boom');
          }),
          throwsA(isA<StateError>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));

        // Database: only the pre-transaction write is logged.
        expect(await db.changesSince(0), hasLength(1));
        expect(await db.lastChangeSeq(), seqBefore);
        // Watches: no event for the rolled-back write.
        expect(emissions, hasLength(1));
        await sub.cancel();
      },
    );

    test('changesSince paginates with limit and validates it', () async {
      final db = await openDatabase();
      final accountsRef = db.collection(accounts);
      for (var i = 1; i <= 3; i++) {
        await accountsRef.doc('a$i').set(Account(name: 'n$i', active: true));
      }

      final all = await db.changesSince(0);
      expect(all, hasLength(3));

      final firstTwo = await db.changesSince(0, limit: 2);
      expect(firstTwo, hasLength(2));
      expect(firstTwo[0].seq, all[0].seq);
      expect(firstTwo[1].seq, all[1].seq);

      final rest = await db.changesSince(firstTwo.last.seq);
      expect(rest, [all[2]]);

      await expectLater(
        db.changesSince(0, limit: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('pruneChanges drops processed rows and keeps the rest', () async {
      final db = await openDatabase();
      final accountsRef = db.collection(accounts);
      for (var i = 1; i <= 3; i++) {
        await accountsRef.doc('a$i').set(Account(name: 'n$i', active: true));
      }
      final all = await db.changesSince(0);

      await db.pruneChanges(upToSeq: all[1].seq);
      expect(await db.changesSince(0), [all[2]]);
      expect(await db.lastChangeSeq(), all[2].seq);

      await db.pruneChanges(upToSeq: await db.lastChangeSeq());
      expect(await db.changesSince(0), isEmpty);
      // The head survives a full prune, so watermarks never go backwards.
      expect(await db.lastChangeSeq(), all[2].seq);

      await db
          .collection(accounts)
          .doc('after-prune')
          .set(const Account(name: 'Later', active: true));
      final later = await db.changesSince(all[2].seq);
      expect(later.single.seq, greaterThan(all[2].seq));
      expect(await db.lastChangeSeq(), later.single.seq);
    });

    test('the log persists across reopen and keeps seq increasing', () async {
      final db = await openDatabase();
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      await db.close();
      openDbs.remove(db);

      final reopened = await openDatabase();
      await reopened
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme 2', active: false));

      final changes = await reopened.changesSince(0);
      expect(changes, hasLength(2));
      expect(changes[1].seq, greaterThan(changes[0].seq));
      expect(changes[1].collection, 'Account');
    });

    test('keepChanges false keeps the log empty but still notifies', () async {
      final db = await openDatabase(
        options: const CocoonOptions(keepChanges: false),
      );
      final a1 = db.collection(accounts).doc('a1');
      final emissions = <DocSnapshot<Account>?>[];
      final sub = a1.watch().listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      await a1.set(const Account(name: 'Acme', active: true));
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(emissions, hasLength(2));
      expect(emissions.last!.data, const Account(name: 'Acme', active: true));
      expect(await db.changesSince(0), isEmpty);
      expect(await db.lastChangeSeq(), 0);
      await sub.cancel();
    });
  });
}
