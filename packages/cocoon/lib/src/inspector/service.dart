/// The DevTools inspector: read-only `dart:developer` service extensions
/// over a running [Cocoon] database.
///
/// In debug and profile builds ([cocoonInspectorEnabled]) every `Cocoon`
/// that opens registers the `ext.cocoon.*` service extensions once per
/// process; the DevTools extension (`packages/cocoon_devtools`) calls them.
/// The engine runs in `sqlite_async` isolates, but the `Cocoon` object
/// lives on the app isolate, so every handler reads the engine directly.
///
/// Service extensions cannot be unregistered, so a database that closes
/// stays listed by `listDatabases` marked `"open": false` and every other
/// handler answers with an error saying the database is closed.
///
/// Committed writes are streamed as `cocoon:changes` `postEvent` events
/// (see [inspectorChangesEventKind]) so the extension can show a live
/// change feed. The feed subscribes when the first `ext.cocoon.*` request
/// arrives — DevTools always calls `listDatabases` first — so apps nobody
/// inspects pay nothing.
///
/// The handlers are plain functions over the raw string parameter map a
/// service extension receives, returning plain JSON-shaped maps; the
/// registration wrappers only encode. Errors come back as a result JSON
/// with an `"error"` key (plus `"suggestedIndex"` for a
/// [MissingIndexException]), so the extension can render them. Everything
/// is read-only: no handler writes.
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../engine/adapter.dart';
import '../engine/cocoon.dart';
import '../engine/changes.dart';
import '../engine/naming.dart';
import '../engine/query.dart';
import '../engine/schema_sql.dart';
import '../engine/watch.dart';
import '../path.dart';

/// The prefix of every service extension the inspector registers.
const String inspectorServicePrefix = 'ext.cocoon.';

/// The `dart:developer` event kind committed changes are streamed on
/// (`<extension>:<kind>` — the extension name must match the DevTools
/// extension's `config.yaml`).
const String inspectorChangesEventKind = 'cocoon:changes';

/// Whether the inspector hooks are active in this build: debug and profile
/// only, never product.
const bool cocoonInspectorEnabled = !bool.fromEnvironment('dart.vm.product');

/// How many documents `listDocs` returns per page when `limit` is absent.
const int inspectorDefaultDocLimit = 50;

/// The default page size `runQuery` uses when `limit` is absent.
const int inspectorDefaultQueryLimit = 50;

final class _InspectorDatabase {
  _InspectorDatabase(this.id, Cocoon database)
    : databasePath = database.databasePath,
      collectionCount = database.registry.entries.length {
    db = database;
    _modelsByTable = {
      for (final entry in database.registry.entries)
        entry.table: entry.adapter.model,
    };
  }

  /// The stable id DevTools addresses this database by.
  final int id;

  /// The file the database was opened from, or `null` for [Cocoon.openWith].
  final String? databasePath;

  /// `null` once the database closed; the entry stays as a tombstone
  /// because service extensions cannot be unregistered.
  Cocoon? db;

  late final Map<String, String> _modelsByTable;
  _ChangeFeed? _feed;

  /// Frozen at close so the tombstone still shows the shape it had.
  int collectionCount;

  bool get isOpen => db != null;

  /// The model name of a registered SQL [table], or the table name itself.
  String modelOfTable(String table) => _modelsByTable[table] ?? table;

  /// Subscribes the change feed (once) so commits stream to DevTools.
  void ensureFeedSubscribed() {
    final database = db;
    if (database == null || _feed != null) {
      return;
    }
    _feed = _ChangeFeed(this);
    database.watchHub.add(_feed!);
  }

  void close() {
    collectionCount = db?.registry.entries.length ?? collectionCount;
    db = null;
  }
}

/// Streams committed changes of one database to DevTools as
/// [inspectorChangesEventKind] events.
final class _ChangeFeed implements CommitListener {
  _ChangeFeed(this._entry);

  final _InspectorDatabase _entry;

  @override
  void onCommit(CommitEvent event) {
    final database = _entry.db;
    if (database == null || event.touched.isEmpty) {
      return;
    }
    final at = DateTime.now().toUtc().toIso8601String();
    developer.postEvent(inspectorChangesEventKind, {
      'databaseId': '${_entry.id}',
      'changes': [
        for (final (table, path, op) in event.touched)
          {
            'collection': _entry.modelOfTable(table),
            'path': path,
            'op': op.name,
            'at': at,
          },
      ],
    });
  }

  @override
  void shutdown() {
    // The hub closes with the database; the tombstone handles the rest.
  }
}

/// The inspector's service extensions, the handlers DevTools calls.
///
/// Every handler takes the raw string parameter map (exactly what
/// `dart:developer` service extensions receive) and returns a JSON-shaped
/// map. Unknown parameters, unknown paths and unknown fields throw; the
/// registration wrapper turns any throw into `{"error": ...}`.
final class CocoonInspectorService {
  CocoonInspectorService._();

  static final List<_InspectorDatabase> _databases = [];
  static int _nextDatabaseId = 1;
  static bool _extensionsRegistered = false;

  /// Called by [Cocoon.open] (and [Cocoon.openWith]): tracks [db] for the
  /// inspector and, on the first open of the process, registers the
  /// `ext.cocoon.*` service extensions.
  ///
  /// No-op in product builds.
  static void attach(Cocoon db) {
    if (!cocoonInspectorEnabled) {
      return;
    }
    for (final entry in _databases) {
      if (identical(entry.db, db)) {
        return;
      }
    }
    _registerExtensions();
    _databases.add(_InspectorDatabase(_nextDatabaseId++, db));
  }

  /// Called by [Cocoon.close]: marks the database's entry closed. The entry
  /// stays as a tombstone because service extensions cannot be unregistered.
  ///
  /// No-op for a database that was never attached, and in product builds.
  static void detach(Cocoon db) {
    if (!cocoonInspectorEnabled) {
      return;
    }
    for (final entry in _databases) {
      if (identical(entry.db, db)) {
        entry.close();
        return;
      }
    }
  }

  /// The extension handlers by their name after [inspectorServicePrefix].
  static final Map<
    String,
    Future<Map<String, Object?>> Function(Map<String, String>)
  >
  _handlers = {
    'listDatabases': listDatabases,
    'listCollections': listCollections,
    'listDocs': listDocs,
    'getDoc': getDoc,
    'runQuery': runQuery,
    'schema': schema,
  };

  static void _registerExtensions() {
    if (_extensionsRegistered) {
      return;
    }
    _extensionsRegistered = true;
    for (final MapEntry(key: name, value: handler) in _handlers.entries) {
      developer.registerExtension(
        '$inspectorServicePrefix$name',
        _wrap(handler),
      );
    }
  }

  /// Dispatches to the extension [name] (`listDatabases`, `runQuery`, ...)
  /// through the same wrapper the service protocol uses, returning the
  /// decoded result JSON — a thrown error included, as `{"error": ...}`.
  ///
  /// The inspector's tests use this to exercise the full extension pipeline
  /// (encoding included) without a VM service.
  @visibleForTesting
  static Future<Map<String, Object?>> dispatch(
    String name,
    Map<String, String> params,
  ) async {
    final handler = _handlers[name];
    if (handler == null) {
      throw ArgumentError.value(name, 'name', 'Unknown inspector extension');
    }
    final response = await _wrap(handler)(name, params);
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  static developer.ServiceExtensionHandler _wrap(
    Future<Map<String, Object?>> Function(Map<String, String>) handler,
  ) {
    return (String method, Map<String, String> parameters) async {
      try {
        return developer.ServiceExtensionResponse.result(
          jsonEncode(await handler(parameters)),
        );
      } on Object catch (error) {
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': error.toString()}),
        );
      }
    };
  }

  // -- Handlers -------------------------------------------------------------

  /// Subscribes the change feeds of every open database: any `ext.cocoon.*`
  /// request means a DevTools client is here, and DevTools always calls
  /// `listDatabases` first.
  static void _ensureFeeds() {
    for (final entry in _databases) {
      entry.ensureFeedSubscribed();
    }
  }

  /// Every database the process opened, open or closed, in open order.
  static Future<Map<String, Object?>> listDatabases(
    Map<String, String> params,
  ) async {
    _ensureFeeds();
    return {
      'databases': [for (final entry in _databases) _databaseJson(entry)],
    };
  }

  /// The collections registered on the database: model, path pattern, SQL
  /// table, document count, indexed columns, the indexes that serve queries
  /// (scope index first), and the stored schema version (the lock version
  /// the app last migrated to, `null` when the app opens without one).
  static Future<Map<String, Object?>> listCollections(
    Map<String, String> params,
  ) async {
    _ensureFeeds();
    final tracked = _openEntryOf(params);
    final db = tracked.db!;
    final collections = <Map<String, Object?>>[];
    for (final entry in db.registry.entries) {
      final rows = await db.executor.getAll(
        'SELECT count(*) AS c FROM ${entry.table}',
      );
      collections.add({
        'model': entry.adapter.model,
        'pattern': entry.adapter.pattern.pattern,
        'table': entry.table,
        'documentCount': rows.first['c']! as int,
        'columns': [
          for (final column in entry.fieldColumns)
            {
              'name': column.name,
              'type': column.type.name,
              'nullable': column.nullable,
              // Mirrored (no index): the column exists for aggregates and
              // group-by, but no declared index covers it.
              'mirrored': !_indexedFieldNames(entry).contains(column.name),
            },
        ],
        'indexes': [
          for (final index in entry.indexPlans)
            {
              'name': index.name,
              'unique': index.unique,
              'parts': [
                for (final part in index.parts)
                  {'name': part.name, 'descending': part.descending},
              ],
            },
        ],
      });
    }
    return {
      'database': _databaseJson(tracked),
      'schemaVersion': await _storedSchemaVersion(db),
      'collections': collections,
    };
  }

  /// One keyset page of documents of the concrete collection [params]
  /// `'path'` (e.g. `accounts/a1/txns`; a top-level collection is just
  /// `accounts`), ordered by document path, decoded to JSON via the
  /// collection's adapter.
  ///
  /// `'limit'` caps the page (default [inspectorDefaultDocLimit]);
  /// `'startAfter'` continues after a previous page's `nextStartAfter`
  /// (a document path). `nextStartAfter` is `null` on the last page.
  static Future<Map<String, Object?>> listDocs(
    Map<String, String> params,
  ) async {
    _ensureFeeds();
    final tracked = _openEntryOf(params);
    final db = tracked.db!;
    final resolved = _resolveCollection(db, _requireParam(params, 'path'));
    final limit =
        _positiveIntParam(params, 'limit') ?? inspectorDefaultDocLimit;
    final startAfter = params['startAfter'];
    // The half-open range ['<path>/', '<path>0') covers exactly the
    // documents of this collection ('0' sorts right after '/'), and the
    // binary-collated unique index on `path` serves both the range and the
    // document-path ordering.
    final from = '${resolved.path.path}/';
    final to = '${resolved.path.path}0';
    final rows = await db.executor.getAll(
      'SELECT path, id, data FROM ${resolved.entry.table} '
      'WHERE path >= ? AND path < ? AND path > ? '
      'ORDER BY path ASC LIMIT ?',
      [from, to, startAfter ?? '', limit + 1],
    );
    final hasMore = rows.length > limit;
    final pageRows = hasMore ? rows.sublist(0, limit) : rows;
    return {
      'database': _databaseJson(tracked),
      'collection': {
        'pattern': resolved.entry.adapter.pattern.pattern,
        'concretePath': resolved.path.path,
        'model': resolved.entry.adapter.model,
      },
      'docs': [
        for (final row in pageRows)
          {
            'path': row['path']! as String,
            'id': row['id']! as String,
            'json': _docJson(resolved.entry, row['data']! as Uint8List),
          },
      ],
      'nextStartAfter': hasMore ? pageRows.last['path']! as String : null,
    };
  }

  /// One document at [params] `'path'` (e.g. `accounts/a1`), decoded to
  /// JSON via its adapter; `exists: false` when the document is missing.
  static Future<Map<String, Object?>> getDoc(Map<String, String> params) async {
    _ensureFeeds();
    final tracked = _openEntryOf(params);
    final db = tracked.db!;
    final resolved = _resolveDoc(db, _requireParam(params, 'path'));
    final row = await db.executor.getOptional(
      'SELECT path, id, data FROM ${resolved.entry.table} WHERE path = ?',
      [resolved.path.path],
    );
    return {
      'database': _databaseJson(tracked),
      'doc': {
        'path': resolved.path.path,
        'id': resolved.path.id,
        'exists': row != null,
        'json': row == null
            ? null
            : _docJson(resolved.entry, row['data']! as Uint8List),
      },
    };
  }

  /// Runs a read-only query built from JSON parameters and returns the rows
  /// plus the query plan: the SQL, the `EXPLAIN QUERY PLAN` text, whether
  /// an index was used and its name.
  ///
  /// Parameters:
  /// - `'path'`: a concrete collection path for a scoped query (top-level
  ///   collections are their own pattern), or
  /// - `'pattern'` + `'group': 'true'`: a collection-group query over every
  ///   parent.
  /// - `'filters'`: JSON array of ``{"field": ..., "op": "<FilterOp name>",``
  ///   `"value": ...}` (or `"values": [...]` for `inList`). Values bind as
  ///   the SQL value directly — for a `DateTime` column that is UTC
  ///   microseconds since epoch.
  /// - `'orders'`: JSON array of `{"field": ..., "descending": ...}`.
  /// - `'limit'`: page size (default [inspectorDefaultQueryLimit]).
  /// - `'fullScan'`: `'true'` to opt out of the index rule.
  ///
  /// A query no index serves comes back as `{"error": ..., "suggestedIndex":
  /// "Index([...])"}` instead of rows, so DevTools can show the fix.
  static Future<Map<String, Object?>> runQuery(
    Map<String, String> params,
  ) async {
    _ensureFeeds();
    final tracked = _openEntryOf(params);
    final db = tracked.db!;
    final group = params['group'] == 'true';
    RegistryEntry entry;
    CollectionPath? scopePath;
    if (group) {
      entry = _entryByPattern(db, _requireParam(params, 'pattern'));
    } else {
      final resolved = _resolveCollection(db, _requireParam(params, 'path'));
      entry = resolved.entry;
      scopePath = resolved.path;
    }
    final filters = _parseFilters(entry, params['filters']);
    final orders = _parseOrders(entry, params['orders']);
    final limit =
        _positiveIntParam(params, 'limit') ?? inspectorDefaultQueryLimit;
    final fullScan = params['fullScan'] == 'true';

    try {
      final query = CocoonQuery<Object>(
        db,
        entry.adapter as CollectionAdapter<Object>,
        scopePath,
        filters: filters,
        orders: orders,
        limit: limit,
        fullScan: fullScan,
      );
      final page = await db.runQuery(query);
      final spec = query.spec;
      final plan = planQuery(
        entry: entry,
        scopePath: spec.scopePath,
        filters: spec.filters,
        orders: spec.orders,
        limit: spec.limit,
        cursor: null,
        fullScan: spec.fullScan,
      );
      final explainRows = await db.executor.getAll(
        'EXPLAIN QUERY PLAN ${plan.sql}',
        plan.args,
      );
      final explain = [
        for (final row in explainRows) row['detail']! as String,
      ].join('; ');
      final (:used, :name) = _indexUsedOf(explain);
      return {
        'database': _databaseJson(tracked),
        'query': {
          'pattern': entry.adapter.pattern.pattern,
          'scope': scopePath?.path,
          'group': group,
          'filters': [
            for (final filter in filters)
              {
                'field': filter.name,
                'op': filter.op.name,
                'values': [...filter.sqlValues],
              },
          ],
          'orders': [
            for (final order in orders)
              {'field': order.name, 'descending': order.descending},
          ],
          'limit': limit,
          'fullScan': fullScan,
        },
        'rows': [
          for (final doc in page.docs)
            {
              'path': doc.ref.path.path,
              'id': doc.id,
              'json': _jsonOf(entry, doc.data),
            },
        ],
        'rowCount': page.docs.length,
        'plan': {
          'sql': plan.sql,
          'explain': explain,
          'usedIndex': used,
          'indexName': name,
        },
      };
    } on MissingIndexException catch (error) {
      return {'error': error.message, 'suggestedIndex': error.suggestedIndex};
    }
  }

  /// The database's schema: the stored schema version, the schema lock
  /// JSON (when the app passed one to [Cocoon.open]) and the live shape of
  /// every collection table (row count, `CREATE` SQL, columns from
  /// `PRAGMA table_info`, indexes from `sqlite_master`, shape hash).
  static Future<Map<String, Object?>> schema(Map<String, String> params) async {
    _ensureFeeds();
    final tracked = _openEntryOf(params);
    final db = tracked.db!;
    final tables = <Map<String, Object?>>[];
    for (final entry in db.registry.entries) {
      final table = entry.table;
      final createRow = await db.executor.getOptional(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table],
      );
      if (createRow == null) {
        // Not created yet (a fresh file mid-open); report the declared
        // shape without live rows.
        tables.add({
          'table': table,
          'model': entry.adapter.model,
          'pattern': entry.adapter.pattern.pattern,
          'exists': false,
          'rowCount': 0,
          'sql': null,
          'columns': const [],
          'indexes': const [],
          'shapeHash': entry.shapeHash,
        });
        continue;
      }
      final columnRows = await db.executor.getAll('PRAGMA table_info($table)');
      final indexRows = await db.executor.getAll(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' "
        'AND tbl_name = ?',
        [table],
      );
      final countRows = await db.executor.getAll(
        'SELECT count(*) AS c FROM $table',
      );
      tables.add({
        'table': table,
        'model': entry.adapter.model,
        'pattern': entry.adapter.pattern.pattern,
        'exists': true,
        'rowCount': countRows.first['c']! as int,
        'sql': createRow['sql'] as String?,
        'columns': [
          for (final column in columnRows)
            {
              'name': column['name']! as String,
              'type': column['type']! as String,
              'notNull': (column['notnull']! as int) != 0,
              'isPrimaryKey': (column['pk']! as int) != 0,
              // Mirrored (no index): an f_ column no declared index covers.
              'mirrored': _isMirroredColumn(entry, column['name']! as String),
            },
        ],
        'indexes': [
          for (final index in indexRows)
            {
              'name': index['name']! as String,
              'sql': index['sql'] as String?,
              // Auto-created indexes (sql == null) only exist for UNIQUE
              // constraints, so they are unique by construction.
              'unique':
                  index['sql'] == null ||
                  (index['sql']! as String).toUpperCase().contains('UNIQUE'),
            },
        ],
        'shapeHash': entry.shapeHash,
      });
    }
    return {
      'database': _databaseJson(tracked),
      'schemaVersion': await _storedSchemaVersion(db),
      'lock': db.schemaLock?.toJson(),
      'tables': tables,
    };
  }

  // -- Shared helpers -------------------------------------------------------

  static Map<String, Object?> _databaseJson(_InspectorDatabase entry) => {
    'id': '${entry.id}',
    'path': entry.databasePath,
    'open': entry.isOpen,
    'collectionCount': entry.collectionCount,
  };

  static _InspectorDatabase _openEntryOf(Map<String, String> params) {
    final entry = _entryOf(params);
    if (!entry.isOpen) {
      throw StateError(
        'Cocoon database ${entry.id}'
        '${entry.databasePath == null ? '' : ' (${entry.databasePath})'} is '
        'closed; reopen the database and reload the inspector',
      );
    }
    return entry;
  }

  static _InspectorDatabase _entryOf(Map<String, String> params) {
    final raw = _requireParam(params, 'databaseId');
    final id = int.tryParse(raw);
    for (final entry in _databases) {
      if (entry.id == id) {
        return entry;
      }
    }
    final openIds = [
      for (final entry in _databases)
        if (entry.isOpen) '${entry.id}',
    ];
    final openSuffix = openIds.isEmpty
        ? ''
        : '; open ids: ${openIds.join(', ')}';
    throw ArgumentError(
      'No Cocoon database with id $raw is tracked by the inspector$openSuffix',
    );
  }

  static String _requireParam(Map<String, String> params, String name) {
    final value = params[name];
    if (value == null || value.isEmpty) {
      throw ArgumentError.value(value, name, 'Required');
    }
    return value;
  }

  static int? _positiveIntParam(Map<String, String> params, String name) {
    final raw = params[name];
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final value = int.tryParse(raw);
    if (value == null || value < 1) {
      throw ArgumentError.value(raw, name, 'Must be a positive integer');
    }
    return value;
  }

  static Future<int?> _storedSchemaVersion(Cocoon db) async {
    final row = await db.executor.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      [schemaVersionMetaKey],
    );
    return row == null ? null : int.tryParse(row['value']! as String);
  }

  /// The model-level field names at least one declared index covers.
  static Set<String> _indexedFieldNames(RegistryEntry entry) => {
    for (final index in entry.adapter.indexes)
      for (final part in index.parts) part.name,
  };

  /// Whether [sqlName] is a mirrored-only `f_` column: a field column no
  /// declared index covers (an `@Mirrored()` field, in generated adapters).
  /// Non-`f_` columns (path, id, params, data) are never mirrored.
  static bool _isMirroredColumn(RegistryEntry entry, String sqlName) {
    if (!sqlName.startsWith('f_')) {
      return false;
    }
    final indexed = <String>{
      for (final index in entry.indexes)
        for (final part in index.parts) part.name,
    };
    return !indexed.contains(sqlName);
  }

  /// The document's JSON the way the inspector shows it: the adapter's
  /// [CollectionAdapter.toInspectorJson], or — when the adapter does not
  /// implement it (hand-written adapter) — the indexed columns.
  static Map<String, Object?> _docJson(RegistryEntry entry, Uint8List data) {
    final value = entry.adapter.decode(data);
    return _jsonOf(entry, value);
  }

  static Map<String, Object?> _jsonOf(RegistryEntry entry, Object? value) {
    final json = entry.adapter.toInspectorJson(value);
    if (json.isNotEmpty) {
      return json;
    }
    return {
      for (final column in entry.fieldColumns)
        column.name: jsonValue(_readColumn(column, value)),
    };
  }

  /// Reads [column]'s field off [value].
  ///
  /// The registry's `Object?` column view is covariant, so tearing off
  /// `read` through it (`String Function(Account)` seen as
  /// `Object? Function(Object?)`) fails a runtime parameter check; the
  /// dynamic view performs the same call without one.
  static Object? _readColumn(
    FieldColumn<Object?, Object?> column,
    Object? value,
  ) {
    final dynamic dynamicColumn = column;
    return dynamicColumn.read(value) as Object?;
  }

  static ({RegistryEntry entry, CollectionPath path}) _resolveCollection(
    Cocoon db,
    String path,
  ) {
    final segments = _pathSegments(path);
    if (segments.length.isEven) {
      throw ArgumentError.value(
        path,
        'path',
        'A collection path has an odd number of segments; a document path '
            'is resolved by getDoc',
      );
    }
    for (final entry in db.registry.entries) {
      final values = _matchParams(entry.adapter.pattern, segments);
      if (values != null) {
        return (entry: entry, path: entry.adapter.pattern.resolve(values));
      }
    }
    throw ArgumentError.value(
      path,
      'path',
      'No registered collection matches this path; registered patterns: '
          '${[for (final e in db.registry.entries) e.adapter.pattern].join(', ')}',
    );
  }

  static ({RegistryEntry entry, DocPath path}) _resolveDoc(
    Cocoon db,
    String path,
  ) {
    final segments = _pathSegments(path);
    if (segments.length.isOdd) {
      throw ArgumentError.value(
        path,
        'path',
        'A document path has an even number of segments; a collection path '
            'is resolved by listDocs',
      );
    }
    final collection = _resolveCollection(
      db,
      segments.sublist(0, segments.length - 1).join('/'),
    );
    return (entry: collection.entry, path: collection.path.doc(segments.last));
  }

  static List<String> _pathSegments(String path) {
    final segments = path.split('/');
    if (segments.isEmpty || segments.any((segment) => segment.isEmpty)) {
      throw ArgumentError.value(path, 'path', 'Not a well-formed path');
    }
    return segments;
  }

  /// The params [pattern] takes when its shape matches [segments] (same
  /// length, equal collection ids, non-empty ids at placeholder slots), or
  /// `null` when it does not.
  static Map<String, String>? _matchParams(
    CollectionPattern pattern,
    List<String> segments,
  ) {
    final patternSegments = pattern.pattern.split('/');
    if (patternSegments.length != segments.length) {
      return null;
    }
    final values = <String, String>{};
    for (var i = 0; i < patternSegments.length; i++) {
      final patternSegment = patternSegments[i];
      if (i.isEven) {
        if (patternSegment != segments[i]) {
          return null;
        }
      } else {
        if (segments[i].isEmpty) {
          return null;
        }
        values[patternSegment.substring(1, patternSegment.length - 1)] =
            segments[i];
      }
    }
    return values;
  }

  static RegistryEntry _entryByPattern(Cocoon db, String pattern) {
    final parsed = CollectionPattern.parse(pattern);
    final entry = db.registry.byPattern(parsed);
    if (entry == null) {
      throw ArgumentError.value(
        pattern,
        'pattern',
        'No collection with this pattern is registered on the database',
      );
    }
    return entry;
  }

  static List<QueryFilter> _parseFilters(RegistryEntry entry, String? json) {
    if (json == null || json.isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(json) as List<Object?>;
    return [
      for (final item in decoded)
        () {
          final map = item! as Map<String, Object?>;
          final name = map['field']! as String;
          final sqlName = _sqlNameOf(entry, name);
          final op = FilterOp.values.byName(map['op']! as String);
          final values = switch (op) {
            FilterOp.isNull || FilterOp.isNotNull => const <Object?>[],
            FilterOp.inList => [
              for (final value in map['values']! as List<Object?>)
                _sqlValue(name, value),
            ],
            _ => [_sqlValue(name, map['value'])],
          };
          return QueryFilter(name, sqlName, op, values);
        }(),
    ];
  }

  static List<QueryOrder> _parseOrders(RegistryEntry entry, String? json) {
    if (json == null || json.isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(json) as List<Object?>;
    return [
      for (final item in decoded)
        () {
          final map = item! as Map<String, Object?>;
          final name = map['field']! as String;
          // Sort keys are never null and never blobs: the same rules
          // CocoonQuery.orderBy enforces. Path params are always sortable.
          final column = _fieldColumnOf(entry, name);
          if (column != null && column.type == ColumnType.blob) {
            throw ArgumentError.value(
              name,
              'field',
              'Blob columns cannot be sorted',
            );
          }
          if (column != null && column.nullable) {
            throw ArgumentError.value(
              name,
              'field',
              'Ordering by a nullable column is not supported: sort keys are '
                  'never null',
            );
          }
          _sqlNameOf(entry, name);
          return QueryOrder(
            name,
            descending: (map['descending'] as bool?) ?? false,
          );
        }(),
    ];
  }

  static FieldColumn<Object?, Object?>? _fieldColumnOf(
    RegistryEntry entry,
    String name,
  ) {
    for (final column in entry.fieldColumns) {
      if (column.name == name) {
        return column;
      }
    }
    return null;
  }

  /// The SQL column of a model field or path param, throwing for names the
  /// collection does not know.
  static String _sqlNameOf(RegistryEntry entry, String name) {
    final known = <String>{for (final column in entry.fieldColumns) column.name}
      ..addAll(entry.paramNames);
    if (!known.contains(name)) {
      throw ArgumentError.value(
        name,
        'field',
        'Unknown field or path param for collection '
            '${entry.adapter.model} (${entry.adapter.pattern})',
      );
    }
    return entry.sqlNameOf(name);
  }

  /// The SQL value a decoded JSON filter value binds as. Numbers, strings,
  /// bools and null bind as themselves (a `DateTime` column takes UTC
  /// microseconds since epoch — the value its SQLite column stores).
  static Object? _sqlValue(String field, Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    throw ArgumentError.value(
      value,
      'value',
      'Filter value for "$field" must be a number, string, bool or null',
    );
  }

  static final RegExp _usingIndexPattern = RegExp(
    r'USING (?:COVERING )?INDEX ([^\s(]+)',
  );

  /// Whether an `EXPLAIN QUERY PLAN` text used an index, and its name.
  static ({bool used, String? name}) _indexUsedOf(String explain) {
    final match = _usingIndexPattern.firstMatch(explain);
    if (match != null) {
      return (used: true, name: match.group(1)!);
    }
    if (explain.contains('USING INTEGER PRIMARY KEY')) {
      return (used: true, name: null);
    }
    return (used: false, name: null);
  }
}

/// Converts one model field value into its JSON representation for the
/// inspector: DateTime as a UTC ISO-8601 string, enums by name, binary
/// fields as `<N bytes>`, everything JSON-native as itself.
Object? jsonValue(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is DateTime) {
    return value.toUtc().toIso8601String();
  }
  if (value is Enum) {
    return value.name;
  }
  if (value is Uint8List) {
    return '<${value.length} bytes>';
  }
  if (value is List<Object?>) {
    return [for (final element in value) jsonValue(element)];
  }
  return value.toString();
}
