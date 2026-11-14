import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/isolate/auto.dart';
import 'package:cocoon/src/engine/isolate/background.dart';
import 'package:cocoon/src/engine/isolate/isolate_options.dart'
    show AutoRoute, AutoRouter;
import 'package:test/test.dart';

import 'support/models.dart';

Account account(String name) => Account(name: name, active: true);

Txn txnOf(int amountMinor, {String? memo}) => Txn(
  bookedOn: 20260115,
  amountMinor: amountMinor,
  rate: 1.5,
  currency: 'MYR',
  status: TxnStatus.posted,
  createdAt: DateTime.utc(2026, 1, 15, 10, 30),
  memo: memo,
);

/// Lets cross-isolate round trips, watch re-reads and SQLite land.
Future<void> settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// The isolate modes' dedicated tests: what must hold when the engine does
/// NOT run on the caller (background: one worker isolate per database; auto:
/// the engine home on the caller plus one read-only helper). The whole
/// regular suite also runs in both modes via `COCOON_TEST_ISOLATE` (see
/// `tool/test_all_modes.sh`); this file covers the isolate-specific
/// contracts the regular suite cannot express.
void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  /// Opens a background-mode database, tracked for the shared tearDown.
  Future<Cocoon> openBackground([String name = 'cocoon.db']) async {
    final db = await Cocoon.open(
      dbPath(name),
      collections: [accounts, txns],
      options: const CocoonOptions(isolate: CocoonIsolate.background),
    );
    openDbs.add(db);
    return db;
  }

  /// Opens an auto-mode database with every routed class forced to the
  /// helper (thresholds 0), so the helper paths are deterministic.
  Future<Cocoon> openAuto() async {
    final db = await Cocoon.open(
      dbPath('auto.db'),
      collections: [accounts, txns],
      options: const CocoonOptions(
        isolate: CocoonIsolate.auto,
        autoThresholds: CocoonAutoThresholds(inlineRows: 0, inlineWriteOps: 0),
      ),
    );
    openDbs.add(db);
    return db;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cocoon_isolate_test');
  });
  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  group('background mode', () {
    test('results cross with their types: docs, getAll, pages, aggregates, '
        'groups', () async {
      final db = await openBackground();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(account('Acme'));
      final added = await a1.collection(txns).add(txnOf(100, memo: 'one'));
      await a1.collection(txns).doc('t2').set(txnOf(200, memo: 'two'));

      final snap = await a1.get();
      expect(snap!.data, account('Acme'));

      final both = await db.getAll([
        a1.collection(txns).doc(added.id),
        a1.collection(txns).doc('missing'),
        a1.collection(txns).doc(added.id),
      ]);
      expect(both, hasLength(3));
      expect(both[0]!.data.memo, 'one');
      expect(both[1], isNull);
      expect(both[2]!.data.memo, 'one');

      final query = a1.collection(txns).query();
      final page = await query.limit(1).get();
      expect(page.docs.single.id, added.id);
      expect(page.nextCursor, isNotNull);
      final nextPage = await query.startAfter(page.nextCursor!).get();
      expect(nextPage.docs.single.id, 't2');

      final aggregate = await a1.collection(txns).aggregate([
        count(),
        sum(txnAmountMinor),
      ]).get();
      expect(aggregate.count, 2);
      expect(aggregate.getSum(txnAmountMinor), 300);

      final memoKey = key(txnMemo);
      final groups = await a1.collection(txns).groupBy([memoKey]).aggregate([
        count(),
      ]).get();
      expect(groups, hasLength(2));
      expect({for (final group in groups) group.count}, {1});
      expect({for (final group in groups) group.key(memoKey)}, {'one', 'two'});
    });

    test('errors cross with their type, message and details', () async {
      final db = await openBackground();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(account('Acme'));

      // A missing index: same type, same message, same fix command.
      await expectLater(
        a1.collection(txns).where(txnAmountMinor.isEqualTo(100)).get(),
        throwsA(
          isA<MissingIndexException>()
              .having((e) => e.suggestedIndex, 'suggestedIndex', isNotNull)
              .having((e) => e.fixCommand, 'fixCommand', isNotNull),
        ),
      );

      // A transaction misuse: same type, same operation.
      await expectLater(
        db.runTransaction((tx) async {
          await a1.set(account('nope'));
        }),
        throwsA(
          isA<TransactionMisuseError>().having(
            (e) => e.operation,
            'operation',
            'DocRef.set',
          ),
        ),
      );

      // A subcollection adapter on a top-level collection: ArgumentError.
      final wrong = db.collection(accounts).doc('a1');
      expect(() => wrong.collection(accounts), throwsArgumentError);

      // A closed database: the same StateError a closed local database
      // throws, for every later call.
      await db.close();
      await expectLater(
        db.collection(accounts).doc('x').get(),
        throwsStateError,
      );
    });

    test('a transaction body that throws rolls back', () async {
      final db = await openBackground();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(account('before'));
      final changes = await db.changesSince(0);
      final beforeSeq = changes.isEmpty ? 0 : changes.last.seq;

      await expectLater(
        db.runTransaction((tx) async {
          await tx.set(a1, account('inside'));
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect((await a1.get())!.data.name, 'before');
      expect(await db.changesSince(beforeSeq), isEmpty);
    });

    test(
      'watch cancel stops the worker watch; close completes the stream',
      () async {
        final db = await openBackground();
        final a1 = db.collection(accounts).doc('a1');
        await a1.set(account('Acme'));

        final emissions = <DocSnapshot<Account>?>[];
        var streamDone = false;
        late final StreamSubscription<DocSnapshot<Account>?> sub;
        sub = a1.watch().listen(emissions.add, onDone: () => streamDone = true);
        await settle();
        expect(emissions, hasLength(1));
        expect(await db.debugWatcherCount, 1);

        await sub.cancel();
        await settle();
        expect(await db.debugWatcherCount, 0);

        // A write after the cancel emits nothing more: the worker-side watch
        // was cancelled, not merely detached.
        await a1.set(account('Acme 2'));
        await settle();
        expect(emissions, hasLength(1));
        expect(streamDone, isFalse);

        // close() completes every watch stream, like the local engine does.
        final other = await openBackground('other.db');
        final b1 = other.collection(accounts).doc('b1');
        await b1.set(account('Beta'));
        var otherDone = false;
        final otherSub = b1.watch().listen(
          (_) {},
          onDone: () => otherDone = true,
        );
        await settle();
        await other.close();
        await settle();
        expect(otherDone, isTrue);
        await otherSub.cancel();
      },
    );

    test(
      'close() fails later calls with StateError and is idempotent',
      () async {
        final db = await openBackground();
        await db.close();
        await expectLater(
          db.collection(accounts).doc('a1').set(account('late')),
          throwsStateError,
        );
        await expectLater(db.close(), completes);
      },
    );

    test('a crashed worker fails pending and future calls', () async {
      final db = await openBackground();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(account('Acme'));

      // A genuinely pending call: the worker holds the transaction's write
      // lock while the body waits, so a plain write outside the body
      // (legal — the guard only binds the body's zone) is still queued
      // behind that lock when the worker dies.
      final gate = Completer<void>();
      var bodyWriteDone = false;
      final txDone = db.runTransaction<void>((tx) async {
        await tx.set(a1, account('inside'));
        bodyWriteDone = true;
        await gate.future;
      });
      while (!bodyWriteDone) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Attach the matcher now: the blocked write fails while we wait for
      // the crash, and an unawaited error would fail the test.
      final blockedFails = expectLater(
        a1.set(account('blocked')),
        throwsA(isA<CocoonIsolateException>()),
      );
      (db.runtime as BackgroundCocoonRuntime).debugWorkerIsolate.kill(
        priority: Isolate.immediate,
      );
      // The exit notification marks the channel dead and fails everything
      // pending; the commit after the body fails the same way.
      await settle();
      gate.complete();
      await expectLater(txDone, throwsA(isA<CocoonIsolateException>()));
      await blockedFails;
      await expectLater(a1.get(), throwsA(isA<CocoonIsolateException>()));
      // The crashed handle is unusable but closes quietly.
      await db.close();
    });

    test('a caller isolate dying mid-transaction rolls back', () async {
      // Seed a committed state, then hand the file to a helper isolate
      // whose transaction is killed mid-body.
      final seedDb = await Cocoon.open(dbPath(), collections: [accounts, txns]);
      await seedDb.collection(accounts).doc('a1').set(account('before'));
      await seedDb.close();

      final txOpen = ReceivePort();
      final isolate = await Isolate.spawn(_holdTransaction, (
        txOpen.sendPort,
        dbPath(),
      ));
      final opened = Completer<void>();
      txOpen.listen((_) {
        if (!opened.isCompleted) {
          opened.complete();
        }
      });
      await opened.future.timeout(const Duration(seconds: 30));
      isolate.kill(priority: Isolate.immediate);

      // The worker rolls the transaction back when its caller dies; wait
      // for the file's write lock to come back, then read what committed.
      var rolledBack = false;
      for (var attempt = 0; attempt < 50 && !rolledBack; attempt++) {
        try {
          final db = await Cocoon.open(dbPath(), collections: [accounts, txns]);
          final name =
              (await db.collection(accounts).doc('a1').get())!.data.name;
          await db.close();
          if (name == 'before') {
            rolledBack = true;
          }
        } on Object {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      txOpen.close();
      expect(
        rolledBack,
        isTrue,
        reason: 'the killed transaction must not have committed',
      );
    });
  });

  group('auto mode', () {
    test('routing rules are pure functions of the thresholds', () {
      const t = CocoonAutoThresholds(inlineRows: 10, inlineWriteOps: 5);
      // getAll: inline at the threshold, helper above it.
      expect(AutoRouter.getAll(t, 10), AutoRoute.inline);
      expect(AutoRouter.getAll(t, 11), AutoRoute.helper);
      // query: an explicit limit at or under the threshold runs inline,
      // above it and unbounded go to the helper.
      expect(AutoRouter.query(t, 10), AutoRoute.inline);
      expect(AutoRouter.query(t, 11), AutoRoute.helper);
      expect(AutoRouter.query(t, null), AutoRoute.helper);
      expect(AutoRouter.query(t, 0), AutoRoute.inline);
      // groupBy: a cap at or under the threshold inline, over it and
      // uncapped helper.
      expect(AutoRouter.groupBy(t, 10), AutoRoute.inline);
      expect(AutoRouter.groupBy(t, 11), AutoRoute.helper);
      expect(AutoRouter.groupBy(t, null), AutoRoute.helper);
      // batch: at or under inlineWriteOps inline, above it helper.
      expect(AutoRouter.batch(t, 5), AutoRoute.inline);
      expect(AutoRouter.batch(t, 6), AutoRoute.helper);
      // bulkWriter always prepares in the helper; aggregates and
      // transactions always run inline.
      expect(AutoRouter.bulkWriter(t), AutoRoute.helper);
      expect(AutoRouter.aggregate(t), AutoRoute.inline);
      expect(AutoRouter.transaction(t), AutoRoute.inline);

      expect(
        () => const CocoonAutoThresholds(inlineRows: -1).validate(),
        throwsArgumentError,
      );
      expect(
        () => const CocoonAutoThresholds(inlineWriteOps: -1).validate(),
        throwsArgumentError,
      );
      // Zero is allowed: with a zero threshold only an operation with
      // nothing in it (an empty getAll, a limit-0 query, an empty batch)
      // stays inline; any real work goes to the helper.
      const zero = CocoonAutoThresholds(inlineRows: 0, inlineWriteOps: 0);
      expect(AutoRouter.getAll(zero, 0), AutoRoute.inline);
      expect(AutoRouter.getAll(zero, 1), AutoRoute.helper);
      expect(AutoRouter.query(zero, 0), AutoRoute.inline);
      expect(AutoRouter.query(zero, 1), AutoRoute.helper);
      expect(AutoRouter.query(zero, null), AutoRoute.helper);
      expect(AutoRouter.groupBy(zero, 0), AutoRoute.inline);
      expect(AutoRouter.groupBy(zero, 1), AutoRoute.helper);
      expect(AutoRouter.batch(zero, 0), AutoRoute.inline);
      expect(AutoRouter.batch(zero, 1), AutoRoute.helper);
    });

    test(
      'an inline write is seen by a heavy helper query; stats move',
      () async {
        final db = await openAuto();
        final a1 = db.collection(accounts).doc('a1');
        await a1.set(account('Acme')); // doc set: always inline.
        await a1.collection(txns).doc('t1').set(txnOf(100, memo: 'one'));

        final page = await a1.collection(txns).query().get(); // helper
        expect(page.docs.single.data.memo, 'one');

        final stats = db.isolateStats!;
        expect(stats.inlineCalls, greaterThan(0));
        expect(stats.helperCalls, greaterThan(0));
        expect(stats.helperBytesMoved, greaterThan(0));
      },
    );

    test(
      'a heavy query during an open transaction sees pre-commit state',
      () async {
        final db = await openAuto();
        final a1 = db.collection(accounts).doc('a1');
        await a1.collection(txns).doc('t1').set(txnOf(1));

        final gate = Completer<void>();
        final txDone = db.runTransaction<void>((tx) async {
          await tx.set(a1.collection(txns).doc('t2'), txnOf(2));
          // Inside the body, non-tx calls on the same database still fail
          // fast: the step-27 guard holds unchanged in auto mode. (The guard
          // throws synchronously, before count() builds a future.)
          Object? misuse;
          try {
            await a1.collection(txns).count();
          } on TransactionMisuseError catch (error) {
            misuse = error;
          }
          expect(misuse, isA<TransactionMisuseError>());
          await gate.future;
        });
        await Future<void>.delayed(const Duration(milliseconds: 60));
        // Outside the body the heavy query is legal while the write lock is
        // held: the helper's read-only connection sees the committed
        // snapshot only — the transaction's own write is invisible, exactly
        // as in caller mode.
        final during = await a1.collection(txns).query().get();
        expect(during.docs.single.id, 't1');
        gate.complete();
        await txDone;
        // After the commit the same heavy query sees the transaction's write.
        final after = await a1.collection(txns).query().get();
        expect({for (final doc in after.docs) doc.id}, {'t1', 't2'});
      },
    );

    test('a watch over a heavy query re-runs it in the helper', () async {
      final db = await openAuto();
      final a1 = db.collection(accounts).doc('a1');

      final pages = <QueryPage<Txn>>[];
      final sub = a1.collection(txns).query().watch().listen(pages.add);
      await settle();
      expect(pages, hasLength(1));

      await a1.collection(txns).doc('t1').set(txnOf(100, memo: 'one'));
      await settle();
      expect(pages, hasLength(2));
      expect(pages.last.docs.single.data.memo, 'one');
      await sub.cancel();

      // The re-runs went through the helper; the notifier stayed on the
      // caller (the stats count the helper reads).
      expect(db.isolateStats!.helperCalls, greaterThan(0));
    });

    test(
      'close() stops the helper; a dead helper degrades to inline',
      () async {
        final db = await openAuto();
        final a1 = db.collection(accounts).doc('a1');
        await a1.set(account('Acme'));

        // A dead helper never fails a user call: the runtime degrades to
        // inline with one warning, and the same heavy query still answers.
        final helper = (db.runtime as AutoCocoonRuntime).debugHelperIsolate;
        helper!.kill(priority: Isolate.immediate);
        await settle();
        final page = await a1.collection(txns).query().get();
        expect(page.docs, isEmpty);
        expect(db.isolateStats, isNotNull);

        await db.close();
        // Closed calls fail like any closed database. (A read of a document
        // still in the hot cache answers, exactly as it does in caller mode —
        // the engine home is the caller — so the checks here use a write and
        // a query, which always reach the engine.)
        await expectLater(a1.set(account('late')), throwsStateError);
        await expectLater(a1.collection(txns).query().get(), throwsStateError);
      },
    );

    test('isolateStats is null outside auto mode', () async {
      final callerDb = await Cocoon.open(
        dbPath('caller.db'),
        collections: [accounts, txns],
      );
      openDbs.add(callerDb);
      await callerDb.collection(accounts).doc('a1').set(account('Acme'));
      expect(callerDb.isolateStats, isNull);

      final backgroundDb = await openBackground('stats.db');
      await backgroundDb.collection(accounts).doc('a1').set(account('Acme'));
      expect(backgroundDb.isolateStats, isNull);
    });
  });

  group('isolate lifetime', () {
    // A link that leaks an open ReceivePort (its error/exit listeners)
    // keeps the host isolate's event loop alive forever: `dart test` masks
    // this because it terminates suite processes, but a plain `dart run`
    // (a Flutter command-line tool, a CLI, a server) would hang at exit.
    // The onExit port fires only when the child isolate actually exits.
    for (final mode in [CocoonIsolate.background, CocoonIsolate.auto]) {
      test(
        'a closed ${mode.name} database lets its host isolate exit',
        () async {
          final closed = ReceivePort();
          final errors = ReceivePort();
          final childFailed = Completer<Object?>();
          errors.listen((message) {
            if (!childFailed.isCompleted) {
              childFailed.complete(message);
            }
          });
          final onExit = RawReceivePort();
          final exited = Completer<void>();
          onExit.handler = (_) {
            if (!exited.isCompleted) {
              exited.complete();
            }
          };
          final isolate = await Isolate.spawn(
            _openCloseAndExit,
            (closed.sendPort, dbPath('exit.db'), mode),
            onExit: onExit.sendPort,
            onError: errors.sendPort,
          );
          final marker = await closed.first.timeout(
            const Duration(seconds: 30),
          );
          expect(marker, 'closed');
          // The child's main is done; its isolate must terminate even though
          // the link registered error/exit listeners while it was open.
          await exited.future.timeout(const Duration(seconds: 30));
          expect(
            childFailed.isCompleted,
            isFalse,
            reason: 'the child isolate must close cleanly, not crash',
          );
          closed.close();
          onExit.close();
          errors.close();
          isolate.kill(priority: Isolate.immediate);
        },
      );
    }
  });
}

/// The caller-isolate-death fixture: opens the database in background mode
/// and holds ONE transaction open (its write lock) until the isolate dies.
Future<void> _holdTransaction((SendPort, String) args) async {
  final (txOpen, path) = args;
  final db = await Cocoon.open(
    path,
    collections: [accounts, txns],
    options: const CocoonOptions(
      isolate: CocoonIsolate.background,
      durability: Durability.normal,
    ),
  );
  await db.runTransaction((tx) async {
    await tx.set(
      db.collection(accounts).doc('a1'),
      const Account(name: 'inside-tx', active: true),
    );
    txOpen.send(null);
    await Completer<void>().future; // killed before this completes
  });
}

/// The isolate-lifetime fixture: opens the database in [mode], does one
/// round trip, closes it and ends main. The test's `onExit` port proves the
/// isolate can actually terminate once its link's listeners are closed.
Future<void> _openCloseAndExit((SendPort, String, CocoonIsolate) args) async {
  final (done, path, mode) = args;
  final db = await Cocoon.open(
    path,
    collections: [accounts, txns],
    options: CocoonOptions(isolate: mode),
  );
  await db.collection(accounts).doc('a1').set(account('Acme'));
  await db.close();
  done.send('closed');
  // main ends here; the isolate must now be free to exit.
}
