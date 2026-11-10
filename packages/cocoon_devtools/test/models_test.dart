import 'package:cocoon_devtools/src/api.dart';
import 'package:cocoon_devtools/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// JSON in exactly the shapes the app side's `ext.cocoon.*` handlers
/// return (`packages/cocoon/lib/src/inspector/service.dart`); when either
/// side drifts, these tests fail.
void main() {
  group('listDatabases', () {
    test('parses open databases and closed tombstones', () {
      final databases = InspectorDatabase.listFrom({
        'databases': [
          {
            'id': '1',
            'path': '/tmp/app/app.db',
            'open': true,
            'collectionCount': 2,
          },
          {'id': '2', 'path': null, 'open': false, 'collectionCount': 1},
        ],
      });
      expect(databases, hasLength(2));
      expect(databases[0].id, '1');
      expect(databases[0].path, '/tmp/app/app.db');
      expect(databases[0].open, isTrue);
      expect(databases[0].collectionCount, 2);
      expect(databases[1].open, isFalse);
      expect(databases[1].label, startsWith('(closed)'));
    });
  });

  group('listCollections', () {
    test('parses collections with columns and index parts', () {
      final listing = CollectionListing.fromJson({
        'database': {
          'id': '1',
          'path': '/tmp/app.db',
          'open': true,
          'collectionCount': 1,
        },
        'schemaVersion': 3,
        'collections': [
          {
            'model': 'Txn',
            'pattern': 'accounts/{accountId}/txns',
            'table': 'accounts_by_account_id_txns',
            'documentCount': 42,
            'columns': [
              {'name': 'bookedOn', 'type': 'integer', 'nullable': false},
              {'name': 'memo', 'type': 'text', 'nullable': true},
              {
                'name': 'amountMinor',
                'type': 'integer',
                'nullable': false,
                'mirrored': true,
              },
            ],
            'indexes': [
              {
                'name': 'cx_txn_ab12cd34',
                'unique': false,
                'parts': [
                  {'name': 'accountId', 'descending': false},
                  {'name': 'bookedOn', 'descending': true},
                ],
              },
            ],
          },
        ],
      });
      expect(listing.schemaVersion, 3);
      final collection = listing.collections.single;
      expect(collection.model, 'Txn');
      expect(collection.params, ['accountId']);
      expect(collection.documentCount, 42);
      expect(collection.columns[0].name, 'bookedOn');
      expect(collection.columns[1].nullable, isTrue);
      // `mirrored` is optional in the payload and defaults to false: an
      // indexed column parses as not mirrored, an `@Mirrored()` column as
      // mirrored.
      expect(collection.columns[0].mirrored, isFalse);
      expect(collection.columns[2].name, 'amountMinor');
      expect(collection.columns[2].mirrored, isTrue);
      final index = collection.indexes.single;
      expect(index.name, 'cx_txn_ab12cd34');
      expect(index.parts, [
        (name: 'accountId', descending: false),
        (name: 'bookedOn', descending: true),
      ]);
    });
  });

  group('listDocs / getDoc', () {
    test('parses a page with its cursor', () {
      final page = DocPage.fromJson({
        'database': {
          'id': '1',
          'path': '/tmp/app.db',
          'open': true,
          'collectionCount': 1,
        },
        'collection': {
          'pattern': 'accounts/{accountId}/txns',
          'concretePath': 'accounts/a1/txns',
          'model': 'Txn',
        },
        'docs': [
          {
            'path': 'accounts/a1/txns/t1',
            'id': 't1',
            'json': {
              'bookedOn': 20261107,
              'status': 'posted',
              'receipt': '<9 bytes>',
              'labels': ['food'],
            },
          },
        ],
        'nextStartAfter': 'accounts/a1/txns/t1',
      });
      expect(page.collection.concretePath, 'accounts/a1/txns');
      expect(page.docs.single.json['bookedOn'], 20261107);
      expect(page.nextStartAfter, 'accounts/a1/txns/t1');

      final lastPage = DocPage.fromJson({
        'database': {
          'id': '1',
          'path': null,
          'open': true,
          'collectionCount': 0,
        },
        'collection': {
          'pattern': 'accounts',
          'concretePath': 'accounts',
          'model': 'Account',
        },
        'docs': const [],
        'nextStartAfter': null,
      });
      expect(lastPage.nextStartAfter, isNull);
    });

    test('parses an existing and a missing document', () {
      final existing = DocDetail.fromJson({
        'path': 'accounts/a1',
        'id': 'a1',
        'exists': true,
        'json': {'name': 'Main'},
      });
      expect(existing.exists, isTrue);
      expect(existing.json, {'name': 'Main'});
      final missing = DocDetail.fromJson({
        'path': 'accounts/zz',
        'id': 'zz',
        'exists': false,
        'json': null,
      });
      expect(missing.exists, isFalse);
      expect(missing.json, isNull);
    });
  });

  group('runQuery', () {
    test('parses rows, plan and echoed query on success', () {
      final outcome = QueryOutcome.fromJson({
        'database': {
          'id': '1',
          'path': '/tmp/app.db',
          'open': true,
          'collectionCount': 1,
        },
        'query': {
          'pattern': 'accounts/{accountId}/txns',
          'scope': 'accounts/a1/txns',
          'group': false,
          'filters': [
            {
              'field': 'status',
              'op': 'equal',
              'values': ['posted'],
            },
          ],
          'orders': [
            {'field': 'bookedOn', 'descending': true},
          ],
          'limit': 50,
          'fullScan': false,
        },
        'rows': [
          {
            'path': 'accounts/a1/txns/t1',
            'id': 't1',
            'json': {'bookedOn': 20261107},
          },
        ],
        'rowCount': 1,
        'plan': {
          'sql': 'SELECT … ORDER BY f_booked_on DESC LIMIT ?',
          'explain': 'SEARCH t USING INDEX cx_txn_ab12cd34 (f_account_id=? …)',
          'usedIndex': true,
          'indexName': 'cx_txn_ab12cd34',
        },
      });
      final succeeded = outcome as QuerySucceeded;
      expect(succeeded.rowCount, 1);
      expect(succeeded.rows.single.id, 't1');
      expect(succeeded.verdict.headline, 'Used index cx_txn_ab12cd34');
      expect(succeeded.sql, contains('ORDER BY'));
    });

    test('parses a refused query with its suggested index', () {
      final outcome = QueryOutcome.fromJson({
        'error': 'No index serves this query…',
        'suggestedIndex': "Index(['status', 'bookedOn'])",
      });
      final refused = outcome as QueryRefused;
      expect(refused.message, contains('No index serves this query'));
      expect(refused.verdict.suggestedIndex, "Index(['status', 'bookedOn'])");
    });
  });

  group('schema', () {
    test('parses version, lock and live tables', () {
      final report = SchemaReport.fromJson({
        'database': {
          'id': '1',
          'path': '/tmp/app.db',
          'open': true,
          'collectionCount': 1,
        },
        'schemaVersion': 2,
        'lock': {
          'format': 'cocoon.lock/1',
          'version': 2,
          'collections': {
            'Txn': {
              'path': 'accounts/{accountId}/txns',
              'fields': {
                'bookedOn': {'number': 1, 'type': 'int'},
                'amountMinor': {'number': 2, 'type': 'int'},
                'dropped': {'number': 4, 'type': 'string'},
              },
              'reserved': [3],
              'indexes': [
                ['accountId', 'bookedOn'],
              ],
            },
          },
        },
        'tables': [
          {
            'table': 'accounts_by_account_id_txns',
            'model': 'Txn',
            'pattern': 'accounts/{accountId}/txns',
            'exists': true,
            'rowCount': 7,
            'sql': 'CREATE TABLE accounts_by_account_id_txns (…)',
            'columns': [
              {
                'name': 'path',
                'type': 'TEXT',
                'notNull': true,
                'isPrimaryKey': true,
              },
              {
                'name': 'f_booked_on',
                'type': 'INTEGER',
                'notNull': true,
                'isPrimaryKey': false,
              },
            ],
            'indexes': [
              {
                'name': 'cx_txn_ab12cd34',
                'sql': 'CREATE INDEX …',
                'unique': false,
              },
            ],
            'shapeHash': 'a1b2c3',
          },
        ],
      });
      expect(report.schemaVersion, 2);
      final lock = report.lock!;
      expect(lock['version'], 2);
      final model =
          (lock['collections']! as Map<String, Object?>)['Txn']!
              as Map<String, Object?>;
      expect(model['reserved'], [3]);
      final table = report.tables.single;
      expect(table.exists, isTrue);
      expect(table.rowCount, 7);
      expect(table.columns.first.isPrimaryKey, isTrue);
      expect(table.indexes.single.name, 'cx_txn_ab12cd34');
    });

    test('a missing lock parses as null', () {
      final report = SchemaReport.fromJson({
        'database': {
          'id': '1',
          'path': null,
          'open': true,
          'collectionCount': 0,
        },
        'schemaVersion': null,
        'lock': null,
        'tables': const [],
      });
      expect(report.lock, isNull);
      expect(report.schemaVersion, isNull);
    });
  });

  group('cocoon:changes events', () {
    test('parses a committed batch', () {
      final batch = ChangeBatch.fromJson({
        'databaseId': '1',
        'changes': [
          {
            'collection': 'Txn',
            'path': 'accounts/a1/txns/t1',
            'op': 'set',
            'at': '2026-11-07T10:30:00.000Z',
          },
          {
            'collection': 'Txn',
            'path': 'accounts/a1/txns/t2',
            'op': 'delete',
            'at': '2026-11-07T10:30:00.000Z',
          },
        ],
      });
      expect(batch.databaseId, '1');
      expect(batch.changes.map((c) => c.op), ['set', 'delete']);
      expect(batch.changes.first.collection, 'Txn');
    });
  });

  group('query value parsing', () {
    test('null, bools and numbers keep their JSON types', () {
      expect(parseQueryValue('null'), isNull);
      expect(parseQueryValue('true'), isTrue);
      expect(parseQueryValue('false'), isFalse);
      expect(parseQueryValue('42'), 42);
      expect(parseQueryValue('-7'), -7);
      expect(parseQueryValue('1.5'), 1.5);
      expect(parseQueryValue(' 20261107 '), 20261107);
    });

    test('anything else stays a string', () {
      expect(parseQueryValue('posted'), 'posted');
      expect(parseQueryValue('MYR'), 'MYR');
      expect(parseQueryValue(''), '');
    });
  });

  group('path grammar', () {
    test('patternParams reads the placeholders in order', () {
      expect(patternParams('accounts/{accountId}/txns'), ['accountId']);
      expect(patternParams('accounts/{accountId}/txns/{txnId}/splits'), [
        'accountId',
        'txnId',
      ]);
      expect(patternParams('accounts'), isEmpty);
    });

    test('topLevelCollectionPaths lists single-segment patterns, sorted', () {
      final paths = topLevelCollectionPaths([
        CollectionInfo(
          model: 'Txn',
          pattern: 'accounts/{accountId}/txns',
          table: 't_txns',
          documentCount: 0,
          columns: const [],
          indexes: const [],
        ),
        CollectionInfo(
          model: 'Account',
          pattern: 'accounts',
          table: 't_accounts',
          documentCount: 2,
          columns: const [],
          indexes: const [],
        ),
      ]);
      expect(paths, ['accounts']);
    });

    test('subcollectionPathOf matches aligned patterns one level deeper', () {
      expect(
        subcollectionPathOf('accounts/{accountId}/txns', 'accounts/a1'),
        'accounts/a1/txns',
      );
      expect(
        subcollectionPathOf(
          'accounts/{accountId}/txns/{txnId}/splits',
          'accounts/a1/txns/t9',
        ),
        'accounts/a1/txns/t9/splits',
      );
    });

    test('subcollectionPathOf rejects misaligned or shallower patterns', () {
      expect(subcollectionPathOf('accounts', 'accounts/a1'), isNull);
      expect(
        subcollectionPathOf(
          'accounts/{accountId}/txns/{txnId}/splits',
          'accounts/a1',
        ),
        isNull,
        reason: 'the document path is more than one level short',
      );
      expect(
        subcollectionPathOf('cards/{cardId}/txns', 'accounts/a1'),
        isNull,
        reason: 'the literal prefix must match',
      );
      expect(
        subcollectionPathOf('accounts/{accountId}/txns', 'accounts/a1/txns/t9'),
        isNull,
        reason: 'a subcollection is exactly one literal deeper',
      );
    });
  });

  group('CocoonInspectorApi', () {
    test('encodes filters and orders the handlers parse', () async {
      final calls = <({String method, Map<String, String> args})>[];
      final api = CocoonInspectorApi(
        call: (method, args) async {
          calls.add((method: method, args: args));
          if (method == 'runQuery') {
            return {
              'database': {
                'id': '1',
                'path': null,
                'open': true,
                'collectionCount': 0,
              },
              'query': {
                'pattern': 'accounts',
                'scope': null,
                'group': false,
                'filters': const [],
                'orders': const [],
                'limit': 50,
                'fullScan': false,
              },
              'rows': const [],
              'rowCount': 0,
              'plan': {
                'sql': 'SELECT 1',
                'explain': 'SCAN',
                'usedIndex': false,
                'indexName': null,
              },
            };
          }
          return {'databases': const []};
        },
        changes: const Stream.empty(),
      );
      final outcome = await api.runQuery(
        databaseId: '1',
        scope: const QueryScope.collection('accounts'),
        filters: const [
          QueryFilterSpec(field: 'status', op: 'equal', value: 'posted'),
          QueryFilterSpec(
            field: 'amountMinor',
            op: 'inList',
            values: [100, 200],
          ),
          QueryFilterSpec(field: 'memo', op: 'isNull'),
        ],
        orders: const [QueryOrderSpec(field: 'bookedOn', descending: true)],
        limit: 25,
        fullScan: true,
      );
      final call = calls.singleWhere((c) => c.method == 'runQuery');
      expect(call.args['path'], 'accounts');
      expect(call.args['limit'], '25');
      expect(call.args['fullScan'], 'true');
      expect(
        call.args['filters'],
        '[{"field":"status","op":"equal","value":"posted"},'
        '{"field":"amountMinor","op":"inList","values":[100,200]},'
        '{"field":"memo","op":"isNull"}]',
      );
      expect(call.args['orders'], '[{"field":"bookedOn","descending":true}]');
      expect(outcome, isA<QuerySucceeded>());
    });

    test('surfaces handler errors as InspectorCallException', () async {
      final api = CocoonInspectorApi(
        call: (method, args) async => {'error': 'Cocoon database 9 is closed'},
        changes: const Stream.empty(),
      );
      await expectLater(
        api.listDatabases(),
        throwsA(
          isA<InspectorCallException>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });
  });
}
