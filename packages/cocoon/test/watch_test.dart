import 'dart:async';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/executor.dart'
    show CocoonExecutor, CocoonRead, CocoonTx;
import 'package:cocoon/src/engine/sqlite_executor.dart';
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/spy_executor.dart';

/// Delays statements matching [gate] before they reach SQLite, so tests can
/// hold a watch's re-run in flight and prove commits coalesce. Everything is
/// forwarded to a real executor — SQLite is never mocked.
final class GatedExecutor implements CocoonExecutor {
  GatedExecutor(this._inner);

  final CocoonExecutor _inner;

  /// When set, statements matching it are held until [release] runs.
  bool Function(String sql)? gate;

  /// How many statements were held so far.
  int held = 0;

  final List<Completer<void>> _gates = [];

  /// How many statements are currently held.
  int get pending => _gates.length;

  Future<void> _maybeGate(String sql) async {
    final predicate = gate;
    if (predicate != null && predicate(sql)) {
      held++;
      final completer = Completer<void>();
      _gates.add(completer);
      await completer.future;
    }
  }

  /// Releases every currently held statement.
  void release() {
    final gates = _gates.toList();
    _gates.clear();
    for (final completer in gates) {
      completer.complete();
    }
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    await _maybeGate(sql);
    return _inner.getAll(sql, args);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    await _maybeGate(sql);
    return _inner.getOptional(sql, args);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) =>
      _inner.execute(sql, args);

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _inner.executeBatch(sql, parameterSets);

  @override
  Future<T> writeTransaction<T>(Future<T> Function(CocoonTx tx) body) =>
      _inner.writeTransaction<T>(body);

  @override
  Future<T> readTransaction<T>(Future<T> Function(CocoonRead tx) body) =>
      _inner.readTransaction<T>(body);

  @override
  Future<void> close() => _inner.close();
}

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

/// Lets broadcast-stream deliveries, cache reads and SQLite round trips land.
Future<void> settle([int ms = 25]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

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

  Future<(Cocoon, SpyExecutor)> openSpied() async {
    final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
    final opened = await Cocoon.openWith(
      spy,
      collections: [accounts, txns, splits],
    );
    openDbs.add(opened);
    return (opened, spy);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_watch_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  group('doc watch', () {
    test('emits the current value on listen, null when missing', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(const Account(name: 'Acme', active: true));

      final emissions = <DocSnapshot<Account>?>[];
      final sub = a1.watch().listen(emissions.add);
      await settle();
      expect(emissions, hasLength(1));
      expect(emissions.single!.data, const Account(name: 'Acme', active: true));
      await sub.cancel();

      final ghostEmissions = <DocSnapshot<Account>?>[];
      final ghostSub = db
          .collection(accounts)
          .doc('ghost')
          .watch()
          .listen(ghostEmissions.add);
      await settle();
      expect(ghostEmissions, hasLength(1));
      expect(ghostEmissions.single, isNull);
      await ghostSub.cancel();
    });

    test(
      'emits on change, not on unrelated writes, not on identical rewrite',
      () async {
        final db = await openDatabase();
        final txnsRef = db.collection(accounts).doc('a1').collection(txns);
        final t1 = await txnsRef.add(txn(bookedOn: 20260101, memo: 'one'));
        final t2 = await txnsRef.add(txn(bookedOn: 20260102, memo: 'two'));

        final emissions = <DocSnapshot<Txn>?>[];
        final sub = t1.watch().listen(emissions.add);
        await settle();
        expect(emissions, hasLength(1));

        // A write to another document of the same collection is unrelated.
        await t2.set(txn(bookedOn: 20260102, memo: 'two!'));
        await settle();
        expect(emissions, hasLength(1));

        // Rewriting t1 with the same canonical bytes must not emit.
        await t1.set(txn(bookedOn: 20260101, memo: 'one'));
        await settle();
        expect(emissions, hasLength(1));

        // A real change emits.
        await t1.set(txn(bookedOn: 20260101, memo: 'one!'));
        await settle();
        expect(emissions, hasLength(2));
        expect(emissions.last!.data.memo, 'one!');
        await sub.cancel();
      },
    );

    test(
      'emits null after a delete and the value again after a rewrite',
      () async {
        final db = await openDatabase();
        final txnsRef = db.collection(accounts).doc('a1').collection(txns);
        final t1 = await txnsRef.add(txn(bookedOn: 20260101, memo: 'one'));

        final emissions = <DocSnapshot<Txn>?>[];
        final sub = t1.watch().listen(emissions.add);
        await settle();
        expect(emissions.single!.data.memo, 'one');

        await t1.delete();
        await settle();
        expect(emissions, hasLength(2));
        expect(emissions.last, isNull);

        await t1.set(txn(bookedOn: 20260101, memo: 'back'));
        await settle();
        expect(emissions, hasLength(3));
        expect(emissions.last!.data.memo, 'back');
        await sub.cancel();
      },
    );

    test(
      'one transaction with several writes emits once with the final value',
      () async {
        final db = await openDatabase();
        final txnsRef = db.collection(accounts).doc('a1').collection(txns);
        final t1 = await txnsRef.add(txn(bookedOn: 20260101, memo: 'a'));

        final emissions = <DocSnapshot<Txn>?>[];
        final sub = t1.watch().listen(emissions.add);
        await settle();
        expect(emissions, hasLength(1));

        // One commit event for the whole transaction: the doc watch re-reads
        // once and emits the final value, not one emission per write.
        await db.runTransaction((tx) async {
          await tx.set(t1, txn(bookedOn: 20260101, memo: 'b'));
          await tx.set(t1, txn(bookedOn: 20260101, memo: 'c'));
          await tx.add(txnsRef, txn(bookedOn: 20260102, memo: 'other'));
        });
        await settle();

        expect(emissions, hasLength(2));
        expect(emissions.last!.data.memo, 'c');
        await sub.cancel();
      },
    );

    test('two listeners on one stream both receive emissions', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final t1 = await txnsRef.add(txn(bookedOn: 20260101, memo: 'one'));

      final stream = t1.watch();
      final first = <DocSnapshot<Txn>?>[];
      final second = <DocSnapshot<Txn>?>[];
      final sub1 = stream.listen(first.add);
      final sub2 = stream.listen(second.add);
      expect(db.debugWatcherCount, 1);
      await settle();
      expect(first, hasLength(1));
      expect(second, hasLength(1));

      await t1.set(txn(bookedOn: 20260101, memo: 'two'));
      await settle();
      expect(first.last!.data.memo, 'two');
      expect(second.last!.data.memo, 'two');

      await sub1.cancel();
      expect(db.debugWatcherCount, 1);

      await t1.set(txn(bookedOn: 20260101, memo: 'three'));
      await settle();
      expect(second.last!.data.memo, 'three');

      await sub2.cancel();
      expect(db.debugWatcherCount, 0);
    });
  });

  group('query watch', () {
    test(
      'emits the current page on listen and re-runs on matching writes',
      () async {
        final db = await openDatabase();
        final txnsRef = db.collection(accounts).doc('a1').collection(txns);
        await txnsRef.add(txn(bookedOn: 20260101, memo: 'old'));

        final emissions = <QueryPage<Txn>>[];
        final sub = txnsRef
            .orderBy(txnBookedOn, descending: true)
            .watch()
            .listen(emissions.add);
        await settle();
        expect(emissions, hasLength(1));
        expect(emissions.single.docs, hasLength(1));

        await txnsRef.add(txn(bookedOn: 20260301, memo: 'new'));
        await settle();
        expect(emissions, hasLength(2));
        expect(emissions.last.docs, hasLength(2));
        expect(emissions.last.docs.first.data.memo, 'new');
        await sub.cancel();
      },
    );

    test('ignores writes to other tables and other parents', () async {
      final (db, spy) = await openSpied();
      final a1 = db.collection(accounts).doc('a1');
      final a2 = db.collection(accounts).doc('a2');
      final t1 = await a1.collection(txns).add(txn(bookedOn: 20260101));
      await a2.collection(txns).add(txn(bookedOn: 20260102));

      int queryRuns() => spy.statements
          .where((statement) => statement.startsWith('SELECT path, id, data'))
          .length;

      final emissions = <QueryPage<Txn>>[];
      final sub = a1.collection(txns).query().watch().listen(emissions.add);
      await settle();
      expect(emissions.single.docs.map((d) => d.id), [t1.id]);
      final baseline = queryRuns();

      // Same table, different parent.
      await a2.collection(txns).add(txn(bookedOn: 20260103, memo: 'a2'));
      await settle();
      // Same parent subtree, different table.
      await t1
          .collection(splits)
          .add(const Split(label: 'main', shareMinor: 10));
      await settle();
      // The parent document's own table.
      await a1.set(const Account(name: 'Acme', active: true));
      await settle();
      expect(queryRuns(), baseline, reason: 'unrelated writes must not re-run');
      expect(emissions, hasLength(1));

      // A matching write re-runs and emits.
      await a1.collection(txns).add(txn(bookedOn: 20260104, memo: 'a1'));
      await settle();
      expect(queryRuns(), greaterThan(baseline));
      expect(emissions, hasLength(2));
      await sub.cancel();
    });

    test('re-runs but does not re-emit an identical page', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final t1 = await txnsRef.add(txn(bookedOn: 20260101, memo: 'same'));

      final emissions = <QueryPage<Txn>>[];
      final sub = txnsRef
          .orderBy(txnBookedOn, descending: true)
          .watch()
          .listen(emissions.add);
      await settle();
      expect(emissions, hasLength(1));

      await t1.set(txn(bookedOn: 20260101, memo: 'same'));
      await settle();
      expect(emissions, hasLength(1), reason: 'identical page is deduplicated');
      await sub.cancel();
    });

    test('coalesces 100 commits into a couple of re-runs', () async {
      final gate = GatedExecutor(
        SqliteExecutor(SqliteDatabase(path: dbPath())),
      );
      final db = await Cocoon.openWith(
        gate,
        collections: [accounts, txns, splits],
      );
      openDbs.add(db);
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);

      // Hold every query read so re-runs pile up behind the gate.
      gate.gate = (sql) => sql.startsWith('SELECT path, id, data');
      final emissions = <QueryPage<Txn>>[];
      final sub = txnsRef
          .orderBy(txnBookedOn, descending: true)
          .limit(10)
          .watch()
          .listen(emissions.add);
      await settle();
      gate.release(); // initial page
      await settle();
      expect(emissions, hasLength(1));
      final heldAfterInitial = gate.held;

      for (var i = 0; i < 100; i++) {
        await txnsRef.add(txn(bookedOn: 20260201 + i, memo: 'v$i'));
      }
      while (gate.pending > 0) {
        gate.release();
        await settle(50);
      }
      await settle(50);

      final reRuns = gate.held - heldAfterInitial;
      expect(reRuns, lessThan(10), reason: '100 commits must coalesce');
      expect(emissions, hasLength(2), reason: 'one final page after the burst');
      final last = emissions.last;
      expect(last.docs, hasLength(10));
      expect(last.docs.first.data.memo, 'v99');
      expect(last.docs.map((d) => d.data.memo), [
        for (var i = 99; i >= 90; i--) 'v$i',
      ]);
      await sub.cancel();
    });
  });

  group('watchFrom', () {
    test('anchors the live range so earlier inserts do not shift it', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      for (var i = 0; i < 10; i++) {
        await txnsRef.add(txn(bookedOn: 100 + i, memo: 'd$i'));
      }
      final query = txnsRef.orderBy(txnBookedOn);
      final page = await query.limit(5).get();
      expect(page.docs.map((d) => d.data.memo), ['d0', 'd1', 'd2', 'd3', 'd4']);

      final emissions = <QueryPage<Txn>>[];
      final sub = query
          .limit(5)
          .watchFrom(page.nextCursor)
          .listen(emissions.add);
      await settle();
      expect(emissions.single.docs.map((d) => d.data.memo), [
        'd5',
        'd6',
        'd7',
        'd8',
        'd9',
      ]);

      // A row inserted before the anchor leaves the window alone.
      await txnsRef.add(txn(bookedOn: 50, memo: 'early'));
      await settle();
      expect(emissions, hasLength(1));

      // A row inserted inside the window appears.
      final newcomer = await txnsRef.add(txn(bookedOn: 105, memo: 'new'));
      await settle();
      expect(emissions, hasLength(2));
      expect(emissions.last.docs, hasLength(5));
      expect(emissions.last.docs.map((d) => d.id), contains(newcomer.id));
      expect(
        emissions.last.docs.map((d) => d.data.memo),
        isNot(contains('early')),
      );
      await sub.cancel();
    });

    test('watchFrom(null) anchors at the start of the query', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      for (var i = 0; i < 5; i++) {
        await txnsRef.add(txn(bookedOn: 100 + i, memo: 'd$i'));
      }

      final emissions = <QueryPage<Txn>>[];
      final sub = txnsRef
          .orderBy(txnBookedOn)
          .limit(3)
          .watchFrom(null)
          .listen(emissions.add);
      await settle();
      expect(emissions.single.docs.map((d) => d.data.memo), ['d0', 'd1', 'd2']);

      // The head of an unanchored-at-a-row window does shift: the new lowest
      // row enters the window.
      final early = await txnsRef.add(txn(bookedOn: 50, memo: 'early'));
      await settle();
      expect(emissions, hasLength(2));
      expect(emissions.last.docs.map((d) => d.id), contains(early.id));
      await sub.cancel();
    });
  });

  group('lifecycle', () {
    test('cancel unregisters the watcher', () async {
      final (db, spy) = await openSpied();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final t1 = await txnsRef.add(txn(bookedOn: 20260101, memo: 'one'));

      int queryRuns() => spy.statements
          .where((statement) => statement.startsWith('SELECT path, id, data'))
          .length;

      final emissions = <QueryPage<Txn>>[];
      final sub = txnsRef.query().watch().listen(emissions.add);
      expect(db.debugWatcherCount, 1);
      await settle();
      expect(emissions, hasLength(1));
      final baseline = queryRuns();

      await sub.cancel();
      expect(db.debugWatcherCount, 0);

      // A write after the cancel must not re-run the query: nothing is
      // registered anymore.
      await txnsRef.add(txn(bookedOn: 20260102, memo: 'after'));
      await settle();
      expect(queryRuns(), baseline);

      // A fresh watch registers again and starts from the current value.
      final emissions2 = <QueryPage<Txn>>[];
      final sub2 = txnsRef.query().watch().listen(emissions2.add);
      expect(db.debugWatcherCount, 1);
      await settle();
      expect(emissions2.single.docs, hasLength(2));
      await sub2.cancel();
      expect(db.debugWatcherCount, 0);

      // The doc watch unregisters the same way.
      final docSub = t1.watch().listen((_) {});
      expect(db.debugWatcherCount, 1);
      await docSub.cancel();
      expect(db.debugWatcherCount, 0);
    });

    test('closing the database completes all watch streams', () async {
      final db = await openDatabase();
      final txnsRef = db.collection(accounts).doc('a1').collection(txns);
      final t1 = await txnsRef.add(txn(bookedOn: 20260101, memo: 'one'));

      final docDone = Completer<void>();
      final queryDone = Completer<void>();
      final docSub = t1.watch().listen((_) {}, onDone: docDone.complete);
      final querySub = txnsRef
          .orderBy(txnBookedOn, descending: true)
          .watch()
          .listen((_) {}, onDone: queryDone.complete);
      await settle();

      await db.close();
      openDbs.remove(db);
      await Future.wait([docDone.future, queryDone.future]);
      await docSub.cancel();
      await querySub.cancel();
      expect(db.debugWatcherCount, 0);
    });
  });
}
