import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/sqlite_executor.dart';
import 'package:cocoon/src/inspector/service.dart';
import 'package:test/test.dart';

import 'support/models.dart';

/// A collection whose adapter overrides [CollectionAdapter.toInspectorJson]
/// and that has a blob column (which must refuse to be sorted).
class BlobDoc {
  const BlobDoc({required this.title, required this.payload});

  final String title;
  final Uint8List payload;
}

final blobDocTitle = FieldColumn.text<BlobDoc, String>(
  'title',
  read: (d) => d.title,
);
final blobDocPayload = FieldColumn.blob<BlobDoc, Uint8List>(
  'payload',
  read: (d) => d.payload,
);

final class BlobDocAdapter extends CollectionAdapter<BlobDoc> {
  BlobDocAdapter();

  @override
  String get model => 'BlobDoc';

  @override
  final pattern = CollectionPattern.parse('blobs');

  @override
  List<FieldColumn<BlobDoc, Object?>> get columns => [
    blobDocTitle,
    blobDocPayload,
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['title']),
  ];

  @override
  Uint8List encode(BlobDoc value) {
    final writer = WireWriter();
    writer.writeString(1, value.title);
    writer.writeBytes(2, value.payload);
    return writer.toBytes();
  }

  @override
  BlobDoc decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var title = '';
    var payload = Uint8List(0);
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          title = reader.readString();
        case 2:
          payload = reader.readBytes();
        default:
          reader.skip(tag.type);
      }
    }
    return BlobDoc(title: title, payload: payload);
  }

  @override
  Map<String, Object?> toInspectorJson(BlobDoc value) => {
    'title': value.title,
    'payload': '<${value.payload.length} bytes>',
  };
}

void main() {
  late Directory dir;

  String dbPath([String name = 'inspector.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  final openDbs = <Cocoon>[];

  Future<Cocoon> openDatabase({
    String name = 'inspector.db',
    List<CollectionAdapter<Object?>>? collections,
    SchemaLock? schemaLock,
    int? schemaVersion,
  }) async {
    final opened = await Cocoon.open(
      dbPath(name),
      collections: collections ?? [accounts, txns, splits],
      schemaLock: schemaLock,
      schemaVersion: schemaVersion,
    );
    openDbs.add(opened);
    return opened;
  }

  /// The registry is process-global (DevTools sees every database of the
  /// running app), so tests resolve their own database by its file path.
  Future<String> databaseIdOf(Cocoon db) async {
    final result = await CocoonInspectorService.dispatch('listDatabases', {});
    final databases = result['databases']! as List<Object?>;
    return databases
            .map((e) => e! as Map<String, Object?>)
            .firstWhere(
              (e) => e['path'] == db.databasePath,
              orElse: () => throw StateError(
                'Database ${db.databasePath} is not tracked',
              ),
            )['id']!
        as String;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_inspector_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  test('the inspector is enabled in non-product builds', () {
    expect(cocoonInspectorEnabled, isTrue);
  });

  test('listDatabases reports open databases and closed tombstones', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    expect(id, isNotEmpty);
    final openResult = await CocoonInspectorService.dispatch(
      'listDatabases',
      {},
    );
    final mine = (openResult['databases']! as List<Object?>)
        .map((e) => e! as Map<String, Object?>)
        .firstWhere((e) => e['id'] == id);
    expect(
      mine.keys,
      unorderedEquals(['id', 'path', 'open', 'collectionCount']),
    );
    expect(mine['path'], dbPath());
    expect(mine['open'], isTrue);
    expect(mine['collectionCount'], 3);

    await db.close();
    final closedResult = await CocoonInspectorService.dispatch(
      'listDatabases',
      {},
    );
    final closedMine = (closedResult['databases']! as List<Object?>)
        .map((e) => e! as Map<String, Object?>)
        .firstWhere((e) => e['id'] == id);
    expect(closedMine['open'], isFalse);
    // The tombstone keeps the shape it had when it closed.
    expect(closedMine['collectionCount'], 3);
  });

  test('a database opened over a custom executor has a null path', () async {
    final executor = SqliteExecutor(SqliteDatabase(path: dbPath('no_path.db')));
    final opened = await Cocoon.openWith(executor, collections: [accounts]);
    openDbs.add(opened);
    final result = await CocoonInspectorService.dispatch('listDatabases', {});
    final nullPathEntries = (result['databases']! as List<Object?>)
        .map((e) => e! as Map<String, Object?>)
        .where((e) => e['path'] == null && e['open'] == true)
        .toList();
    expect(nullPathEntries, isNotEmpty);
    expect(nullPathEntries.last['collectionCount'], 1);
  });

  test(
    'listCollections returns model, pattern, table, counts and indexes',
    () async {
      final db = await openDatabase();
      final id = await databaseIdOf(db);
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      final result = await CocoonInspectorService.dispatch('listCollections', {
        'databaseId': id,
      });
      expect(
        result.keys,
        unorderedEquals(['database', 'schemaVersion', 'collections']),
      );
      expect(result['schemaVersion'], isNull);
      expect((result['database']! as Map<String, Object?>)['id'], id);

      final collections = result['collections']! as List<Object?>;
      expect(collections, hasLength(3));
      final txn = collections
          .map((c) => c! as Map<String, Object?>)
          .firstWhere((c) => c['model'] == 'Txn');
      expect(
        txn.keys,
        unorderedEquals([
          'model',
          'pattern',
          'table',
          'documentCount',
          'columns',
          'indexes',
        ]),
      );
      expect(txn['pattern'], 'accounts/{accountId}/txns');
      expect(txn['table'], 'txn');
      expect(txn['documentCount'], 0);

      final columns = txn['columns']! as List<Object?>;
      final bookedOn = columns
          .map((c) => c! as Map<String, Object?>)
          .firstWhere((c) => c['name'] == 'bookedOn');
      expect(bookedOn, {
        'name': 'bookedOn',
        'type': 'integer',
        'nullable': false,
        'mirrored': false,
      });
      final memo = columns
          .map((c) => c! as Map<String, Object?>)
          .firstWhere((c) => c['name'] == 'memo');
      expect(memo['nullable'], isTrue);

      final indexes = txn['indexes']! as List<Object?>;
      // The implicit scope index first, then every declared index.
      expect(indexes.first! as Map<String, Object?>, {
        'name': 'cx_txn_scope',
        'unique': isTrue,
        'parts': [
          {'name': 'accountId', 'descending': isFalse},
          {'name': 'id', 'descending': isFalse},
        ],
      });
      final names = [
        for (final index in indexes) (index! as Map<String, Object?>)['name'],
      ];
      expect(names, contains('cx_txn_scope'));
      expect(names.where((name) => name != 'cx_txn_scope'), hasLength(5));
    },
  );

  test('listCollections reports the stored schema version', () async {
    final db = await openDatabase(schemaVersion: 4);
    final id = await databaseIdOf(db);
    final result = await CocoonInspectorService.dispatch('listCollections', {
      'databaseId': id,
    });
    expect(result['schemaVersion'], 4);
  });

  test('listDocs pages a collection by document path', () async {
    final db = await openDatabase(collections: [accounts]);
    final id = await databaseIdOf(db);
    final collection = db.collection(accounts);
    for (var i = 1; i <= 3; i++) {
      await collection
          .doc('a$i')
          .set(Account(name: 'Account $i', active: true, note: 'note $i'));
    }
    final result = await CocoonInspectorService.dispatch('listDocs', {
      'databaseId': id,
      'path': 'accounts',
      'limit': '2',
    });
    expect(
      result.keys,
      unorderedEquals(['database', 'collection', 'docs', 'nextStartAfter']),
    );
    final collectionJson = result['collection']! as Map<String, Object?>;
    expect(collectionJson, {
      'pattern': 'accounts',
      'concretePath': 'accounts',
      'model': 'Account',
    });
    final docs = result['docs']! as List<Object?>;
    expect(docs, hasLength(2));
    final first = docs.first! as Map<String, Object?>;
    expect(first.keys, unorderedEquals(['path', 'id', 'json']));
    expect(first['path'], 'accounts/a1');
    // The test adapters do not implement toInspectorJson, so the indexed
    // columns are the fallback JSON.
    expect(
      (first['json']! as Map<String, Object?>).keys,
      unorderedEquals(['name', 'active', 'note']),
    );
    expect(first['json'], {
      'name': 'Account 1',
      'active': true,
      'note': 'note 1',
    });
    expect(result['nextStartAfter'], 'accounts/a2');

    final secondPage = await CocoonInspectorService.dispatch('listDocs', {
      'databaseId': id,
      'path': 'accounts',
      'limit': '2',
      'startAfter': result['nextStartAfter']! as String,
    });
    final secondDocs = secondPage['docs']! as List<Object?>;
    expect(
      [for (final doc in secondDocs) (doc! as Map<String, Object?>)['id']],
      ['a3'],
    );
    expect(secondPage['nextStartAfter'], isNull);
  });

  test('listDocs on a subcollection path scopes to the parent', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    await db
        .collection(accounts)
        .doc('a1')
        .collection(txns)
        .add(
          Txn(
            bookedOn: 20260101,
            amountMinor: 100,
            rate: 1,
            currency: 'MYR',
            status: TxnStatus.posted,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );
    await db
        .collection(accounts)
        .doc('a2')
        .collection(txns)
        .add(
          Txn(
            bookedOn: 20260102,
            amountMinor: 200,
            rate: 1,
            currency: 'SGD',
            status: TxnStatus.pending,
            createdAt: DateTime.utc(2026, 1, 2),
          ),
        );
    final result = await CocoonInspectorService.dispatch('listDocs', {
      'databaseId': id,
      'path': 'accounts/a1/txns',
    });
    final docs = result['docs']! as List<Object?>;
    expect(docs, hasLength(1));
    final doc = docs.single! as Map<String, Object?>;
    expect(doc['path'], startsWith('accounts/a1/txns/'));
    expect((doc['json']! as Map<String, Object?>)['currency'], 'MYR');
  });

  test('listDocs keeps prefix siblings separate', () async {
    final db = await openDatabase(collections: [accounts]);
    final id = await databaseIdOf(db);
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'one', active: true));
    await db
        .collection(accounts)
        .doc('a10')
        .set(const Account(name: 'ten', active: true));
    final result = await CocoonInspectorService.dispatch('listDocs', {
      'databaseId': id,
      'path': 'accounts',
    });
    expect((result['docs']! as List<Object?>), hasLength(2));
  });

  test('getDoc decodes one document and reports missing ones', () async {
    final db = await openDatabase(collections: [accounts]);
    final id = await databaseIdOf(db);
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true, note: 'hello'));
    final found = await CocoonInspectorService.dispatch('getDoc', {
      'databaseId': id,
      'path': 'accounts/a1',
    });
    expect(found.keys, unorderedEquals(['database', 'doc']));
    final doc = found['doc']! as Map<String, Object?>;
    expect(doc['path'], 'accounts/a1');
    expect(doc['id'], 'a1');
    expect(doc['exists'], isTrue);
    expect(doc['json'], {'name': 'Acme', 'active': true, 'note': 'hello'});

    final missing = await CocoonInspectorService.dispatch('getDoc', {
      'databaseId': id,
      'path': 'accounts/nope',
    });
    final missingDoc = missing['doc']! as Map<String, Object?>;
    expect(missingDoc['exists'], isFalse);
    expect(missingDoc['json'], isNull);
  });

  test('the adapter override wins over the column fallback', () async {
    final adapter = BlobDocAdapter();
    final db = await openDatabase(collections: [adapter]);
    final id = await databaseIdOf(db);
    await db
        .collection(adapter)
        .doc('b1')
        .set(BlobDoc(title: 'receipt', payload: Uint8List.fromList([9, 8, 7])));
    final result = await CocoonInspectorService.dispatch('getDoc', {
      'databaseId': id,
      'path': 'blobs/b1',
    });
    final doc = result['doc']! as Map<String, Object?>;
    expect(doc['json'], {'title': 'receipt', 'payload': '<3 bytes>'});
  });

  test('runQuery returns rows, the plan and the used index', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    final a1 = db.collection(accounts).doc('a1');
    await a1
        .collection(txns)
        .add(
          Txn(
            bookedOn: 20260101,
            amountMinor: 100,
            rate: 1.5,
            currency: 'MYR',
            status: TxnStatus.posted,
            createdAt: DateTime.utc(2026, 1, 1),
            memo: 'first',
          ),
        );
    await a1
        .collection(txns)
        .add(
          Txn(
            bookedOn: 20260102,
            amountMinor: 200,
            rate: 2.5,
            currency: 'MYR',
            status: TxnStatus.pending,
            createdAt: DateTime.utc(2026, 1, 2),
          ),
        );
    // The scope filter (accountId) plus the -bookedOn order are served by
    // the declared (accountId, -bookedOn) index.
    final result = await CocoonInspectorService.dispatch('runQuery', {
      'databaseId': id,
      'path': 'accounts/a1/txns',
      'orders': jsonEncode([
        {'field': 'bookedOn', 'descending': true},
      ]),
      'limit': '1',
    });

    expect(
      result.keys,
      unorderedEquals(['database', 'query', 'rows', 'rowCount', 'plan']),
    );
    final query = result['query']! as Map<String, Object?>;
    expect(query['pattern'], 'accounts/{accountId}/txns');
    expect(query['scope'], 'accounts/a1/txns');
    expect(query['group'], isFalse);
    expect(query['filters'], isEmpty);
    expect(query['orders'], [
      {'field': 'bookedOn', 'descending': true},
    ]);
    expect(query['limit'], 1);
    expect(query['fullScan'], isFalse);

    expect(result['rowCount'], 1);
    final rows = result['rows']! as List<Object?>;
    final row = rows.single! as Map<String, Object?>;
    expect(row.keys, unorderedEquals(['path', 'id', 'json']));
    expect((row['json']! as Map<String, Object?>)['bookedOn'], 20260102);

    final plan = result['plan']! as Map<String, Object?>;
    expect(
      plan.keys,
      unorderedEquals(['sql', 'explain', 'usedIndex', 'indexName']),
    );
    expect(plan['usedIndex'], isTrue);
    expect(plan['indexName'], startsWith('cx_txn_'));
    expect(plan['explain'], contains('USING INDEX'));
    expect(plan['sql'], contains('ORDER BY'));
  });

  test(
    'runQuery reports the suggested index when none serves the query',
    () async {
      final db = await openDatabase();
      final id = await databaseIdOf(db);
      final result = await CocoonInspectorService.dispatch('runQuery', {
        'databaseId': id,
        'path': 'accounts/a1/txns',
        'filters': jsonEncode([
          {'field': 'rate', 'op': 'greater', 'value': 2},
        ]),
      });
      expect(result['error'], isNotNull);
      // The suggestion includes the parent param the scoped query filters by.
      expect(result['suggestedIndex'], "Index(['accountId', 'rate'])");
    },
  );

  test(
    'runQuery with fullScan runs and the plan reports a full scan',
    () async {
      final db = await openDatabase();
      final id = await databaseIdOf(db);
      final result = await CocoonInspectorService.dispatch('runQuery', {
        'databaseId': id,
        'pattern': 'accounts/{accountId}/txns',
        'group': 'true',
        'filters': jsonEncode([
          {'field': 'rate', 'op': 'greater', 'value': 2},
        ]),
        'fullScan': 'true',
      });
      expect(result['error'], isNull);
      final plan = result['plan']! as Map<String, Object?>;
      // The planner chose no serving index for the filter. The raw EXPLAIN
      // may still ride the scope index to avoid sorting the identity
      // tiebreak (p_account_id, id) — it stays a whole-table SCAN either
      // way, never an index seek on the filter.
      expect(plan['explain'], contains('SCAN txn'));
    },
  );

  test('runQuery runs collection-group queries under the index rule', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    for (final docId in ['a1', 'a2']) {
      await db
          .collection(accounts)
          .doc(docId)
          .collection(txns)
          .add(
            Txn(
              bookedOn: 20260101,
              amountMinor: 100,
              rate: 1,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          );
    }
    final result = await CocoonInspectorService.dispatch('runQuery', {
      'databaseId': id,
      'pattern': 'accounts/{accountId}/txns',
      'group': 'true',
      'filters': jsonEncode([
        {'field': 'status', 'op': 'equal', 'value': 'posted'},
      ]),
      'orders': jsonEncode([
        {'field': 'bookedOn', 'descending': true},
      ]),
    });
    expect(result['rowCount'], 2);
    final query = result['query']! as Map<String, Object?>;
    expect(query['group'], isTrue);
    expect(query['scope'], isNull);
    expect(query['filters'], [
      {
        'field': 'status',
        'op': 'equal',
        'values': ['posted'],
      },
    ]);
    final plan = result['plan']! as Map<String, Object?>;
    expect(plan['usedIndex'], isTrue);
  });

  test('runQuery validates fields like the query builder does', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    final unknownField = await CocoonInspectorService.dispatch('runQuery', {
      'databaseId': id,
      'path': 'accounts/a1/txns',
      'filters': jsonEncode([
        {'field': 'nope', 'op': 'equal', 'value': 'x'},
      ]),
    });
    expect(
      unknownField['error'],
      contains('Unknown field or path param for collection Txn'),
    );

    final nullableSort = await CocoonInspectorService.dispatch('runQuery', {
      'databaseId': id,
      'path': 'accounts/a1/txns',
      'orders': jsonEncode([
        {'field': 'memo', 'descending': false},
        {'field': 'bookedOn', 'descending': false},
      ]),
    });
    expect(
      nullableSort['error'],
      contains('Ordering by a nullable column is not supported'),
    );
  });

  test('runQuery refuses to sort blob columns', () async {
    final adapter = BlobDocAdapter();
    final db = await openDatabase(collections: [adapter]);
    final id = await databaseIdOf(db);
    final result = await CocoonInspectorService.dispatch('runQuery', {
      'databaseId': id,
      'path': 'blobs',
      'orders': jsonEncode([
        {'field': 'payload', 'descending': false},
      ]),
    });
    expect(result['error'], contains('Blob columns cannot be sorted'));
  });

  test(
    'runQuery rejects non-scalar filter values through the wrapper',
    () async {
      final db = await openDatabase();
      final id = await databaseIdOf(db);
      final result = await CocoonInspectorService.dispatch('runQuery', {
        'databaseId': id,
        'path': 'accounts/a1/txns',
        'filters': jsonEncode([
          {
            'field': 'currency',
            'op': 'equal',
            'value': ['MYR'],
          },
        ]),
      });
      expect(
        result['error'],
        contains('must be a number, string, bool or null'),
      );
    },
  );

  test('schema returns live table info, version and the lock', () async {
    final lock = SchemaLock(
      version: 2,
      collections: {
        'Account': CollectionSpec(
          model: 'Account',
          path: 'accounts',
          fields: [
            FieldSpec(name: 'name', number: 1, type: 'String'),
            FieldSpec(name: 'active', number: 2, type: 'bool'),
          ],
          reserved: {7},
          indexes: [
            ['name'],
          ],
        ),
      },
    );
    final db = await openDatabase(
      collections: [accounts],
      schemaVersion: 2,
      schemaLock: lock,
    );
    final id = await databaseIdOf(db);
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true));

    final result = await CocoonInspectorService.dispatch('schema', {
      'databaseId': id,
    });
    expect(
      result.keys,
      unorderedEquals(['database', 'schemaVersion', 'lock', 'tables']),
    );
    expect(result['schemaVersion'], 2);
    expect(result['lock'], lock.toJson());

    final tables = result['tables']! as List<Object?>;
    final account = tables
        .map((t) => t! as Map<String, Object?>)
        .firstWhere((t) => t['table'] == 'account');
    expect(
      account.keys,
      unorderedEquals([
        'table',
        'model',
        'pattern',
        'exists',
        'rowCount',
        'sql',
        'columns',
        'indexes',
        'shapeHash',
      ]),
    );
    expect(account['exists'], isTrue);
    expect(account['rowCount'], 1);
    expect(account['sql'], contains('CREATE TABLE account'));
    expect(account['sql'], isNot(contains('path')));
    expect(account['model'], 'Account');
    expect(account['pattern'], 'accounts');

    final columns = account['columns']! as List<Object?>;
    final idColumn = columns
        .map((c) => c! as Map<String, Object?>)
        .firstWhere((c) => c['name'] == 'id');
    expect(idColumn['type'], 'TEXT');
    expect(idColumn['notNull'], isTrue);
    expect(idColumn['isPrimaryKey'], isFalse);
    final names = [
      for (final column in columns) (column! as Map<String, Object?>)['name'],
    ];
    // The format-2 layout: identity is the scope key, no stored path column.
    expect(names, containsAll(['id', 'data', 'f_name']));
    expect(names, isNot(contains('path')));

    final indexes = account['indexes']! as List<Object?>;
    final indexNames = [
      for (final index in indexes) (index! as Map<String, Object?>)['name'],
    ];
    expect(indexNames, contains('cx_account_scope'));
    final scope = indexes
        .map((i) => i! as Map<String, Object?>)
        .firstWhere((i) => i['name'] == 'cx_account_scope');
    expect(scope['unique'], isTrue);
    expect(scope['sql'], contains('CREATE UNIQUE INDEX'));
  });

  test('schema reports a null lock when the app did not pass one', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    final result = await CocoonInspectorService.dispatch('schema', {
      'databaseId': id,
    });
    expect(result['lock'], isNull);
  });

  test('mirrored columns are reported as mirrored (no index)', () async {
    final db = await openDatabase(
      collections: [accounts, txnsWithCategory, splits],
    );
    final id = await databaseIdOf(db);

    final schema = await CocoonInspectorService.dispatch('schema', {
      'databaseId': id,
    });
    final txn = (schema['tables']! as List<Object?>)
        .map((t) => t! as Map<String, Object?>)
        .firstWhere((t) => t['table'] == 'txn');
    final columns = txn['columns']! as List<Object?>;
    bool mirroredOf(String name) =>
        (columns
                .map((c) => c! as Map<String, Object?>)
                .firstWhere((c) => c['name'] == name)['mirrored']!
            as bool);
    expect(mirroredOf('f_category'), isTrue); // mirrored, no index
    expect(mirroredOf('f_booked_on'), isFalse); // indexed
    expect(mirroredOf('p_account_id'), isFalse); // params never are
    final columnNames = [
      for (final column in columns) (column! as Map<String, Object?>)['name'],
    ];
    expect(columnNames, isNot(contains('path')));

    final listing = await CocoonInspectorService.dispatch('listCollections', {
      'databaseId': id,
    });
    final txnListing = (listing['collections']! as List<Object?>)
        .map((c) => c! as Map<String, Object?>)
        .firstWhere((c) => c['model'] == 'Txn');
    final listedColumns = txnListing['columns']! as List<Object?>;
    final category = listedColumns
        .map((c) => c! as Map<String, Object?>)
        .firstWhere((c) => c['name'] == 'category');
    expect(category['mirrored'], isTrue);
    final bookedOn = listedColumns
        .map((c) => c! as Map<String, Object?>)
        .firstWhere((c) => c['name'] == 'bookedOn');
    expect(bookedOn['mirrored'], isFalse);
  });

  test('every handler answers an error for a closed database', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    await db.close();

    for (final name in [
      'listCollections',
      'listDocs',
      'getDoc',
      'runQuery',
      'schema',
    ]) {
      final result = await CocoonInspectorService.dispatch(name, {
        'databaseId': id,
        'path': 'accounts',
        'pattern': 'accounts',
      });
      expect(result['error'], contains('is closed'), reason: name);
    }
  });

  test('handlers answer an error for an unknown database id', () async {
    await openDatabase();
    final result = await CocoonInspectorService.dispatch('listDocs', {
      'databaseId': '99999',
      'path': 'accounts',
    });
    expect(result['error'], contains('No Cocoon database with id 99999'));
  });

  test('handlers require their parameters', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    final missingId = await CocoonInspectorService.dispatch('listDocs', {
      'path': 'accounts',
    });
    expect(missingId['error'], contains('databaseId'));
    final missingPath = await CocoonInspectorService.dispatch('listDocs', {
      'databaseId': id,
    });
    expect(missingPath['error'], contains('path'));
  });

  test(
    'listDocs rejects document paths and getDoc rejects collection paths',
    () async {
      final db = await openDatabase();
      final id = await databaseIdOf(db);
      final docPathToList = await CocoonInspectorService.dispatch('listDocs', {
        'databaseId': id,
        'path': 'accounts/a1',
      });
      expect(
        docPathToList['error'],
        contains('A collection path has an odd number of segments'),
      );
      final collectionPathToGet = await CocoonInspectorService.dispatch(
        'getDoc',
        {'databaseId': id, 'path': 'accounts'},
      );
      expect(
        collectionPathToGet['error'],
        contains('A document path has an even number of segments'),
      );
    },
  );

  test('listDocs rejects paths no registered collection matches', () async {
    final db = await openDatabase();
    final id = await databaseIdOf(db);
    final result = await CocoonInspectorService.dispatch('listDocs', {
      'databaseId': id,
      'path': 'invoices/inv1/lines',
    });
    expect(result['error'], contains('No registered collection matches'));
  });

  test('unknown extension names are rejected', () async {
    await openDatabase();
    expect(
      () => CocoonInspectorService.dispatch('nope', {}),
      throwsArgumentError,
    );
  });

  test(
    'the change feed subscribes on the first request and survives commits',
    () async {
      final db = await openDatabase(collections: [accounts]);
      // No feed before any DevTools request: apps nobody inspects pay nothing.
      expect(db.debugWatcherCount, 0);
      await CocoonInspectorService.dispatch('listDatabases', {});
      expect(db.debugWatcherCount, 1);

      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));
      expect(db.debugWatcherCount, 1);

      final second = await openDatabase(
        name: 'second.db',
        collections: [accounts],
      );
      final secondId = await databaseIdOf(second);
      await CocoonInspectorService.dispatch('listCollections', {
        'databaseId': secondId,
      });
      expect(second.debugWatcherCount, 1);
      await second.close();
    },
  );

  test('attach is idempotent and a repeated detach is a no-op', () async {
    final db = await openDatabase(collections: [accounts]);
    CocoonInspectorService.attach(db);
    CocoonInspectorService.attach(db);
    final result = await CocoonInspectorService.dispatch('listDatabases', {});
    final mineCount = (result['databases']! as List<Object?>)
        .map((e) => e! as Map<String, Object?>)
        .where((e) => e['path'] == dbPath())
        .length;
    expect(mineCount, 1);

    await db.close();
    CocoonInspectorService.detach(db);
    final after = await CocoonInspectorService.dispatch('listDatabases', {});
    final afterCount = (after['databases']! as List<Object?>)
        .map((e) => e! as Map<String, Object?>)
        .where((e) => e['path'] == dbPath())
        .length;
    expect(afterCount, 1);
  });

  test('the change log stays readable next to the inspector', () async {
    final db = await openDatabase(collections: [accounts]);
    await db
        .collection(accounts)
        .doc('a1')
        .set(const Account(name: 'Acme', active: true));
    final changes = await db.changesSince(0);
    expect(changes, hasLength(1));
    expect(changes.single.collection, 'Account');
  });
}
