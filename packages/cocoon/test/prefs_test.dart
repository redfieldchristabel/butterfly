import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/naming.dart'
    show metaTableName, prefsTableName;
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/open_db.dart';

/// An older library version's v1 layout: name + active only (no note).
final class _V1AccountAdapter extends CollectionAdapter<Account> {
  @override
  String get model => 'Account';

  @override
  final pattern = CollectionPattern.parse('accounts');

  @override
  List<FieldColumn<Account, Object?>> get columns => [
    accountName,
    accountActive,
  ];

  @override
  List<IndexDef> get indexes => const [];

  @override
  Uint8List encode(Account value) {
    final writer = WireWriter();
    writer.writeString(1, value.name);
    writer.writeBool(2, value.active);
    return writer.toBytes();
  }

  @override
  Account decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var active = false;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 2:
          active = reader.readBool();
        default:
          reader.skip(tag.type);
      }
    }
    return Account(name: name, active: active);
  }
}

/// A v3 layout where the note field moved to number 8; the encode produces
/// the moved layout with the engine's own migration helper.
final class _V3AccountAdapter extends CollectionAdapter<Account> {
  @override
  String get model => 'Account';

  @override
  final pattern = CollectionPattern.parse('accounts');

  @override
  List<FieldColumn<Account, Object?>> get columns => [
    accountName,
    accountActive,
  ];

  @override
  List<IndexDef> get indexes => const [];

  @override
  Uint8List encode(Account value) {
    final current = accounts.encode(value);
    if (value.note == null) {
      return current;
    }
    return rewriteField(
      current,
      from: 3,
      fromWire: MigrationWireType.text,
      to: 8,
      toWire: MigrationWireType.text,
      convert: (value) => value,
    );
  }

  @override
  Account decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var active = false;
    String? note;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 2:
          active = reader.readBool();
        case 8:
          note = reader.readString();
        default:
          reader.skip(tag.type);
      }
    }
    return Account(name: name, active: active, note: note);
  }
}

final v1Account = _V1AccountAdapter();
final v3Account = _V3AccountAdapter();

/// A Txn fixture for the wrong-adapter test: every stored column rides.
final allTypesTxn = Txn(
  bookedOn: 20260115,
  amountMinor: -12999,
  rate: 1.25,
  currency: 'USD',
  status: TxnStatus.posted,
  createdAt: DateTime.utc(2026, 1, 15),
  memo: 'all types',
);

/// Broadcast controllers deliver asynchronously; pump the microtask queue.
Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({
    CocoonOptions options = const CocoonOptions(),
    List<CollectionAdapter<Object?>>? collections,
    bool preloadPrefs = false,
    String? path,
  }) async {
    final opened = await openCocoon(
      path ?? dbPath(),
      collections: collections ?? [accounts, txns, splits],
      options: options,
      preloadPrefs: preloadPrefs,
    );
    openDbs.add(opened);
    return opened;
  }

  /// Opens in caller mode regardless of `COCOON_TEST_ISOLATE`: the raw-DDL
  /// assertions below read `db.executor`, which only exists on the caller —
  /// every other executor-using slice (backup, write buffer, changes)
  /// pins caller mode the same way.
  Future<Cocoon> openCallerDatabase() async {
    final opened = await Cocoon.open(
      dbPath(),
      collections: [accounts, txns, splits],
    );
    openDbs.add(opened);
    return opened;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_prefs_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  group('storage', () {
    test(
      'the internal table is created at open, WITHOUT ROWID, reserved',
      () async {
        final db = await openCallerDatabase();
        final row = await db.executor.getOptional(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
          [prefsTableName],
        );
        expect(row, isNotNull);
        expect(row!['sql']! as String, contains('WITHOUT ROWID'));
        // Reserved: [tableNameFor] rejects any model mapping to the prefix.
        expect(() => tableNameFor('_CocoinPrefs'), throwsArgumentError);
        final meta = await db.executor.getOptional(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [metaTableName],
        );
        expect(meta, isNotNull);
      },
    );

    test(
      'a fresh database reports no prefs; no index beyond the primary key',
      () async {
        final db = await openCallerDatabase();
        expect(await db.prefs.keys(), []);
        expect(await db.prefs.preload(), 0);
        final indexes = await db.executor.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
          [prefsTableName],
        );
        // A text primary key on a WITHOUT ROWID table is the table itself.
        expect(indexes, isEmpty);
      },
    );
  });

  group('prefs round trips', () {
    test('every primitive round trips; absent key is null', () async {
      final db = await openDatabase(preloadPrefs: true);
      final prefs = db.prefs;
      await prefs.setString('theme', 'dark');
      await prefs.setInt('launchCount', 3);
      await prefs.setBool('onboarded', true);
      await prefs.setDouble('textScale', 1.2);
      await prefs.setBytes('blob', Uint8List.fromList([1, 2, 3, 255]));
      await prefs.setInt('negative', -12345);

      expect(await prefs.getString('theme'), 'dark');
      expect(await prefs.getInt('launchCount'), 3);
      expect(await prefs.getBool('onboarded'), true);
      expect(await prefs.getDouble('textScale'), 1.2);
      expect(await prefs.getBytes('blob'), Uint8List.fromList([1, 2, 3, 255]));
      expect(await prefs.getInt('negative'), -12345);

      expect(await prefs.getString('absent'), null);
      expect(await prefs.getInt('absent'), null);
      expect(await prefs.getBool('absent'), null);
      expect(await prefs.getDouble('absent'), null);
      expect(await prefs.getBytes('absent'), null);
      expect(await prefs.containsKey('absent'), false);
      expect(await prefs.containsKey('theme'), true);

      // The sync surface agrees after open-time preload.
      expect(prefs.getStringSync('theme'), 'dark');
      expect(prefs.getIntSync('launchCount'), 3);
      expect(prefs.getBoolSync('onboarded'), true);
      expect(prefs.getDoubleSync('textScale'), 1.2);
      expect(prefs.getBytesSync('blob'), Uint8List.fromList([1, 2, 3, 255]));
      expect(prefs.getStringSync('absent'), null);
      expect(prefs.containsKeySync('absent'), false);
    });

    test('overwrite changes the value; remove; keys sorted; clear', () async {
      final db = await openDatabase(preloadPrefs: true);
      final prefs = db.prefs;
      await prefs.setString('theme', 'dark');
      await prefs.setString('theme', 'light');
      expect(await prefs.getString('theme'), 'light');
      expect(prefs.getStringSync('theme'), 'light');

      await prefs.setInt('a', 3);
      await prefs.setString('b', 'x');
      await prefs.setBool('c', true);
      expect(await prefs.keys(), ['a', 'b', 'c', 'theme']);
      expect(prefs.keysSync(), ['a', 'b', 'c', 'theme']);

      await prefs.remove('b');
      expect(await prefs.containsKey('b'), false);
      expect(await prefs.keys(), ['a', 'c', 'theme']);
      // Removing an absent key changes nothing.
      await prefs.remove('never-there');
      expect(await prefs.keys(), ['a', 'c', 'theme']);

      // Clear removes every pref; collections are untouched.
      final a1 = db.collection(accounts).doc('a1');
      await a1.set(const Account(name: 'Acme', active: true));
      await prefs.clear();
      expect(await prefs.keys(), []);
      expect(prefs.keysSync(), []);
      expect((await a1.get())!.data.name, 'Acme');
    });

    test(
      'wrong-kind read throws PrefsTypeException naming everything',
      () async {
        final db = await openDatabase(preloadPrefs: true);
        final prefs = db.prefs;
        await prefs.setString('theme', 'dark');
        await prefs.setBytes('blob', Uint8List.fromList([1]));

        await expectLater(
          prefs.getInt('theme'),
          throwsA(
            isA<PrefsTypeException>()
                .having((e) => e.key, 'key', 'theme')
                .having((e) => e.storedKind, 'storedKind', 'string')
                .having((e) => e.requestedKind, 'requestedKind', 'int')
                .having(
                  (e) => e.toString(),
                  'toString',
                  allOf(contains('theme'), contains('string'), contains('int')),
                ),
          ),
        );
        await expectLater(
          prefs.getString('blob'),
          throwsA(isA<PrefsTypeException>()),
        );
        // The sync surface throws the same error.
        expect(
          () => prefs.getIntSync('theme'),
          throwsA(isA<PrefsTypeException>()),
        );
        // Never garbage: a wrong-kind read never serves a value.
        var served = 'garbage';
        try {
          served = await prefs.getInt('theme') as String;
        } on PrefsTypeException {
          served = 'clear';
        }
        expect(served, 'clear');
      },
    );

    test('invalid keys throw ArgumentError', () async {
      final db = await openDatabase(preloadPrefs: true);
      final prefs = db.prefs;
      final tooLong = 'x' * 257;
      expect(() => prefs.setString('', 'x'), throwsA(isA<ArgumentError>()));
      expect(
        () => prefs.setString(tooLong, 'x'),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => prefs.getString(''), throwsA(isA<ArgumentError>()));
      expect(() => prefs.getString(tooLong), throwsA(isA<ArgumentError>()));
      expect(() => prefs.getStringSync(''), throwsA(isA<ArgumentError>()));
      expect(
        () => prefs.containsKeySync(tooLong),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => prefs.remove(''), throwsA(isA<ArgumentError>()));
      // Exactly 256 UTF-8 bytes is fine.
      await prefs.setString('y' * 256, 'ok');
      expect(await prefs.getString('y' * 256), 'ok');
    });

    test('survives close and reopen; closed database errors', () async {
      final path = dbPath();
      final db = await openDatabase(path: path, preloadPrefs: true);
      await db.prefs.setString('theme', 'dark');
      await db.prefs.setInt('launchCount', 3);
      await db.close();
      openDbs.remove(db);

      // Async + sync + watch start all throw the closed-database error.
      await expectLater(
        db.prefs.setString('x', 'y'),
        throwsA(isA<StateError>()),
      );
      expect(() => db.prefs.getStringSync('theme'), throwsA(isA<StateError>()));
      expect(
        () => db.prefs.containsKeySync('theme'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => db.prefs.watch<dynamic>('theme'),
        throwsA(isA<StateError>()),
      );

      final reopened = await openDatabase(path: path, preloadPrefs: true);
      expect(await reopened.prefs.getString('theme'), 'dark');
      expect(reopened.prefs.getIntSync('launchCount'), 3);
      expect(await reopened.prefs.keys(), ['launchCount', 'theme']);
    });
  });

  group('watch', () {
    test(
      'emits the current value first, then set/remove; other keys never',
      () async {
        final db = await openDatabase(preloadPrefs: true);
        final prefs = db.prefs;
        final emissions = <Object?>[];
        final sub = prefs.watch<dynamic>('theme').listen(emissions.add);
        await pump();
        expect(emissions, [null]); // current value first: absent

        await prefs.setString('theme', 'dark');
        await prefs.setString('other', 'x');
        await prefs.setString('theme', 'light');
        await prefs.remove('theme');
        await prefs.setString('theme', 'dark');
        await pump();
        expect(emissions, [null, 'dark', 'light', null, 'dark']);
        await sub.cancel();
      },
    );

    test('a covering clear wakes every covered watch with null', () async {
      final db = await openDatabase(preloadPrefs: true);
      final prefs = db.prefs;
      await prefs.setString('theme', 'dark');
      await prefs.setInt('launchCount', 1);
      final themeEmissions = <Object?>[];
      final sub = prefs.watch<dynamic>('theme').listen(themeEmissions.add);
      await pump();
      expect(themeEmissions, ['dark']);

      await prefs.clear();
      await pump();
      expect(themeEmissions, ['dark', null]);
      await sub.cancel();

      // A clear covering an absent key emits nothing.
      final absentEmissions = <Object?>[];
      final sub2 = prefs.watch<dynamic>('absent').listen(absentEmissions.add);
      await pump();
      expect(absentEmissions, [null]);
      await prefs.clear();
      await pump();
      expect(absentEmissions, [null]);
      await sub2.cancel();
    });

    test('typed watch emits a wrong-kind read as an error event; next write '
        'fixes the kind', () async {
      final db = await openDatabase(preloadPrefs: true);
      await db.prefs.setString('theme', 'dark');
      final errors = <Object?>[];
      final values = <int?>[];
      final sub = db.prefs
          .watch<int>('theme')
          .listen(values.add, onError: errors.add);
      await pump();
      expect(values, isEmpty);
      expect(errors, [isA<PrefsTypeException>()]);

      await db.prefs.setInt('theme', 3);
      await pump();
      expect(values, [3]);
      expect(errors, [isA<PrefsTypeException>()]);
      await sub.cancel();
    });

    test('cancel leaks no listener; close completes streams', () async {
      final db = await openDatabase(preloadPrefs: true);
      final prefs = db.prefs;
      final done = Completer<void>();
      final emissions = <Object?>[];
      final sub = prefs
          .watch<dynamic>('theme')
          .listen(emissions.add, onDone: done.complete);
      await pump();
      expect(prefs.debugMachineCount, 1);
      await prefs.setString('theme', 'dark');
      await pump();
      expect(emissions, [null, 'dark']);

      await sub.cancel();
      await pump();
      expect(prefs.debugMachineCount, 0);
      // Re-listening restarts the watcher (current value again).
      final sub2 = prefs.watch<dynamic>('theme').listen(emissions.add);
      await pump();
      expect(prefs.debugMachineCount, 1);
      expect(emissions.last, 'dark');
      await sub2.cancel();

      // After close, streams complete and no listener leaks.
      final done2 = Completer<void>();
      final sub3 = prefs
          .watch<dynamic>('launchCount')
          .listen((_) {}, onDone: done2.complete);
      await pump();
      await db.close();
      openDbs.remove(db);
      await done2.future;
      await sub3.cancel();
      await pump();
      expect(prefs.debugMachineCount, 0);
    });
  });

  group('transactions', () {
    test(
      'one transaction commits a collection document and a pref together',
      () async {
        final db = await openDatabase(preloadPrefs: true);
        final a1 = db.collection(accounts).doc('a1');
        await db.runTransaction((tx) async {
          await tx.set(a1, const Account(name: 'Ada', active: true));
          await tx.prefs.setString('currentUser', 'me');
        });
        expect((await a1.get())!.data.name, 'Ada');
        expect(await db.prefs.getString('currentUser'), 'me');
        // Write-through after the commit.
        expect(db.prefs.getStringSync('currentUser'), 'me');
      },
    );

    test(
      'a thrown error rolls back both stores; the preload map is unchanged',
      () async {
        final db = await openDatabase(preloadPrefs: true);
        await db.prefs.setString('currentUser', 'me');
        await db.prefs.setString('theme', 'dark');
        final themeEmissions = <Object?>[];
        final sub = db.prefs.watch<dynamic>('theme').listen(themeEmissions.add);
        await pump();
        final baseline = themeEmissions.isEmpty ? 0 : themeEmissions.length;

        final a1 = db.collection(accounts).doc('a1');
        await expectLater(
          db.runTransaction((tx) async {
            await tx.set(a1, const Account(name: 'Ada', active: true));
            await tx.prefs.setString('currentUser', 'someone-else');
            await tx.prefs.remove('theme');
            throw StateError('roll back');
          }),
          throwsA(isA<StateError>()),
        );
        await pump();

        expect(await a1.get(), null);
        expect(await db.prefs.getString('currentUser'), 'me');
        expect(db.prefs.getStringSync('currentUser'), 'me');
        expect(db.prefs.getStringSync('theme'), 'dark');
        // No watch emission for any of the rolled-back mutations.
        expect(themeEmissions.length, baseline);
        await sub.cancel();
      },
    );

    test(
      'read-your-writes inside the transaction (prefs and single)',
      () async {
        final db = await openDatabase(preloadPrefs: true);
        await db.prefs.setInt('launchCount', 1);
        await db
            .single(accounts, key: 'me')
            .set(const Account(name: 'Ada', active: true));
        await db.runTransaction((tx) async {
          await tx.prefs.setInt('launchCount', 2);
          expect(await tx.prefs.getInt('launchCount'), 2);
          await tx.prefs.remove('launchCount');
          expect(await tx.prefs.getInt('launchCount'), null);
          await tx
              .single(accounts, key: 'me')
              .set(const Account(name: 'Bob', active: false));
          expect((await tx.single(accounts, key: 'me').get())!.name, 'Bob');
          // The db surface cannot see uncommitted writes: the sync surface
          // (map, written through only post-commit) still holds the old values.
          expect(db.prefs.getIntSync('launchCount'), 1);
          expect(db.single(accounts, key: 'me').getSync()!.name, 'Ada');
        });
        expect(await db.prefs.getInt('launchCount'), null);
        expect((await db.single(accounts, key: 'me').get())!.name, 'Bob');
        expect(db.prefs.containsKeySync('launchCount'), false);
      },
    );

    test('db.prefs/db.single inside a transaction body throws '
        'TransactionMisuseError', () async {
      final db = await openDatabase();
      await expectLater(
        db.runTransaction((tx) async {
          await db.prefs.setString('theme', 'dark');
        }),
        throwsA(
          isA<TransactionMisuseError>().having(
            (e) => e.operation,
            'operation',
            'Prefs.setString',
          ),
        ),
      );
      await expectLater(
        db.runTransaction((tx) async {
          await db.prefs.getString('theme');
        }),
        throwsA(isA<TransactionMisuseError>()),
      );
      await expectLater(
        db.runTransaction((tx) async {
          await db.prefs.keys();
        }),
        throwsA(isA<TransactionMisuseError>()),
      );
      await expectLater(
        db.runTransaction((tx) async {
          await db
              .single(accounts, key: 'me')
              .set(const Account(name: 'Ada', active: true));
        }),
        throwsA(
          isA<TransactionMisuseError>().having(
            (e) => e.operation,
            'operation',
            'Single.set',
          ),
        ),
      );
      // The rolled-back transactions left nothing.
      expect(await db.prefs.getString('theme'), null);
    });

    test('batch.prefs commits with the documents in one transaction', () async {
      final db = await openDatabase(preloadPrefs: true);
      await db.prefs.setString('old', 'value');
      final themeEmissions = <Object?>[];
      final oldEmissions = <Object?>[];
      final sub = db.prefs.watch<dynamic>('theme').listen(themeEmissions.add);
      final sub2 = db.prefs.watch<dynamic>('old').listen(oldEmissions.add);
      await pump();

      final batch = db.batch();
      batch.set(
        db.collection(accounts).doc('a1'),
        const Account(name: 'Ada', active: true),
      );
      batch.prefs.setString('theme', 'dark');
      batch.prefs.remove('old');
      await batch.commit();
      await pump();

      expect(await db.prefs.getString('theme'), 'dark');
      expect(db.prefs.getStringSync('theme'), 'dark');
      expect(db.prefs.containsKeySync('old'), false);
      expect((await db.collection(accounts).doc('a1').get())!.data.name, 'Ada');
      expect(themeEmissions.last, 'dark');
      expect(oldEmissions.last, null);
      await sub.cancel();
      await sub2.cancel();
    });

    test('a failed batch rolls its prefs back', () async {
      final db = await openDatabase(preloadPrefs: true);
      await db.prefs.setString('theme', 'dark');
      final batch = db.batch();
      batch.prefs.setString('theme', 'light');
      batch.update(
        db.collection(accounts).doc('missing'),
        const Account(name: 'X', active: true),
      );
      await expectLater(batch.commit(), throwsA(isA<ArgumentError>()));
      expect(db.prefs.getStringSync('theme'), 'dark');
      expect(await db.prefs.getString('theme'), 'dark');
    });
  });

  group('single', () {
    test(
      'set/get/clear/watch without registering the model collection',
      () async {
        final db = await openDatabase(collections: [], preloadPrefs: true);
        // Nothing at all is registered here: a single needs no table and no
        // registration — the adapter's codecs are reused as-is. Its adapter
        // declares an index on name; indexes are ignored for singles.
        final currentUser = db.single(accounts, key: 'currentUser');
        expect(await currentUser.get(), null);
        expect(currentUser.getSync(), null);

        await currentUser.set(
          const Account(name: 'Ada', active: true, note: 'me'),
        );
        final u = await currentUser.get();
        expect(u!.name, 'Ada');
        expect(u.note, 'me');
        expect(currentUser.getSync()!.name, 'Ada');

        final emissions = <Account?>[];
        final sub = currentUser.watch().listen(emissions.add);
        await pump();
        expect(emissions, [isA<Account>()]);
        expect(emissions.first!.name, 'Ada');

        await currentUser.set(const Account(name: 'Bob', active: false));
        await pump();
        expect(emissions.last!.name, 'Bob');

        await currentUser.clear();
        await pump();
        expect(emissions.last, null);
        expect(await currentUser.get(), null);
        expect(currentUser.getSync(), null);
        await sub.cancel();
      },
    );

    test(
      'wrong-adapter read throws PrefsTypeException; writes overwrite',
      () async {
        final db = await openDatabase(collections: [], preloadPrefs: true);
        await db
            .single(accounts, key: 'me')
            .set(const Account(name: 'Ada', active: true));

        final txnSingle = db.single(txns, key: 'me');
        await expectLater(
          txnSingle.get(),
          throwsA(
            isA<PrefsTypeException>()
                .having((e) => e.key, 'key', 'me')
                .having(
                  (e) => e.storedKind,
                  'storedKind',
                  contains('single model'),
                )
                .having(
                  (e) => e.requestedKind,
                  'requestedKind',
                  contains('Txn'),
                ),
          ),
        );
        expect(() => txnSingle.getSync(), throwsA(isA<PrefsTypeException>()));
        // Reading the model key through the primitives throws too.
        await expectLater(
          db.prefs.getString('me'),
          throwsA(isA<PrefsTypeException>()),
        );

        // Writes overwrite whatever kind the row held.
        await txnSingle.set(allTypesTxn);
        expect((await txnSingle.get())!.amountMinor, allTypesTxn.amountMinor);
      },
    );

    test(
      'model evolution: older encoder bytes decode with newer adapters',
      () async {
        final db = await openDatabase(collections: [], preloadPrefs: true);
        final me = db.single(v1Account, key: 'me');
        await me.set(const Account(name: 'Ada', active: true, note: 'legacy'));

        // The current layout's adapter decodes v1 bytes: the note field is
        // absent, the constructor default fills it.
        expect((await db.single(accounts, key: 'me').get())!.note, null);

        // A field-number move (note: 3 -> 8), produced by the engine's own
        // rewriteField helper, round trips under its own adapter.
        final moved = db.single(v3Account, key: 'me');
        await moved.set(
          const Account(name: 'Bob', active: true, note: 'rewritten'),
        );
        expect((await moved.get())!.note, 'rewritten');
        // And the current layout's adapter skips the unknown field 8.
        expect((await db.single(accounts, key: 'me').get())!.note, null);
      },
    );

    test(
      'getSync caches the decoded model and invalidates on overwrite',
      () async {
        final db = await openDatabase(collections: [], preloadPrefs: true);
        final me = db.single(accounts, key: 'me');
        await me.set(const Account(name: 'Ada', active: true));
        expect(currentUserName(me), 'Ada');
        await me.set(const Account(name: 'Bob', active: false));
        expect(currentUserName(me), 'Bob');
        await me.clear();
        expect(me.getSync(), null);
      },
    );
  });

  group('backup, restore and sync', () {
    test('prefs travel with backups; restore brings back the backup\'s prefs '
        'and drops newer ones', () async {
      final path = dbPath();
      final backup = '$path.bak';
      final db = await openDatabase(path: path, preloadPrefs: true);
      await db.prefs.setString('currentUser', 'me');
      await db.prefs.setInt('launchCount', 3);
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      await db.backupTo(backup, overwrite: true);

      // Newer prefs after the backup are dropped by the restore.
      await db.prefs.setString('currentUser', 'someone-else');
      await db.prefs.setInt('launchCount', 10);
      await db.prefs.remove('launchCount');
      await db.close();
      openDbs.remove(db);

      await Cocoon.restoreBackup(
        backup: backup,
        path: path,
        collections: [accounts, txns, splits],
      );
      final reopened = await openDatabase(path: path, preloadPrefs: true);
      expect(await reopened.prefs.getString('currentUser'), 'me');
      expect(reopened.prefs.getIntSync('launchCount'), 3);
    });

    test('prefs writes never enter the change log', () async {
      final db = await openDatabase(); // keepChanges on (default)
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      await db.prefs.setString('theme', 'dark');
      await db.prefs.setInt('launchCount', 3);
      await db.prefs.remove('launchCount');

      final changes = await db.changesSince(0, limit: 100);
      expect(changes, isNotEmpty);
      expect(
        changes,
        everyElement(
          isA<Change>().having((c) => c.collection, 'collection', 'Account'),
        ),
      );
    });
  });

  group('preload', () {
    test(
      'sync getters throw before preload; the async surface still works',
      () async {
        final db = await openDatabase();
        await db.prefs.setString('k', 'v');
        expect(
          () => db.prefs.getStringSync('k'),
          throwsA(
            isA<StateError>().having(
              (e) => e.toString(),
              'toString',
              contains('preload'),
            ),
          ),
        );
        expect(() => db.prefs.keysSync(), throwsA(isA<StateError>()));
        expect(() => db.prefs.containsKeySync('k'), throwsA(isA<StateError>()));
        expect(
          () => db.single(accounts, key: 'me').getSync(),
          throwsA(isA<StateError>()),
        );
        expect(await db.prefs.getString('k'), 'v');
      },
    );

    test('preload is idempotent; earlier writes are not lost; count', () async {
      final db = await openDatabase();
      await db.prefs.setString('a', 'x');
      await db.prefs.setInt('b', 2);
      expect(await db.prefs.preload(), 2);
      expect(db.prefs.getStringSync('a'), 'x');
      expect(db.prefs.getIntSync('b'), 2);
      expect(await db.prefs.preload(), 2); // cheap twice
      await db.prefs.setString('c', 'y');
      expect(await db.prefs.preload(), 3);
      expect(db.prefs.getStringSync('c'), 'y');
    });

    test('preloadPrefs: true feeds the sync getters immediately', () async {
      final db = await openDatabase(preloadPrefs: true);
      expect(db.prefs.keysSync(), []);
      await db.prefs.setString('k', 'v');
      expect(db.prefs.getStringSync('k'), 'v');
    });

    test(
      'write-through after set/remove/clear and committed transactions',
      () async {
        final db = await openDatabase(preloadPrefs: true);
        await db.prefs.setString('a', 'x');
        expect(db.prefs.getStringSync('a'), 'x');
        await db.prefs.remove('a');
        expect(db.prefs.containsKeySync('a'), false);
        await db.prefs.setInt('b', 1);
        await db.prefs.clear();
        expect(db.prefs.keysSync(), []);
        await db.runTransaction((tx) async {
          await tx.prefs.setString('c', 'y');
        });
        expect(db.prefs.getStringSync('c'), 'y');
      },
    );

    test('prefs never route to the auto helper', () async {
      final db = await openDatabase(preloadPrefs: true);
      if (testIsolateMode == CocoonIsolate.auto) {
        await waitHelperReady(db);
      }
      await db.prefs.setString('theme', 'dark');
      expect(await db.prefs.getString('theme'), 'dark');
      await db.prefs.preload();
      expect(db.prefs.getStringSync('theme'), 'dark');
      expect(await db.prefs.keys(), ['theme']);
      if (testIsolateMode == CocoonIsolate.auto) {
        expect(db.isolateStats!.helperCalls, 0);
      }
    });

    test(
      'map and watch agree across 200 randomized operations (seeded)',
      () async {
        final db = await openDatabase(preloadPrefs: true);
        final prefs = db.prefs;
        final keys = [for (var i = 0; i < 8; i++) 'k$i'];
        final model = <String, Object?>{};
        final modelKind = <String, String>{};
        final emissions = <String, List<Object?>>{};
        final subs = <StreamSubscription<Object?>>[];
        for (final key in [...keys, 'txCounter']) {
          emissions[key] = [];
          subs.add(prefs.watch<dynamic>(key).listen(emissions[key]!.add));
        }
        await pump();
        final random = Random(20261115);
        final a1 = db.collection(accounts).doc('a1');

        for (var op = 0; op < 200; op++) {
          final key = keys[random.nextInt(keys.length)];
          switch (random.nextInt(6)) {
            case 0:
              final value = 's$op';
              await prefs.setString(key, value);
              model[key] = value;
              modelKind[key] = 'string';
            case 1:
              final value = op;
              await prefs.setInt(key, value);
              model[key] = value;
              modelKind[key] = 'int';
            case 2:
              await prefs.remove(key);
              model.remove(key);
              modelKind.remove(key);
            case 3:
              await prefs.clear();
              model.clear();
              modelKind.clear();
            case 4:
              final value = 't$op';
              await db.runTransaction((tx) async {
                await tx.prefs.setString(key, value);
                await tx.prefs.setInt('txCounter', op);
                await tx.set(a1, Account(name: 'n$op', active: true));
              });
              model[key] = value;
              modelKind[key] = 'string';
              model['txCounter'] = op;
              modelKind['txCounter'] = 'int';
            case 5:
              await expectLater(
                db.runTransaction((tx) async {
                  await tx.prefs.setString(key, 'never');
                  throw StateError('roll back');
                }),
                throwsA(isA<StateError>()),
              );
            // The model is unchanged.
          }
          await pump();
          for (final key in emissions.keys) {
            switch (modelKind[key]) {
              case 'string':
                expect(
                  prefs.getStringSync(key),
                  model[key],
                  reason: 'op $op key $key',
                );
              case 'int':
                expect(
                  prefs.getIntSync(key),
                  model[key],
                  reason: 'op $op key $key',
                );
              default:
                expect(
                  prefs.containsKeySync(key),
                  false,
                  reason: 'op $op key $key',
                );
            }
            final last = emissions[key]!.isEmpty ? null : emissions[key]!.last;
            expect(last, model[key], reason: 'emission op $op key $key');
          }
        }
        for (final sub in subs) {
          await sub.cancel();
        }
        expect(prefs.debugMachineCount, 0);
      },
    );

    test(
      'micro: 10k getSync after preload vs 10k get without it (printed)',
      () async {
        final db = await openDatabase();
        final prefs = db.prefs;
        await prefs.setString('k', 'value');

        var t = Stopwatch()..start();
        for (var i = 0; i < 10000; i++) {
          await prefs.getString('k');
        }
        t.stop();
        final without = t.elapsedMicroseconds / 10000;

        await prefs.preload();
        t = Stopwatch()..start();
        for (var i = 0; i < 10000; i++) {
          prefs.getStringSync('k');
        }
        t.stop();
        final withSync = t.elapsedMicroseconds / 10000;

        print(
          'micro: 10k get (SQL) ${without.toStringAsFixed(2)}us/op vs '
          '10k getSync (memory) ${withSync.toStringAsFixed(3)}us/op',
        );
        expect(withSync, lessThan(without));
      },
    );
  });
}

/// Reads the single's synced model name off the sync surface (the sync
/// getter under test in the caching test).
String? currentUserName(Single<Account> me) => me.getSync()?.name;
