import 'dart:async';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/transaction_guard.dart'
    show TransactionScope, currentScopeFor;
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/open_db.dart';

final otherTxn = Txn(
  bookedOn: 20260201,
  amountMinor: 42,
  rate: 1.0,
  currency: 'USD',
  status: TxnStatus.pending,
  createdAt: DateTime.utc(2026, 2, 1),
);

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({
    List<CollectionAdapter<Object?>>? collections,
  }) async {
    final opened = await openCocoon(
      dbPath(),
      collections: collections ?? [accounts, txns, splits],
    );
    openDbs.add(opened);
    return opened;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_tx_guard');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  /// The write-variant misuse: right operation, the `Fix:` line, and it
  /// fails within a second instead of waiting on a lock.
  Matcher writeMisuse(String operation) => throwsA(
    isA<TransactionMisuseError>()
        .having((error) => error.operation, 'operation', operation)
        .having(
          (error) => error.message,
          'message',
          allOf(
            contains(
              "it would wait forever for this transaction's own write lock.",
            ),
            contains(
              'Fix: use tx.set / tx.update / tx.delete inside the '
              'transaction, or call it after runTransaction returns.',
            ),
          ),
        ),
  );

  /// The read-variant misuse: right operation, the `Fix:` line, fails
  /// within a second.
  Matcher readMisuse(String operation) => throwsA(
    isA<TransactionMisuseError>()
        .having((error) => error.operation, 'operation', operation)
        .having(
          (error) => error.message,
          'message',
          allOf(
            contains(
              'it reads committed data only and cannot see this '
              "transaction's writes.",
            ),
            contains(
              'Fix: use tx.get / tx.getAll inside the transaction, or run '
              'the query before runTransaction and pass the ids in.',
            ),
          ),
        ),
  );

  /// Runs a body whose writes go through `tx` first and then hits the
  /// database directly with [misuse]; expects the write-variant error for
  /// [operation] within 1 s, and that the body's earlier write is gone
  /// (the error rolled the transaction back).
  Future<void> expectWriteGuard(
    String operation,
    Future<void> Function(Cocoon db) misuse,
  ) async {
    final db = await openDatabase();
    final victim = db.collection(accounts).doc('victim');
    await expectLater(
      db
          .runTransaction((tx) async {
            await tx.set(victim, const Account(name: 'victim', active: true));
            await misuse(db);
          })
          .timeout(const Duration(seconds: 1)),
      writeMisuse(operation),
    );
    expect(
      await victim.get(),
      isNull,
      reason: 'the misuse error must roll the body back',
    );
  }

  /// Runs [misuse] on the database inside a body; expects the read-variant
  /// error for [operation] within 1 s.
  Future<void> expectReadGuard(
    String operation,
    Future<void> Function(Cocoon db) misuse,
  ) async {
    final db = await openDatabase();
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true));
    await expectLater(
      db.runTransaction((_) => misuse(db)).timeout(const Duration(seconds: 1)),
      readMisuse(operation),
    );
  }

  group('guarded write paths', () {
    test('DocRef.set', () async {
      await expectWriteGuard('DocRef.set', (db) async {
        await db
            .collection(accounts)
            .doc('victim')
            .set(const Account(name: 'again', active: false));
      });
    });

    test('DocRef.delete', () async {
      await expectWriteGuard('DocRef.delete', (db) async {
        await db.collection(accounts).doc('victim').delete();
      });
    });

    test('CollectionRef.add', () async {
      await expectWriteGuard('CollectionRef.add', (db) async {
        await db
            .collection(accounts)
            .add(const Account(name: 'added', active: true));
      });
    });

    test('WriteBatch.commit', () async {
      await expectWriteGuard('WriteBatch.commit', (db) async {
        final batch = db.batch()
          ..set(
            db.collection(accounts).doc('batched'),
            const Account(name: 'batched', active: true),
          );
        await batch.commit();
      });
    });

    test('Cocoon.bulkWriter (creation)', () async {
      await expectWriteGuard('Cocoon.bulkWriter', (db) async {
        db.bulkWriter();
      });
    });

    test(
      'BulkWriter.set / flush / close (writer from outside the body)',
      () async {
        final db = await openDatabase();
        final bulk = db.bulkWriter();
        final victim = db.collection(accounts).doc('victim');
        await expectLater(
          db
              .runTransaction((tx) async {
                await tx.set(
                  victim,
                  const Account(name: 'victim', active: true),
                );
                bulk.set(
                  db.collection(accounts).doc('bulk'),
                  const Account(name: 'bulk', active: true),
                );
              })
              .timeout(const Duration(seconds: 1)),
          writeMisuse('BulkWriter.set'),
        );
        expect(await victim.get(), isNull, reason: 'the body must roll back');

        final flushVictim = db.collection(accounts).doc('flush-victim');
        await expectLater(
          db
              .runTransaction((tx) async {
                await tx.set(
                  flushVictim,
                  const Account(name: 'victim', active: true),
                );
                await bulk.flush();
              })
              .timeout(const Duration(seconds: 1)),
          writeMisuse('BulkWriter.flush'),
        );
        expect(await flushVictim.get(), isNull);

        final closeVictim = db.collection(accounts).doc('close-victim');
        await expectLater(
          db
              .runTransaction((tx) async {
                await tx.set(
                  closeVictim,
                  const Account(name: 'victim', active: true),
                );
                await bulk.close();
              })
              .timeout(const Duration(seconds: 1)),
          writeMisuse('BulkWriter.close'),
        );
        expect(await closeVictim.get(), isNull);

        // The guard checked before any state change: the writer is still
        // usable and finishes normally outside the transaction.
        await bulk.close();
      },
    );

    test('nested Cocoon.runTransaction', () async {
      final db = await openDatabase();
      final victim = db.collection(accounts).doc('victim');
      await expectLater(
        db.runTransaction((tx) async {
          await tx.set(victim, const Account(name: 'victim', active: true));
          await db
              .runTransaction((_) async {})
              .timeout(const Duration(seconds: 1));
        }),
        throwsA(
          isA<TransactionMisuseError>()
              .having(
                (error) => error.operation,
                'operation',
                'Cocoon.runTransaction',
              )
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('Nested runTransaction calls are not supported'),
                  contains('Fix: use the outer tx'),
                ),
              ),
        ),
      );
      expect(await victim.get(), isNull, reason: 'the body must roll back');
    });

    test('BulkWriter.delete', () async {
      final db = await openDatabase();
      final bulk = db.bulkWriter();
      final victim = db.collection(accounts).doc('victim');
      await expectLater(
        db
            .runTransaction((tx) async {
              await tx.set(victim, const Account(name: 'victim', active: true));
              bulk.delete(db.collection(accounts).doc('victim'));
            })
            .timeout(const Duration(seconds: 1)),
        writeMisuse('BulkWriter.delete'),
      );
      expect(await victim.get(), isNull);
      await bulk.close();
    });
  });

  group('guarded read paths', () {
    test('DocRef.get', () async {
      await expectReadGuard('DocRef.get', (db) async {
        await db.collection(accounts).doc('a1').get();
      });
    });

    test('CollectionRef.get', () async {
      await expectReadGuard('CollectionRef.get', (db) async {
        await db.collection(accounts).get();
      });
    });

    test('CollectionRef.count', () async {
      await expectReadGuard('CollectionRef.count', (db) async {
        await db.collection(accounts).count();
      });
    });

    test('CollectionRef.getAll', () async {
      await expectReadGuard('CollectionRef.getAll', (db) async {
        await db.collection(accounts).getAll(['a1']);
      });
    });

    test('CocoonQuery.get', () async {
      await expectReadGuard('CocoonQuery.get', (db) async {
        await db.collection(accounts).query().get();
      });
    });

    test('CocoonQuery.count', () async {
      await expectReadGuard('CocoonQuery.count', (db) async {
        await db.collection(accounts).query().count();
      });
    });

    test('CocoonQuery.get on a collection group', () async {
      await expectReadGuard('CocoonQuery.get', (db) async {
        await db.collectionGroup(txns).query().allowFullScan().get();
      });
    });

    test('AggregateQuery.get', () async {
      await expectReadGuard('AggregateQuery.get', (db) async {
        await db.collection(accounts).query().aggregate([count()]).get();
      });
    });

    test('AggregateGroupQuery.get', () async {
      await expectReadGuard('AggregateGroupQuery.get', (db) async {
        await db
            .collection(accounts)
            .query()
            .groupBy([key(accountName)])
            .aggregate([count()])
            .get();
      });
    });

    test('Cocoon.getAll', () async {
      await expectReadGuard('Cocoon.getAll', (db) async {
        await db.getAll([db.collection(accounts).doc('a1')]);
      });
    });

    test('Cocoon.backupTo', () async {
      final db = await openDatabase();
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      await expectLater(
        db
            .runTransaction((_) => db.backupTo(dbPath('backup.db')))
            .timeout(const Duration(seconds: 1)),
        readMisuse('Cocoon.backupTo'),
      );
      expect(File(dbPath('backup.db')).existsSync(), isFalse);
    });
  });

  group('what stays allowed', () {
    test(
      'tx.get, tx.getAll, tx.set and tx.delete see the transaction writes',
      () async {
        final db = await openDatabase();
        final a1 = db.collection(accounts).doc('a1');
        final existing = await a1.collection(txns).add(otherTxn);

        await db.runTransaction((tx) async {
          await tx.set(a1, const Account(name: 'Updated', active: true));
          final inside = await tx.get(a1);
          expect(inside!.data.name, 'Updated');
          final account = await tx.getAll([a1]);
          expect(account.single!.data.name, 'Updated');
          final txnSnap = await tx.getAll([existing]);
          expect(txnSnap.single, isNotNull);
          await tx.delete(existing);
          expect(await tx.get(existing), isNull);
        });

        expect((await a1.get())!.data.name, 'Updated');
        expect(await existing.get(), isNull);
      },
    );

    test(
      'a second open Cocoon on another file can be read and written',
      () async {
        final db = await openDatabase();
        final other = await openCocoon(
          dbPath('other.db'),
          collections: [accounts, txns, splits],
        );
        openDbs.add(other);
        final otherRef = other.collection(accounts).doc('o1');

        await db.runTransaction((tx) async {
          expect(await otherRef.get(), isNull);
          await otherRef.set(const Account(name: 'Other', active: true));
          expect((await otherRef.get())!.data.name, 'Other');
        });

        expect((await otherRef.get())!.data.name, 'Other');
      },
    );

    test(
      'a runTransaction on another database inside the body is allowed',
      () async {
        final db = await openDatabase();
        final other = await openCocoon(
          dbPath('other.db'),
          collections: [accounts, txns, splits],
        );
        openDbs.add(other);
        final otherRef = other.collection(accounts).doc('o1');

        await db.runTransaction((tx) async {
          await other.runTransaction((otx) async {
            await otx.set(
              otherRef,
              const Account(name: 'Nested', active: true),
            );
          });
        });

        expect((await otherRef.get())!.data.name, 'Nested');
      },
    );

    test(
      'a future created in the body works once runTransaction returned',
      () async {
        final db = await openDatabase();
        final baseline = db.collection(accounts).doc('baseline');
        await baseline.set(const Account(name: 'baseline', active: true));
        final late1 = db.collection(accounts).doc('late1');
        final gate = Completer<void>();
        Future<void>? detached;
        TransactionScope? seen;

        await db.runTransaction((tx) async {
          seen = currentScopeFor(db);
          expect(seen, isNotNull, reason: 'the body runs inside its scope');
          // Registered inside the body: runs later, in the body's zone.
          detached = gate.future.then((_) async {
            // A cached read never reaches SQLite: on the pinned sqlite_async
            // a continuation created inside a transaction body carries the
            // library's own internal lock-guard zone and a WRITE through the
            // same database fails with its LockError even after the
            // transaction ended (an upstream trap, see doc/design.md — the
            // raw probe there shows the same failure without Cocoon).
            // The Cocoon guard must be inactive here either way.
            expect((await baseline.get())!.data.name, 'baseline');
            // Escape the stale upstream zone so the write can actually
            // complete; a TransactionMisuseError here would be a guard bug.
            await Zone.root.run(
              () => late1.set(const Account(name: 'late', active: true)),
            );
          });
        });
        gate.complete();

        await detached; // scope inactive: no TransactionMisuseError
        expect(seen!.active, isFalse, reason: 'the commit ended the scope');
        expect((await late1.get())!.data.name, 'late');
      },
    );

    test('the same after a body that threw (rollback)', () async {
      final db = await openDatabase();
      final late2 = db.collection(accounts).doc('late2');
      final gate = Completer<void>();
      Future<void>? detached;
      TransactionScope? seen;

      await expectLater(
        db.runTransaction((tx) async {
          seen = currentScopeFor(db);
          detached = gate.future.then(
            (_) => Zone.root.run(
              () => late2.set(const Account(name: 'late', active: true)),
            ),
          );
          throw StateError('boom');
        }),
        throwsStateError,
      );
      gate.complete();

      await detached;
      expect(seen!.active, isFalse, reason: 'the rollback ended the scope');
      expect((await late2.get())!.data.name, 'late');
    });

    test(
      'watch created inside the body emits normally after the commit',
      () async {
        final db = await openDatabase();
        final doc = db.collection(accounts).doc('watched');
        await doc.set(const Account(name: 'baseline', active: true));

        final events = <String>[];
        late StreamSubscription<DocSnapshot<Account>?> sub;
        await db.runTransaction((tx) async {
          sub = doc.watch().listen(
            (snapshot) => events.add(snapshot?.data.name ?? '<absent>'),
          );
          await tx.set(doc, const Account(name: 'committed', active: true));
        });

        // The first emission reflects committed data; the transaction's own
        // write arrives with its commit event.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(events.first, 'baseline');
        await doc.set(const Account(name: 'after', active: true));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(events, contains('committed'));
        expect(events, contains('after'));
        await sub.cancel();
      },
    );

    test('batch commit outside any transaction is unaffected', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      final batch = db.batch()
        ..set(a1, const Account(name: 'Acme', active: true));
      await batch.commit();
      expect((await a1.get())!.data.name, 'Acme');
    });

    test('bulkWriter outside any transaction is unaffected', () async {
      final db = await openDatabase();
      final ref = db.collection(accounts).doc('a1');
      final bulk = db.bulkWriter()
        ..set(ref, const Account(name: 'Acme', active: true));
      await bulk.close();
      expect((await ref.get())!.data.name, 'Acme');
    });

    test('normal writes outside any transaction are unaffected', () async {
      final db = await openDatabase();
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(const Account(name: 'Acme', active: true));
      final added = await db
          .collection(accounts)
          .add(const Account(name: 'Beta', active: false));
      await a1.delete();
      expect(await a1.get(), isNull);
      expect((await added.get())!.data.name, 'Beta');
    });
  });
}
