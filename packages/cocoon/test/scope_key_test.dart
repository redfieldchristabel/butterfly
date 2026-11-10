import 'dart:io';
import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/schema_sql.dart';
import 'package:test/test.dart';

import 'support/models.dart';

/// The scope key IS the stored identity in the format-2 layout: the p_ param
/// columns plus id, one unique index, and the full path derived from it.
/// These tests pin the derivation in both directions.
void main() {
  final entry = SchemaRegistry.build([accounts, txns, splits]).entryFor(txns);

  group('scope key derivation', () {
    test('path -> (params, id) -> path round-trips', () {
      const path = 'accounts/a1/txns/t9';
      final key = entry.scopeKeyOf(path)!;
      expect(key.paramValues, ['a1']);
      expect(key.id, 't9');
      expect(entry.pathOfRow(key.paramValues, key.id), path);
    });

    test('a root collection derives paths from the id alone', () {
      final accountsEntry = SchemaRegistry.build([accounts]).entryFor(accounts);
      const path = 'accounts/a1';
      final key = accountsEntry.scopeKeyOf(path)!;
      expect(key.paramValues, isEmpty);
      expect(key.id, 'a1');
      expect(accountsEntry.pathOfRow(key.paramValues, key.id), path);
    });

    test('nested subcollections keep every ancestor param in order', () {
      final splitsEntry = SchemaRegistry.build([
        accounts,
        txns,
        splits,
      ]).entryFor(splits);
      const path = 'accounts/a1/txns/t2/splits/s3';
      final key = splitsEntry.scopeKeyOf(path)!;
      expect(key.paramValues, ['a1', 't2']);
      expect(key.id, 's3');
      expect(splitsEntry.pathOfRow(key.paramValues, key.id), path);
    });

    test('ids with odd characters survive the round trip', () {
      const oddIds = [
        '0', // sorts before the collection-prefix guard character
        'a b c', // spaces
        'über-идентификator', // unicode
        "quote'and\"double", // quotes
        'dash-under.dot', // punctuation
        '0x00-reserved-looking',
        r'back\slash', // backslash
        'emoji-🦋',
      ];
      for (final id in oddIds) {
        final path = 'accounts/acct 1/txns/$id';
        final key = entry.scopeKeyOf(path)!;
        expect(key.paramValues, ['acct 1']);
        expect(key.id, id);
        expect(entry.pathOfRow(key.paramValues, key.id), path);
      }
    });

    test('paths of another shape or collection do not match', () {
      expect(entry.scopeKeyOf('accounts/a1'), isNull); // a document, not txn
      expect(entry.scopeKeyOf('accounts/a1/txns'), isNull); // a collection
      expect(entry.scopeKeyOf('accounts/a1/ledger/t1'), isNull);
      expect(entry.scopeKeyOf('a1/txns/t1'), isNull); // missing the root
      expect(entry.scopeKeyOf('accounts/a1/txns/t1/extra'), isNull);
    });

    test('key columns are the p_ params then id, matching the scope index', () {
      expect(entry.keyColumns, ['p_account_id', 'id']);
      final accountsEntry = SchemaRegistry.build([accounts]).entryFor(accounts);
      expect(accountsEntry.keyColumns, ['id']);
    });
  });

  group('scope key uniqueness', () {
    test(
      'the same id under two parents coexists; the same scope key upserts',
      () async {
        final dir = Directory.systemTemp.createTempSync('cocoon_scope_test');
        try {
          final db = await Cocoon.open(
            '${dir.path}${Platform.pathSeparator}scope.db',
            collections: [accounts, txns],
          );
          final a1 = db.collection(accounts).doc('a1');
          final a2 = db.collection(accounts).doc('a2');
          await a1.set(const Account(name: 'one', active: true));
          await a2.set(const Account(name: 'two', active: true));
          final t1OfA1 = a1.collection(txns).doc('t1');
          final t1OfA2 = a2.collection(txns).doc('t1');
          await t1OfA1.set(
            Txn(
              bookedOn: 20260101,
              amountMinor: 100,
              rate: 1,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          );
          await t1OfA2.set(
            Txn(
              bookedOn: 20260101,
              amountMinor: 200,
              rate: 1,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          );
          // Same id, different parents: two rows, one per scope key.
          expect((await t1OfA1.get())!.data.amountMinor, 100);
          expect((await t1OfA2.get())!.data.amountMinor, 200);
          expect(await a1.collection(txns).count(), 1);
          expect(await a2.collection(txns).count(), 1);

          // Same scope key again: the upsert replaces, it does not duplicate.
          await t1OfA1.set(
            Txn(
              bookedOn: 20260101,
              amountMinor: 300,
              rate: 1,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          );
          expect((await t1OfA1.get())!.data.amountMinor, 300);
          expect(await a1.collection(txns).count(), 1);
          expect(
            await db.collectionGroup(txns).query().allowFullScan().count(),
            2,
          );
          await db.close();
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
    );
  });
}
