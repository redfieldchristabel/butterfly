import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/naming.dart';
import 'package:cocoon/src/engine/schema_sql.dart';
import 'package:test/test.dart';

import 'support/models.dart';

final accountEntry = SchemaRegistry.build([
  accounts,
]).byPattern(accounts.pattern)!;
final txnEntry = SchemaRegistry.build([
  accounts,
  txns,
]).byPattern(txns.pattern)!;
final txnNoMemoEntry = SchemaRegistry.build([
  accounts,
  txnsWithoutMemo,
]).byPattern(txnsWithoutMemo.pattern)!;
final splitEntry = SchemaRegistry.build([
  accounts,
  txns,
  splits,
]).byPattern(splits.pattern)!;

void main() {
  group('naming', () {
    test('snake_case conversion', () {
      expect(snakeCase('Txn'), 'txn');
      expect(snakeCase('AccountNote'), 'account_note');
      expect(snakeCase('HTTPServer'), 'http_server');
      expect(snakeCase('already_snake'), 'already_snake');
    });

    test('table names derive from models and refuse reserved prefixes', () {
      expect(tableNameFor('Txn'), 'txn');
      expect(tableNameFor('AccountNote'), 'account_note');
      expect(
        () => tableNameFor('Sqlite_master'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('sqlite_'),
          ),
        ),
      );
      expect(() => tableNameFor('_CocoonMeta'), throwsArgumentError);
      expect(() => tableNameFor('123bad'), throwsArgumentError);
    });

    test('column names mirror fields and params', () {
      expect(fieldColumnName('bookedOn'), 'f_booked_on');
      expect(paramColumnName('accountId'), 'p_account_id');
    });
  });

  group('create table', () {
    final entry = txnEntry;

    test('declares id, params, data and checked field columns, no path', () {
      final sql = createTableSql(
        entry.table,
        entry.paramSqlNames,
        entry.columnDdls,
      );
      // The format-2 layout: identity is the scope key; there is no stored
      // `path` column and no UNIQUE constraint beyond the scope index.
      expect(sql, isNot(contains('path')));
      expect(sql, contains('id TEXT NOT NULL'));
      expect(sql, contains('p_account_id TEXT NOT NULL'));
      expect(sql, contains('data BLOB NOT NULL'));
      expect(
        sql,
        contains(
          "f_booked_on INTEGER NOT NULL CHECK (typeof(f_booked_on) = 'integer')",
        ),
      );
      // Nullable text column: NULL allowed by the CHECK, no NOT NULL.
      expect(
        sql,
        contains(
          "f_memo TEXT CHECK (f_memo IS NULL OR typeof(f_memo) = 'text')",
        ),
      );
      expect(sql, isNot(contains('f_memo TEXT NOT NULL')));
    });

    test('root collections have no param columns', () {
      final accountsEntry = accountEntry;
      final sql = createTableSql(
        accountsEntry.table,
        accountsEntry.paramSqlNames,
        accountsEntry.columnDdls,
      );
      expect(sql, isNot(contains('p_')));
      expect(sql, contains('f_name TEXT NOT NULL'));
      expect(sql, contains('f_active INTEGER NOT NULL'));
    });
  });

  group('index DDL', () {
    test('physical names are deterministic fingerprints of the definition', () {
      final entry = txnEntry;
      final index = entry.indexes.singleWhere(
        (i) => i.canonical.contains('accountId'),
      );
      expect(index.name, matches(RegExp(r'^cx_txn_[0-9a-f]{16}$')));
      expect(index.name, indexName(entry.table, index.canonical));
      // A different definition gets a different name.
      final other = indexName(entry.table, '${index.canonical}x');
      expect(other, isNot(index.name));
    });

    test('declared index appends id with the last part direction', () {
      final entry = txnEntry;
      final index = entry.indexes.singleWhere(
        (i) => i.canonical.contains('accountId'),
      );
      expect(
        createIndexSql(entry.table, index),
        'CREATE INDEX IF NOT EXISTS ${index.name} ON txn '
        '(p_account_id ASC, f_booked_on DESC, id DESC)',
      );
    });

    test('unique indexes are created UNIQUE', () {
      final entry = SchemaRegistry.build([
        _UniqueAccountAdapter(),
      ]).byPattern(_UniqueAccountAdapter().pattern)!;
      final index = entry.indexes.single;
      expect(index.unique, isTrue);
      expect(
        createIndexSql(entry.table, index),
        'CREATE UNIQUE INDEX IF NOT EXISTS ${index.name} ON unique_account '
        '(f_name ASC)',
      );
    });

    test('scope index is unique over params and id', () {
      final entry = txnEntry;
      expect(
        createScopeIndexSql(entry.table, entry.paramSqlNames),
        'CREATE UNIQUE INDEX IF NOT EXISTS cx_txn_scope ON txn '
        '(p_account_id ASC, id ASC)',
      );
      final accountsEntry = accountEntry;
      expect(
        createScopeIndexSql(accountsEntry.table, accountsEntry.paramSqlNames),
        'CREATE UNIQUE INDEX IF NOT EXISTS cx_account_scope ON account '
        '(id ASC)',
      );
    });

    test('alter add column omits NOT NULL (SQLite backfill limitation)', () {
      final entry = txnEntry;
      final memo = entry.columnDdls.singleWhere((c) => c.name == 'f_memo');
      expect(
        alterAddColumnSql(entry.table, memo),
        "ALTER TABLE txn ADD COLUMN f_memo TEXT CHECK (f_memo IS NULL OR "
        "typeof(f_memo) = 'text')",
      );
      expect(
        createMetaTableSql(),
        'CREATE TABLE IF NOT EXISTS _cocoon_meta '
        '(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
    });
  });

  group('shape hash', () {
    test('is stable across builds and sensitive to shape changes', () {
      final entry = txnEntry;
      final rebuilt = SchemaRegistry.build([
        accounts,
        txns,
      ]).byPattern(txns.pattern)!;
      expect(rebuilt.shapeHash, entry.shapeHash);

      final withoutMemo = txnNoMemoEntry;
      expect(withoutMemo.shapeHash, isNot(entry.shapeHash));
    });
  });

  group('registry validation', () {
    test('rejects duplicate models and duplicate patterns', () {
      expect(
        () => SchemaRegistry.build([accounts, AccountAdapter()]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('registered twice'),
          ),
        ),
      );
      expect(
        () => SchemaRegistry.build([txns, _TxnAliasAdapter()]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('same collection path'),
          ),
        ),
      );
    });

    test('rejects unknown index fields', () {
      expect(
        () => SchemaRegistry.build([_BadIndexAdapter()]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('unknown field or param'),
          ),
        ),
      );
    });

    test('rejects fields that shadow path params', () {
      expect(
        () => SchemaRegistry.build([_ShadowParamAdapter()]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('shadows the path param'),
          ),
        ),
      );
    });

    test('rejects two fields mapping to the same column', () {
      expect(
        () => SchemaRegistry.build([_ColumnClashAdapter()]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('same column "f_booked_on"'),
          ),
        ),
      );
    });

    test('subcollections require their parent adapter', () {
      expect(
        () => SchemaRegistry.build([txns]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('parent collection accounts has no registered adapter'),
          ),
        ),
      );
      expect(
        () => SchemaRegistry.build([accounts, txns, splits]),
        returnsNormally,
      );
    });

    test('rejects an adapter whose parent chain skips a level', () {
      // splits under a doc of `txns` is fine; under `accounts` it is not.
      expect(
        () => SchemaRegistry.build([accounts, splits]),
        throwsArgumentError,
      );
    });
  });
}

final class _UniqueAccountAdapter extends CollectionAdapter<Account> {
  @override
  String get model => 'UniqueAccount';

  @override
  final pattern = CollectionPattern.parse('unique_accounts');

  @override
  List<FieldColumn<Account, Object?>> get columns => [accountName];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name'], unique: true),
  ];

  @override
  Uint8List encode(Account value) => throw UnimplementedError();

  @override
  Account decode(Uint8List bytes) => throw UnimplementedError();
}

final class _TxnAliasAdapter extends CollectionAdapter<Txn> {
  @override
  String get model => 'TxnV2';

  @override
  final pattern = txns.pattern;

  @override
  List<FieldColumn<Txn, Object?>> get columns => txns.columns;

  @override
  List<IndexDef> get indexes => txns.indexes;

  @override
  Uint8List encode(Txn value) => txns.encode(value);

  @override
  Txn decode(Uint8List bytes) => txns.decode(bytes);
}

final class _BadIndexAdapter extends CollectionAdapter<Account> {
  @override
  String get model => 'BadIndex';

  @override
  final pattern = CollectionPattern.parse('bad_index');

  @override
  List<FieldColumn<Account, Object?>> get columns => [accountName];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['nope']),
  ];

  @override
  Uint8List encode(Account value) => throw UnimplementedError();

  @override
  Account decode(Uint8List bytes) => throw UnimplementedError();
}

final class _ShadowParamAdapter extends CollectionAdapter<Txn> {
  @override
  String get model => 'ShadowParam';

  @override
  final pattern = CollectionPattern.parse('shadows/{accountId}/items');

  @override
  List<FieldColumn<Txn, Object?>> get columns => [
    FieldColumn.text<Txn, String>('accountId', read: (t) => t.currency),
  ];

  @override
  List<IndexDef> get indexes => const [];

  @override
  Uint8List encode(Txn value) => throw UnimplementedError();

  @override
  Txn decode(Uint8List bytes) => throw UnimplementedError();
}

final class _ColumnClashAdapter extends CollectionAdapter<Txn> {
  @override
  String get model => 'ColumnClash';

  @override
  final pattern = CollectionPattern.parse('column_clash');

  @override
  List<FieldColumn<Txn, Object?>> get columns => [
    txnBookedOn,
    FieldColumn.integer<Txn, int>('booked_on', read: (t) => t.bookedOn),
  ];

  @override
  List<IndexDef> get indexes => const [];

  @override
  Uint8List encode(Txn value) => throw UnimplementedError();

  @override
  Txn decode(Uint8List bytes) => throw UnimplementedError();
}
