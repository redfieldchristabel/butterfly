/// Typed views over the JSON the `ext.cocoon.*` service extensions return.
///
/// The DevTools extension talks to the inspected app only over the VM
/// service protocol, so every handler result arrives as plain JSON; these
/// classes parse it once and give the panels something typed to render.
/// Parsing is strict: a shape the app side does not produce throws a
/// [FormatException] naming the piece that was unexpected, so a mismatch
/// between the two packages is visible immediately.
///
/// The pure helpers here ([patternParams], [topLevelCollectionPaths],
/// [subcollectionPathOf], [parseQueryValue]) carry the small amount of
/// Cocoon path/query grammar the UI needs; they mirror the app-side rules
/// and are unit tested.
///
/// The [StorageReport] family documents the JSON a future
/// `ext.cocoon.storage` service extension must return (the shape lives in
/// its dartdoc); the Storage tab renders that shape from built-in preview
/// payloads until the extension ships.
library;

/// The service extension prefix every Cocoon inspector call uses.
///
/// Must match `inspectorServicePrefix` on the app side
/// (`packages/cocoon/lib/src/inspector/service.dart`); the extension
/// cannot import that file, because `cocoon_devtools` is a standalone
/// package that never depends on `cocoon`.
const String inspectorServicePrefix = 'ext.cocoon.';

/// The kind of the `dart:developer` events committed changes stream on.
///
/// Must match `inspectorChangesEventKind` on the app side.
const String inspectorChangesEventKind = 'cocoon:changes';

/// The names of the filter operators the query runner offers, in the order
/// the app side declares them (`FilterOp`).
const List<String> filterOpNames = [
  'equal',
  'notEqual',
  'less',
  'lessEqual',
  'greater',
  'greaterEqual',
  'inList',
  'isNull',
  'isNotNull',
];

/// The filter operators that take no value at all.
const Set<String> valuelessOps = {'isNull', 'isNotNull'};

/// The filter operator that takes a list of values (`inList`).
const String listValueOp = 'inList';

/// One database the inspected app has open (or has closed; the entry stays
/// as a tombstone because service extensions cannot be unregistered).
final class InspectorDatabase {
  const InspectorDatabase({
    required this.id,
    required this.path,
    required this.open,
    required this.collectionCount,
  });

  /// Parses one entry of the `listDatabases` result.
  factory InspectorDatabase.fromJson(Object? json) {
    final map = _mapOf(json, 'database');
    return InspectorDatabase(
      id: _stringOf(map['id'], 'id'),
      path: map['path'] as String?,
      open: map['open'] == true,
      collectionCount: _intOf(map['collectionCount'], 'collectionCount'),
    );
  }

  /// The stable id every other extension call addresses the database by.
  final String id;

  /// The file the database was opened from, or `null` when the app opened
  /// it over a custom executor.
  final String? path;

  /// Whether the database is still open.
  final bool open;

  /// How many collections the database registers.
  final int collectionCount;

  /// A human label for headers and the database picker.
  String get label {
    final where = path == null ? 'custom executor' : path!;
    return closedSuffix(open, 'Database $id — $where');
  }

  /// Parses the whole `listDatabases` result.
  static List<InspectorDatabase> listFrom(Object? json) {
    final map = _mapOf(json, 'listDatabases result');
    return [
      for (final entry in _listOf(map['databases'], 'databases'))
        InspectorDatabase.fromJson(entry),
    ];
  }
}

/// Prepends '(closed) ' to [text] while [open] is false, so tombstones read
/// at a glance.
String closedSuffix(bool open, String text) => open ? text : '(closed) $text';

/// One column of a collection's SQL table: an indexed or mirrored field, or
/// a path param.
final class CollectionColumn {
  const CollectionColumn({
    required this.name,
    required this.type,
    required this.nullable,
    this.mirrored = false,
  });

  /// Parses one entry of `listCollections`'s `columns`.
  factory CollectionColumn.fromJson(Object? json) {
    final map = _mapOf(json, 'column');
    return CollectionColumn(
      name: _stringOf(map['name'], 'name'),
      type: _stringOf(map['type'], 'type'),
      nullable: map['nullable'] == true,
      mirrored: map['mirrored'] == true,
    );
  }

  /// The field or path param name the query runner filters and sorts by.
  final String name;

  /// The SQL storage type (`text`, `integer`, `real`, `blob`).
  final String type;

  /// Whether the field can be absent; nullable columns cannot be sorted.
  final bool nullable;

  /// Whether the column is mirrored without an index (`@Mirrored()`):
  /// aggregates and group-by read it, filters and sorts need an index.
  final bool mirrored;
}

/// One declared index of a collection, as the planner serves queries with.
final class CollectionIndex {
  const CollectionIndex({
    required this.name,
    required this.unique,
    required this.parts,
  });

  /// Parses one entry of `listCollections`'s `indexes`.
  factory CollectionIndex.fromJson(Object? json) {
    final map = _mapOf(json, 'index');
    return CollectionIndex(
      name: _stringOf(map['name'], 'name'),
      unique: map['unique'] == true,
      parts: [
        for (final part in _listOf(map['parts'], 'parts'))
          () {
            final partMap = _mapOf(part, 'index part');
            return (
              name: _stringOf(partMap['name'], 'name'),
              descending: partMap['descending'] == true,
            );
          }(),
      ],
    );
  }

  /// The index name `EXPLAIN QUERY PLAN` reports back.
  final String name;

  /// Whether the index enforces uniqueness.
  final bool unique;

  /// The (name, descending) parts in declaration order.
  final List<({String name, bool descending})> parts;
}

/// One collection registered on the database.
final class CollectionInfo {
  const CollectionInfo({
    required this.model,
    required this.pattern,
    required this.table,
    required this.documentCount,
    required this.columns,
    required this.indexes,
  });

  /// Parses one entry of `listCollections`'s `collections`.
  factory CollectionInfo.fromJson(Object? json) {
    final map = _mapOf(json, 'collection');
    return CollectionInfo(
      model: _stringOf(map['model'], 'model'),
      pattern: _stringOf(map['pattern'], 'pattern'),
      table: _stringOf(map['table'], 'table'),
      documentCount: _intOf(map['documentCount'], 'documentCount'),
      columns: [
        for (final column in _listOf(map['columns'], 'columns'))
          CollectionColumn.fromJson(column),
      ],
      indexes: [
        for (final index in _listOf(map['indexes'], 'indexes'))
          CollectionIndex.fromJson(index),
      ],
    );
  }

  /// The Dart model class name.
  final String model;

  /// The collection path pattern, e.g. `accounts/{accountId}/txns`.
  final String pattern;

  /// The SQL table the collection stores its documents in.
  final String table;

  /// How many documents the collection holds.
  final int documentCount;

  /// The indexed field columns and path params, queryable by name.
  final List<CollectionColumn> columns;

  /// The declared indexes, scope index first.
  final List<CollectionIndex> indexes;

  /// The `{param}` names the pattern takes, in order.
  List<String> get params => patternParams(pattern);
}

/// The `listCollections` result: the collections plus the stored schema
/// version (the lock version the app last migrated to, `null` when the app
/// opened without one).
final class CollectionListing {
  const CollectionListing({
    required this.schemaVersion,
    required this.collections,
  });

  /// Parses the whole `listCollections` result.
  factory CollectionListing.fromJson(Object? json) {
    final map = _mapOf(json, 'listCollections result');
    return CollectionListing(
      schemaVersion: map['schemaVersion'] as int?,
      collections: [
        for (final entry in _listOf(map['collections'], 'collections'))
          CollectionInfo.fromJson(entry),
      ],
    );
  }

  /// The stored schema version, or `null` when the app did not pass a lock.
  final int? schemaVersion;

  /// Every registered collection, in registration order.
  final List<CollectionInfo> collections;
}

/// The concrete collection a document page was read from.
final class CollectionRef {
  const CollectionRef({
    required this.pattern,
    required this.concretePath,
    required this.model,
  });

  /// Parses the `collection` entry of the `listDocs` result.
  factory CollectionRef.fromJson(Object? json) {
    final map = _mapOf(json, 'collection');
    return CollectionRef(
      pattern: _stringOf(map['pattern'], 'pattern'),
      concretePath: _stringOf(map['concretePath'], 'concretePath'),
      model: _stringOf(map['model'], 'model'),
    );
  }

  /// The collection's pattern.
  final String pattern;

  /// The concrete path the page was read under, e.g. `accounts/a1/txns`.
  final String concretePath;

  /// The Dart model class name.
  final String model;
}

/// One document of a page: its path, id and decoded JSON fields.
final class DocSummary {
  const DocSummary({required this.path, required this.id, required this.json});

  /// Parses one entry of `listDocs`'s `docs`.
  factory DocSummary.fromJson(Object? json) {
    final map = _mapOf(json, 'document');
    return DocSummary(
      path: _stringOf(map['path'], 'path'),
      id: _stringOf(map['id'], 'id'),
      json: _mapOf(map['json'], 'json'),
    );
  }

  /// The full document path, e.g. `accounts/a1/txns/t9`.
  final String path;

  /// The document id (the last path segment).
  final String id;

  /// The decoded document, JSON-shaped by the generated adapter.
  final Map<String, Object?> json;
}

/// One keyset page of documents.
final class DocPage {
  const DocPage({
    required this.collection,
    required this.docs,
    required this.nextStartAfter,
  });

  /// Parses the whole `listDocs` result.
  factory DocPage.fromJson(Object? json) {
    final map = _mapOf(json, 'listDocs result');
    return DocPage(
      collection: CollectionRef.fromJson(map['collection']),
      docs: [
        for (final doc in _listOf(map['docs'], 'docs'))
          DocSummary.fromJson(doc),
      ],
      nextStartAfter: map['nextStartAfter'] as String?,
    );
  }

  /// The collection the page belongs to.
  final CollectionRef collection;

  /// The documents, ordered by document path.
  final List<DocSummary> docs;

  /// The `startAfter` value for the next page, `null` on the last page.
  final String? nextStartAfter;
}

/// One document read by `getDoc`, existing or not.
final class DocDetail {
  const DocDetail({
    required this.path,
    required this.id,
    required this.exists,
    required this.json,
  });

  /// Parses the whole `getDoc` result's `doc` entry.
  factory DocDetail.fromJson(Object? json) {
    final map = _mapOf(json, 'document');
    return DocDetail(
      path: _stringOf(map['path'], 'path'),
      id: _stringOf(map['id'], 'id'),
      exists: map['exists'] == true,
      json: map['json'] == null ? null : _mapOf(map['json'], 'json'),
    );
  }

  /// The full document path.
  final String path;

  /// The document id.
  final String id;

  /// Whether the document exists.
  final bool exists;

  /// The decoded document, or `null` for a missing one.
  final Map<String, Object?>? json;
}

/// One filter the query runner sends: a field, an operator name and the
/// value(s) to bind.
final class QueryFilterSpec {
  const QueryFilterSpec({
    required this.field,
    required this.op,
    this.value,
    this.values = const [],
  });

  /// The field or path param name.
  final String field;

  /// One of [filterOpNames].
  final String op;

  /// The single value (ignored by [valuelessOps] and [listValueOp]).
  final Object? value;

  /// The values for [listValueOp].
  final List<Object?> values;

  /// Encodes the filter the way the app side's `_parseFilters` expects.
  Map<String, Object?> toJson() => {
    'field': field,
    'op': op,
    if (op == listValueOp)
      'values': values
    else if (!valuelessOps.contains(op))
      'value': value,
  };
}

/// One order the query runner sends.
final class QueryOrderSpec {
  const QueryOrderSpec({required this.field, required this.descending});

  /// The field or path param name.
  final String field;

  /// Whether the sort runs descending.
  final bool descending;

  /// Encodes the order the way the app side's `_parseOrders` expects.
  Map<String, Object?> toJson() => {'field': field, 'descending': descending};
}

/// How a query's plan reads out, in the order of preference.
enum PlanOutcome {
  /// A declared index served the query.
  usedIndex,

  /// The query walked documents by id, needing no secondary index.
  usedPrimaryKey,

  /// No index served the query: every row was read.
  fullScan,
}

/// The plain-words verdict about how SQLite ran (or refused) a query.
///
/// The step's wording contract: an index use reads `Used index
/// cx_txn_ab12cd34`, a full scan reads `Full scan: add Index([...])`.
final class PlanVerdict {
  const PlanVerdict._(this.outcome, this.indexName, this.suggestedIndex);

  /// The verdict for a plan that used a declared index.
  factory PlanVerdict.index(String indexName) =>
      PlanVerdict._(PlanOutcome.usedIndex, indexName, null);

  /// The verdict for a plan that used the document-id primary key.
  factory PlanVerdict.primaryKey() =>
      const PlanVerdict._(PlanOutcome.usedPrimaryKey, null, null);

  /// The verdict for a plan that read every row.
  factory PlanVerdict.fullScan() =>
      const PlanVerdict._(PlanOutcome.fullScan, null, null);

  /// The verdict for a query the index rule refused outright.
  factory PlanVerdict.missingIndex(String suggestedIndex) =>
      PlanVerdict._(PlanOutcome.fullScan, null, suggestedIndex);

  /// Builds the verdict from the `plan` entry of a `runQuery` result.
  factory PlanVerdict.fromPlan(Map<String, Object?> plan) {
    final usedIndex = plan['usedIndex'] == true;
    final indexName = plan['indexName'] as String?;
    if (!usedIndex) {
      return PlanVerdict.fullScan();
    }
    return indexName == null
        ? PlanVerdict.primaryKey()
        : PlanVerdict.index(indexName);
  }

  /// Which kind of plan ran.
  final PlanOutcome outcome;

  /// The index name for [PlanOutcome.usedIndex].
  final String? indexName;

  /// The `Index([...])` declaration the app side suggested, for a query the
  /// index rule refused.
  final String? suggestedIndex;

  /// The one-line headline the query runner shows.
  String get headline => switch (outcome) {
    PlanOutcome.usedIndex => 'Used index $indexName',
    PlanOutcome.usedPrimaryKey => 'Used the document-id primary key',
    PlanOutcome.fullScan => 'Full scan: add Index([...])',
  };

  /// The follow-up sentence telling the developer what it means.
  String get advice => switch (outcome) {
    PlanOutcome.usedIndex =>
      'A declared index served this query; no extra rows were read.',
    PlanOutcome.usedPrimaryKey =>
      'The query walked documents by id, so no secondary index was needed.',
    PlanOutcome.fullScan =>
      'No index served this query, so every row was read. Declare an '
          'Index on the fields the query filters and sorts by, then run the '
          'migrate command.',
  };
}

/// One result row of a successful query.
final class QueryRow {
  const QueryRow({required this.path, required this.id, required this.json});

  /// Parses one entry of the `runQuery` result's `rows`.
  factory QueryRow.fromJson(Object? json) {
    final map = _mapOf(json, 'query row');
    return QueryRow(
      path: _stringOf(map['path'], 'path'),
      id: _stringOf(map['id'], 'id'),
      json: _mapOf(map['json'], 'json'),
    );
  }

  /// The document path.
  final String path;

  /// The document id.
  final String id;

  /// The decoded document, JSON-shaped by the generated adapter.
  final Map<String, Object?> json;
}

/// A query that ran: rows, the plan and the exact query the app side built.
final class QuerySucceeded extends QueryOutcome {
  const QuerySucceeded({
    required this.rows,
    required this.rowCount,
    required this.verdict,
    required this.sql,
    required this.explain,
    required this.queryEcho,
  });

  /// Parses a `runQuery` result that has no `error` key.
  factory QuerySucceeded.fromJson(Map<String, Object?> map) {
    final plan = _mapOf(map['plan'], 'plan');
    return QuerySucceeded(
      rows: [
        for (final row in _listOf(map['rows'], 'rows')) QueryRow.fromJson(row),
      ],
      rowCount: _intOf(map['rowCount'], 'rowCount'),
      verdict: PlanVerdict.fromPlan(plan),
      sql: _stringOf(plan['sql'], 'sql'),
      explain: _stringOf(plan['explain'], 'explain'),
      queryEcho: _mapOf(map['query'], 'query'),
    );
  }

  /// The result rows, in query order.
  final List<QueryRow> rows;

  /// How many rows came back (the page is capped by the limit).
  final int rowCount;

  /// The plain-words verdict about the plan.
  final PlanVerdict verdict;

  /// The SQL the app side generated.
  final String sql;

  /// The joined `EXPLAIN QUERY PLAN` detail lines.
  final String explain;

  /// The parsed filters, orders and flags the app side used.
  final Map<String, Object?> queryEcho;
}

/// A query the app side refused: the index rule named the missing index.
final class QueryRefused extends QueryOutcome {
  const QueryRefused({required this.message, required this.verdict});

  /// Parses a `runQuery` result that carries an `error` key.
  factory QueryRefused.fromJson(Map<String, Object?> map) {
    final message = map['error']! as String;
    final suggested = map['suggestedIndex'];
    return QueryRefused(
      message: message,
      verdict: suggested == null
          ? PlanVerdict.fullScan()
          : PlanVerdict.missingIndex(suggested as String),
    );
  }

  /// The error message, including which fields the query used.
  final String message;

  /// The verdict carrying the suggested `Index([...])` declaration.
  final PlanVerdict verdict;
}

/// A query outcome: either [QuerySucceeded] or [QueryRefused].
sealed class QueryOutcome {
  const QueryOutcome();

  /// Parses a whole `runQuery` result.
  static QueryOutcome fromJson(Map<String, Object?> map) =>
      map.containsKey('error')
      ? QueryRefused.fromJson(map)
      : QuerySucceeded.fromJson(map);
}

/// One column of a live SQL table, as `PRAGMA table_info` reports it.
final class TableColumn {
  const TableColumn({
    required this.name,
    required this.type,
    required this.notNull,
    required this.isPrimaryKey,
    this.mirrored = false,
  });

  /// Parses one entry of the `schema` result's `columns`.
  factory TableColumn.fromJson(Object? json) {
    final map = _mapOf(json, 'table column');
    return TableColumn(
      name: _stringOf(map['name'], 'name'),
      type: _stringOf(map['type'], 'type'),
      notNull: map['notNull'] == true,
      isPrimaryKey: map['isPrimaryKey'] == true,
      mirrored: map['mirrored'] == true,
    );
  }

  /// The column name.
  final String name;

  /// The declared SQL type.
  final String type;

  /// Whether the column is NOT NULL.
  final bool notNull;

  /// Whether the column is (part of) the primary key.
  final bool isPrimaryKey;

  /// Whether the column is mirrored without an index (`f_` column no
  /// declared index covers — an `@Mirrored()` field).
  final bool mirrored;
}

/// One live SQL index, as `sqlite_master` reports it.
final class TableIndex {
  const TableIndex({
    required this.name,
    required this.unique,
    required this.sql,
  });

  /// Parses one entry of the `schema` result's `indexes`.
  factory TableIndex.fromJson(Object? json) {
    final map = _mapOf(json, 'table index');
    return TableIndex(
      name: _stringOf(map['name'], 'name'),
      unique: map['unique'] == true,
      sql: map['sql'] as String?,
    );
  }

  /// The index name.
  final String name;

  /// Whether the index enforces uniqueness.
  final bool unique;

  /// The CREATE INDEX statement, `null` for auto-created indexes.
  final String? sql;
}

/// One collection table as it exists in the database file right now.
final class TableInfo {
  const TableInfo({
    required this.table,
    required this.model,
    required this.pattern,
    required this.exists,
    required this.rowCount,
    required this.columns,
    required this.indexes,
    required this.shapeHash,
    required this.sql,
  });

  /// Parses one entry of the `schema` result's `tables`.
  factory TableInfo.fromJson(Object? json) {
    final map = _mapOf(json, 'table');
    return TableInfo(
      table: _stringOf(map['table'], 'table'),
      model: _stringOf(map['model'], 'model'),
      pattern: _stringOf(map['pattern'], 'pattern'),
      exists: map['exists'] == true,
      rowCount: _intOf(map['rowCount'], 'rowCount'),
      columns: [
        for (final column in _listOf(map['columns'], 'columns'))
          TableColumn.fromJson(column),
      ],
      indexes: [
        for (final index in _listOf(map['indexes'], 'indexes'))
          TableIndex.fromJson(index),
      ],
      shapeHash: _stringOf(map['shapeHash'], 'shapeHash'),
      sql: map['sql'] as String?,
    );
  }

  /// The table name.
  final String table;

  /// The Dart model class name.
  final String model;

  /// The collection path pattern.
  final String pattern;

  /// Whether the table exists in the file yet.
  final bool exists;

  /// How many rows the table holds.
  final int rowCount;

  /// The live columns.
  final List<TableColumn> columns;

  /// The live indexes.
  final List<TableIndex> indexes;

  /// The shape hash the engine reconciles on open.
  final String shapeHash;

  /// The CREATE TABLE statement, `null` when the table does not exist yet.
  final String? sql;
}

/// The whole `schema` result: stored version, lock JSON and live tables.
final class SchemaReport {
  const SchemaReport({
    required this.schemaVersion,
    required this.lock,
    required this.tables,
  });

  /// Parses the whole `schema` result.
  factory SchemaReport.fromJson(Object? json) {
    final map = _mapOf(json, 'schema result');
    return SchemaReport(
      schemaVersion: map['schemaVersion'] as int?,
      lock: map['lock'] == null ? null : _mapOf(map['lock'], 'lock'),
      tables: [
        for (final table in _listOf(map['tables'], 'tables'))
          TableInfo.fromJson(table),
      ],
    );
  }

  /// The stored schema version, or `null` when the file predates locks.
  final int? schemaVersion;

  /// The parsed `cocoon.lock` the app passed to `Cocoon.open`, or
  /// `null` when it did not.
  final Map<String, Object?>? lock;

  /// The live shape of every collection table.
  final List<TableInfo> tables;
}

/// One committed change of a document, as the live feed shows it.
final class ChangeRecord {
  const ChangeRecord({
    required this.databaseId,
    required this.collection,
    required this.path,
    required this.op,
    required this.at,
  });

  /// Parses one entry of a `cocoon:changes` event's `changes` list.
  factory ChangeRecord.fromJson(String databaseId, Object? json) {
    final map = _mapOf(json, 'change');
    return ChangeRecord(
      databaseId: databaseId,
      collection: _stringOf(map['collection'], 'collection'),
      path: _stringOf(map['path'], 'path'),
      op: _stringOf(map['op'], 'op'),
      at: _stringOf(map['at'], 'at'),
    );
  }

  /// The database the change hit.
  final String databaseId;

  /// The model name of the collection, e.g. `Txn`.
  final String collection;

  /// The document path.
  final String path;

  /// `set` or `delete`.
  final String op;

  /// The commit time as a UTC ISO-8601 string.
  final String at;
}

/// The whole `cocoon:changes` event payload: every (table, path, op) a
/// committed transaction touched.
final class ChangeBatch {
  const ChangeBatch({required this.databaseId, required this.changes});

  /// Parses a `cocoon:changes` event payload.
  factory ChangeBatch.fromJson(Object? json) {
    final map = _mapOf(json, 'change event');
    final databaseId = _stringOf(map['databaseId'], 'databaseId');
    return ChangeBatch(
      databaseId: databaseId,
      changes: [
        for (final change in _listOf(map['changes'], 'changes'))
          ChangeRecord.fromJson(databaseId, change),
      ],
    );
  }

  /// The database the transaction committed to.
  final String databaseId;

  /// The touched documents.
  final List<ChangeRecord> changes;
}

/// The `{param}` names a collection pattern takes, in order.
List<String> patternParams(String pattern) => [
  for (final segment in pattern.split('/'))
    if (segment.startsWith('{') && segment.endsWith('}'))
      segment.substring(1, segment.length - 1),
];

/// The paths the document browser can list at the root of the database: the
/// concrete path of every collection whose pattern has no parent segments.
List<String> topLevelCollectionPaths(Iterable<CollectionInfo> collections) {
  final paths = <String>[];
  for (final collection in collections) {
    final segments = collection.pattern.split('/');
    if (segments.length == 1 && segments.first.isNotEmpty) {
      paths.add(segments.first);
    }
  }
  return paths..sort();
}

/// The concrete path of [pattern] as a direct subcollection of the document
/// at [docPath], or `null` when [pattern] is not one.
///
/// The pattern's segments must align with the document path segment by
/// segment (literal segments equal, param segments take the document's),
/// then add exactly one literal collection segment. This is how the
/// document browser drills down: `accounts/a1/txns/t9` plus the pattern
/// `accounts/{accountId}/txns/{txnId}/splits` gives
/// `accounts/a1/txns/t9/splits`.
String? subcollectionPathOf(String pattern, String docPath) {
  final patternSegments = pattern.split('/');
  final docSegments = docPath.split('/');
  if (patternSegments.length != docSegments.length + 1) {
    return null;
  }
  for (var i = 0; i < docSegments.length; i++) {
    final segment = patternSegments[i];
    if (segment.startsWith('{')) {
      continue;
    }
    if (segment != docSegments[i]) {
      return null;
    }
  }
  final last = patternSegments.last;
  if (last.isEmpty || last.startsWith('{')) {
    return null;
  }
  return '$docPath/$last';
}

/// The query value a filter's text input decodes to: `null`, `true`,
/// `false` and numbers keep their JSON types, anything else stays a string.
///
/// `DateTime` indexed columns store UTC microseconds since epoch, so those
/// filters take an integer literal.
Object? parseQueryValue(String raw) {
  final text = raw.trim();
  if (text == 'null') {
    return null;
  }
  if (text == 'true') {
    return true;
  }
  if (text == 'false') {
    return false;
  }
  return int.tryParse(text) ?? double.tryParse(text) ?? text;
}

/// The one error every extension call can carry instead of a result.
class InspectorCallException implements Exception {
  const InspectorCallException(this.message);

  /// The app side's error text.
  final String message;

  @override
  String toString() => message;
}

// -- Storage (preview) -------------------------------------------------------
//
// The Storage tab renders where a database file's bytes go. The live feed is
// not wired yet: the classes below define the JSON shape a future
// `ext.cocoon.storage` service extension must return, and the tab renders
// built-in preview payloads ([StorageReport.previewIdle],
// [StorageReport.previewBulkLoad]) until that extension exists.

/// The whole `ext.cocoon.storage` result: the file, every collection's
/// bytes, the change log and the bulk-load state.
///
/// This dartdoc is the shape contract for the app-side handler a later step
/// implements (`packages/cocoon/lib/src/inspector/service.dart`); the
/// preview payloads below are exactly this shape, from the 1M-transaction
/// rivals benchmark (`benchmarks/cocoon_rivals/STORAGE.md` Part A):
///
/// ```json
/// {
///   "file": {
///     "dbBytes": 409088000,
///     "walBytes": 37343232,
///     "freelistBytes": 0,
///     "pageSize": 4096,
///     "pageCount": 99875
///   },
///   "collections": [
///     {
///       "model": "Txn",
///       "pattern": "accounts/{accountId}/txns",
///       "table": "txn",
///       "documentCount": 1000025,
///       "tableBytes": 165830656,
///       "pathIndex": {"name": "sqlite_autoindex_txn_1", "bytes": 41328640},
///       "scopeIndex": {"name": "cx_txn_scope", "bytes": 25952256},
///       "indexes": [
///         {
///           "name": "cx_txn_54b66501d86f96a9",
///           "unique": false,
///           "parts": [
///             {"name": "accountId", "descending": false},
///             {"name": "bookedOn", "descending": true}
///           ],
///           "bytes": 31055872,
///           "state": "live"
///         }
///       ],
///       "changeLogBytes": 54771712
///     }
///   ],
///   "changeLog": {"bytes": 54771712, "rows": 1000690},
///   "bulkLoad": {"active": false}
/// }
/// ```
///
/// Field-by-field:
///
/// - `file.dbBytes`: the main database file, `page_count * page_size` —
///   every page dbstat can account for, free pages included.
///   `file.walBytes`: the `-wal` sidecar's size on disk (0 when
///   checkpointed away). `file.freelistBytes`: `freelist_count * page_size`
///   — pages the file would give back after a `VACUUM`. The headline the
///   tab shows is `dbBytes + walBytes`, the on-disk footprint.
/// - `collections`: one entry per collection table, any order. `tableBytes`
///   is the table's own pages (rows). `pathIndex` is the `path UNIQUE`
///   autoindex and `scopeIndex` the `(param, id)` scope index; either may
///   be `null` when the layout keeps none. `indexes` lists the collection's
///   declared secondary indexes only. `changeLogBytes` is the share of the
///   change-log table this collection's writes produced; the log's own
///   whole-table row is `changeLog`. Small objects (other collections'
///   tables, `_cocoon_meta`, `sqlite_sequence`, the schema) may be left
///   unattributed — nothing else in the file is double-counted, except the
///   change-log share, which is reported inside its collection and again in
///   `changeLog` because both views are useful.
/// - `indexes[].bytes` is 0 while the index is not in the file (deferred by
///   a bulk load, or rebuilding). `indexes[].state` is `live`, `deferred`
///   or `rebuilding`; a state word the tab does not know parses as an
///   unknown state instead of throwing, so the two packages can drift.
/// - `bulkLoad` is `{"active": false}` when no `bulkWriter()` runs; while
///   one runs it carries `elapsedMs`, `rowsCommitted`, `rowsQueued` (still
///   buffered), `chunkSize`, `deferredIndexes` (physical index names) and
///   `waitingQueries` (how many queries are held until the deferred
///   indexes come back).
final class StorageReport {
  const StorageReport({
    required this.file,
    required this.collections,
    required this.changeLog,
    required this.bulkLoad,
  });

  /// Parses the whole `storage` result.
  factory StorageReport.fromJson(Object? json) {
    final map = _mapOf(json, 'storage result');
    return StorageReport(
      file: StorageFile.fromJson(map['file']),
      collections: [
        for (final entry in _listOf(map['collections'], 'collections'))
          CollectionStorage.fromJson(entry),
      ],
      changeLog: ChangeLogStorage.fromJson(map['changeLog']),
      bulkLoad: BulkLoadReport.fromJson(map['bulkLoad']),
    );
  }

  /// The database file's page accounting.
  final StorageFile file;

  /// One entry per collection table, any order.
  final List<CollectionStorage> collections;

  /// The change-log table, whole.
  final ChangeLogStorage changeLog;

  /// Whether a `bulkWriter()` is running, and its progress.
  final BulkLoadReport bulkLoad;

  /// Encodes the report back to the documented wire shape.
  Map<String, Object?> toJson() => {
    'file': file.toJson(),
    'collections': [for (final collection in collections) collection.toJson()],
    'changeLog': changeLog.toJson(),
    'bulkLoad': bulkLoad.toJson(),
  };

  /// The preview payload for a database at rest: the 1M-transaction rivals
  /// benchmark's checkpointed file (STORAGE.md Part A — page counts times
  /// the 4096-byte page size), plus a WAL sidecar like the one the rivals
  /// matrix measured (RESULTS.md's 425.8 MB "File size" row is the open
  /// file plus its un-checkpointed WAL; the db pages are Part A's).
  static Map<String, Object?> previewIdleJson() => {
    'file': {
      'dbBytes': 99875 * 4096,
      'walBytes': 9117 * 4096,
      'freelistBytes': 0,
      'pageSize': 4096,
      'pageCount': 99875,
    },
    'collections': [
      {
        'model': 'Txn',
        'pattern': 'accounts/{accountId}/txns',
        'table': 'txn',
        'documentCount': 1000025,
        'tableBytes': 40486 * 4096,
        'pathIndex': {'name': 'sqlite_autoindex_txn_1', 'bytes': 10090 * 4096},
        'scopeIndex': {'name': 'cx_txn_scope', 'bytes': 6336 * 4096},
        'indexes': [
          _previewIndex('cx_txn_54b66501d86f96a9', 7582, const [
            (name: 'accountId', descending: false),
            (name: 'bookedOn', descending: true),
          ]),
          _previewIndex('cx_txn_31eb54e047d080dd', 8876, const [
            (name: 'status', descending: false),
            (name: 'bookedOn', descending: false),
          ]),
          _previewIndex('cx_txn_f4ecd63f00d4b439', 6918, const [
            (name: 'bookedOn', descending: false),
          ]),
          _previewIndex('cx_txn_4081929ae6be2a63', 6207, const [
            (name: 'amountMinor', descending: false),
          ]),
        ],
        'changeLogBytes': 13372 * 4096,
      },
    ],
    'changeLog': {'bytes': 13372 * 4096, 'rows': 1000690},
    'bulkLoad': {'active': false},
  };

  /// The preview payload with a `bulkWriter()` mid-load: ~80% of the same
  /// 1M import committed (page-rounded from Part A), the four secondary
  /// indexes deferred — so they hold no pages — the WAL near the engine's
  /// 8,000-page autocheckpoint ceiling, a small freelist from chunk churn,
  /// and two queries waiting for the deferred indexes. The load-plausible
  /// page counts are derived from Part A, not measured.
  static Map<String, Object?> previewBulkLoadJson() => {
    'file': {
      'dbBytes': (32389 + 10698 + 8072 + 5069 + 6 + 96) * 4096,
      'walBytes': 7922 * 4096,
      'freelistBytes': 96 * 4096,
      'pageSize': 4096,
      'pageCount': 32389 + 10698 + 8072 + 5069 + 6 + 96,
    },
    'collections': [
      {
        'model': 'Txn',
        'pattern': 'accounts/{accountId}/txns',
        'table': 'txn',
        'documentCount': 800000,
        'tableBytes': 32389 * 4096,
        'pathIndex': {'name': 'sqlite_autoindex_txn_1', 'bytes': 8072 * 4096},
        'scopeIndex': {'name': 'cx_txn_scope', 'bytes': 5069 * 4096},
        'indexes': [
          _previewIndex('cx_txn_54b66501d86f96a9', 0, const [
            (name: 'accountId', descending: false),
            (name: 'bookedOn', descending: true),
          ], state: 'deferred'),
          _previewIndex('cx_txn_31eb54e047d080dd', 0, const [
            (name: 'status', descending: false),
            (name: 'bookedOn', descending: false),
          ], state: 'deferred'),
          _previewIndex('cx_txn_f4ecd63f00d4b439', 0, const [
            (name: 'bookedOn', descending: false),
          ], state: 'deferred'),
          _previewIndex('cx_txn_4081929ae6be2a63', 0, const [
            (name: 'amountMinor', descending: false),
          ], state: 'deferred'),
        ],
        'changeLogBytes': 10698 * 4096,
      },
    ],
    'changeLog': {'bytes': 10698 * 4096, 'rows': 800000},
    'bulkLoad': {
      'active': true,
      'elapsedMs': 10400,
      'rowsCommitted': 800000,
      'rowsQueued': 200000,
      'chunkSize': 10000,
      'deferredIndexes': [
        'cx_txn_54b66501d86f96a9',
        'cx_txn_31eb54e047d080dd',
        'cx_txn_f4ecd63f00d4b439',
        'cx_txn_4081929ae6be2a63',
      ],
      'waitingQueries': 2,
    },
  };

  /// The idle preview, parsed. (The tab renders these through [fromJson] so
  /// every render exercises the wire shape.)
  static StorageReport previewIdle() =>
      StorageReport.fromJson(previewIdleJson());

  /// The active-bulk-load preview, parsed.
  static StorageReport previewBulkLoad() =>
      StorageReport.fromJson(previewBulkLoadJson());

  @override
  bool operator ==(Object other) =>
      other is StorageReport &&
      file == other.file &&
      bulkLoad == other.bulkLoad &&
      changeLog == other.changeLog &&
      _listEquals(collections, other.collections);

  @override
  int get hashCode =>
      Object.hash(file, changeLog, bulkLoad, collections.length);
}

/// One declared secondary index of the `storage` result.
final class StorageIndex {
  const StorageIndex({
    required this.name,
    required this.unique,
    required this.parts,
    required this.bytes,
    required this.stateRaw,
  });

  /// Parses one entry of a collection's `indexes`.
  factory StorageIndex.fromJson(Object? json) {
    final map = _mapOf(json, 'storage index');
    return StorageIndex(
      name: _stringOf(map['name'], 'name'),
      unique: map['unique'] == true,
      parts: [
        for (final part in _listOf(map['parts'], 'parts'))
          () {
            final partMap = _mapOf(part, 'index part');
            return (
              name: _stringOf(partMap['name'], 'name'),
              descending: partMap['descending'] == true,
            );
          }(),
      ],
      bytes: _intOf(map['bytes'], 'bytes'),
      stateRaw: _stringOf(map['state'], 'state'),
    );
  }

  /// The physical index name (`cx_<table>_<hex>`).
  final String name;

  /// Whether the index enforces uniqueness.
  final bool unique;

  /// The (name, descending) parts in declaration order.
  final List<({String name, bool descending})> parts;

  /// The bytes the index's pages take; 0 while it is not in the file.
  final int bytes;

  /// The state word the wire carried (`live`, `deferred`, `rebuilding`, or
  /// something newer — see [state]).
  final String stateRaw;

  /// The parsed state; an unknown word parses as [StorageIndexState.unknown]
  /// instead of throwing.
  StorageIndexState get state => storageIndexStateFrom(stateRaw);

  /// The human label for the declared fields, e.g. `account, newest first`.
  String get fieldsLabel => storageIndexFieldsLabel(parts);

  /// Encodes back to the documented wire shape.
  Map<String, Object?> toJson() => {
    'name': name,
    'unique': unique,
    'parts': [
      for (final part in parts)
        {'name': part.name, 'descending': part.descending},
    ],
    'bytes': bytes,
    'state': stateRaw,
  };

  @override
  bool operator ==(Object other) =>
      other is StorageIndex &&
      name == other.name &&
      unique == other.unique &&
      bytes == other.bytes &&
      stateRaw == other.stateRaw &&
      _listEquals(parts, other.parts);

  @override
  int get hashCode => Object.hash(name, unique, bytes, stateRaw, parts.length);
}

/// Where a collection's index stands relative to a bulk load.
enum StorageIndexState {
  /// In the file and serving queries.
  live,

  /// Dropped for the duration of a bulk load.
  deferred,

  /// Being rebuilt (a bulk load just finished, or crash recovery ran).
  rebuilding,

  /// A state word this build does not know; [StorageIndex.stateRaw] carries
  /// the original.
  unknown,
}

/// Parses a `storage` index state word; unknown words become
/// [StorageIndexState.unknown] so a newer app side cannot crash the tab.
StorageIndexState storageIndexStateFrom(String raw) => switch (raw) {
  'live' => StorageIndexState.live,
  'deferred' => StorageIndexState.deferred,
  'rebuilding' => StorageIndexState.rebuilding,
  _ => StorageIndexState.unknown,
};

/// The human words for an index state; an unknown state shows the raw wire
/// word so the mismatch is visible.
String storageIndexStateLabel(StorageIndex index) => switch (index.state) {
  StorageIndexState.live => 'Live',
  StorageIndexState.deferred => 'Deferred by a bulk load',
  StorageIndexState.rebuilding => 'Rebuilding',
  StorageIndexState.unknown => index.stateRaw,
};

/// One engine-owned index of a collection table in the `storage` result:
/// the `path UNIQUE` autoindex or the `(param, id)` scope index.
final class StorageTableIndex {
  const StorageTableIndex({required this.name, required this.bytes});

  /// Parses one entry of a `pathIndex` / `scopeIndex` field.
  factory StorageTableIndex.fromJson(Object? json) {
    final map = _mapOf(json, 'table index');
    return StorageTableIndex(
      name: _stringOf(map['name'], 'name'),
      bytes: _intOf(map['bytes'], 'bytes'),
    );
  }

  /// The physical index name.
  final String name;

  /// The bytes the index's pages take.
  final int bytes;

  /// Encodes back to the documented wire shape.
  Map<String, Object?> toJson() => {'name': name, 'bytes': bytes};

  @override
  bool operator ==(Object other) =>
      other is StorageTableIndex && name == other.name && bytes == other.bytes;

  @override
  int get hashCode => Object.hash(name, bytes);
}

/// One collection table's bytes in the `storage` result.
final class CollectionStorage {
  const CollectionStorage({
    required this.model,
    required this.pattern,
    required this.table,
    required this.documentCount,
    required this.tableBytes,
    required this.pathIndex,
    required this.scopeIndex,
    required this.indexes,
    required this.changeLogBytes,
  });

  /// Parses one entry of the `storage` result's `collections`.
  factory CollectionStorage.fromJson(Object? json) {
    final map = _mapOf(json, 'collection storage');
    return CollectionStorage(
      model: _stringOf(map['model'], 'model'),
      pattern: _stringOf(map['pattern'], 'pattern'),
      table: _stringOf(map['table'], 'table'),
      documentCount: _intOf(map['documentCount'], 'documentCount'),
      tableBytes: _intOf(map['tableBytes'], 'tableBytes'),
      pathIndex: map['pathIndex'] == null
          ? null
          : StorageTableIndex.fromJson(map['pathIndex']),
      scopeIndex: map['scopeIndex'] == null
          ? null
          : StorageTableIndex.fromJson(map['scopeIndex']),
      indexes: [
        for (final index in _listOf(map['indexes'], 'indexes'))
          StorageIndex.fromJson(index),
      ],
      changeLogBytes: _intOf(map['changeLogBytes'], 'changeLogBytes'),
    );
  }

  /// The Dart model class name.
  final String model;

  /// The collection path pattern, e.g. `accounts/{accountId}/txns`.
  final String pattern;

  /// The SQL table the collection stores its documents in.
  final String table;

  /// How many documents the table holds.
  final int documentCount;

  /// The bytes the table's own pages (the rows) take.
  final int tableBytes;

  /// The `path UNIQUE` autoindex, or `null` when the layout keeps none.
  final StorageTableIndex? pathIndex;

  /// The `(param, id)` scope index, or `null` when the table has none.
  final StorageTableIndex? scopeIndex;

  /// The collection's declared secondary indexes, any order.
  final List<StorageIndex> indexes;

  /// The share of the change-log table this collection's writes produced.
  final int changeLogBytes;

  /// Every byte of the file attributed to this collection, change-log share
  /// included.
  int get totalBytes =>
      tableBytes +
      (pathIndex?.bytes ?? 0) +
      (scopeIndex?.bytes ?? 0) +
      changeLogBytes +
      [
        for (final index in indexes) index.bytes,
      ].fold(0, (sum, bytes) => sum + bytes);

  /// Encodes back to the documented wire shape.
  Map<String, Object?> toJson() => {
    'model': model,
    'pattern': pattern,
    'table': table,
    'documentCount': documentCount,
    'tableBytes': tableBytes,
    'pathIndex': pathIndex?.toJson(),
    'scopeIndex': scopeIndex?.toJson(),
    'indexes': [for (final index in indexes) index.toJson()],
    'changeLogBytes': changeLogBytes,
  };

  @override
  bool operator ==(Object other) =>
      other is CollectionStorage &&
      model == other.model &&
      pattern == other.pattern &&
      table == other.table &&
      documentCount == other.documentCount &&
      tableBytes == other.tableBytes &&
      pathIndex == other.pathIndex &&
      scopeIndex == other.scopeIndex &&
      changeLogBytes == other.changeLogBytes &&
      _listEquals(indexes, other.indexes);

  @override
  int get hashCode => Object.hash(
    model,
    pattern,
    table,
    documentCount,
    tableBytes,
    pathIndex,
    scopeIndex,
    changeLogBytes,
    indexes.length,
  );
}

/// The change-log table in the `storage` result, whole (the per-collection
/// shares live on [CollectionStorage.changeLogBytes]).
final class ChangeLogStorage {
  const ChangeLogStorage({required this.bytes, required this.rows});

  /// Parses the `storage` result's `changeLog` entry.
  factory ChangeLogStorage.fromJson(Object? json) {
    final map = _mapOf(json, 'change log');
    return ChangeLogStorage(
      bytes: _intOf(map['bytes'], 'bytes'),
      rows: _intOf(map['rows'], 'rows'),
    );
  }

  /// The bytes the table's pages take.
  final int bytes;

  /// How many change rows the table holds (one per written document per
  /// committed write).
  final int rows;

  /// Encodes back to the documented wire shape.
  Map<String, Object?> toJson() => {'bytes': bytes, 'rows': rows};

  @override
  bool operator ==(Object other) =>
      other is ChangeLogStorage && bytes == other.bytes && rows == other.rows;

  @override
  int get hashCode => Object.hash(bytes, rows);
}

/// The bulk-load section of the `storage` result: idle, or a running
/// `bulkWriter()`'s progress.
final class BulkLoadReport {
  const BulkLoadReport({
    required this.active,
    this.elapsedMs = 0,
    this.rowsCommitted = 0,
    this.rowsQueued = 0,
    this.chunkSize = 0,
    this.deferredIndexes = const [],
    this.waitingQueries = 0,
  });

  /// The idle report every `{"active": false}` payload parses to.
  static const BulkLoadReport idle = BulkLoadReport(active: false);

  /// Parses the `storage` result's `bulkLoad` entry.
  ///
  /// An inactive payload needs nothing but `active: false`; an active one
  /// must carry the whole progress set — a shape the app side does not
  /// produce throws a [FormatException] naming the missing piece.
  factory BulkLoadReport.fromJson(Object? json) {
    final map = _mapOf(json, 'bulk load');
    if (map['active'] != true) {
      return idle;
    }
    return BulkLoadReport(
      active: true,
      elapsedMs: _intOf(map['elapsedMs'], 'elapsedMs'),
      rowsCommitted: _intOf(map['rowsCommitted'], 'rowsCommitted'),
      rowsQueued: _intOf(map['rowsQueued'], 'rowsQueued'),
      chunkSize: _intOf(map['chunkSize'], 'chunkSize'),
      deferredIndexes: [
        for (final name in _listOf(map['deferredIndexes'], 'deferredIndexes'))
          _stringOf(name, 'deferred index name'),
      ],
      waitingQueries: _intOf(map['waitingQueries'], 'waitingQueries'),
    );
  }

  /// Whether a `bulkWriter()` is running.
  final bool active;

  /// Milliseconds since the writer started (active payloads only).
  final int elapsedMs;

  /// Rows committed so far, chunk by chunk.
  final int rowsCommitted;

  /// Rows still buffered, not yet committed.
  final int rowsQueued;

  /// Rows per chunk commit ([BulkWriterOptions.chunkSize] on the app side).
  final int chunkSize;

  /// The physical index names the writer deferred.
  final List<String> deferredIndexes;

  /// How many queries are held until the deferred indexes are rebuilt.
  final int waitingQueries;

  /// Committed share of the whole load, 0 to 1; 0 when nothing is queued.
  double get progress {
    final total = rowsCommitted + rowsQueued;
    return total == 0 ? 0 : rowsCommitted / total;
  }

  /// Encodes back to the documented wire shape; the idle report encodes to
  /// exactly `{"active": false}`.
  Map<String, Object?> toJson() => active
      ? {
          'active': true,
          'elapsedMs': elapsedMs,
          'rowsCommitted': rowsCommitted,
          'rowsQueued': rowsQueued,
          'chunkSize': chunkSize,
          'deferredIndexes': List<String>.of(deferredIndexes),
          'waitingQueries': waitingQueries,
        }
      : {'active': false};

  @override
  bool operator ==(Object other) =>
      other is BulkLoadReport &&
      active == other.active &&
      elapsedMs == other.elapsedMs &&
      rowsCommitted == other.rowsCommitted &&
      rowsQueued == other.rowsQueued &&
      chunkSize == other.chunkSize &&
      waitingQueries == other.waitingQueries &&
      _listEquals(deferredIndexes, other.deferredIndexes);

  @override
  int get hashCode => Object.hash(
    active,
    elapsedMs,
    rowsCommitted,
    rowsQueued,
    chunkSize,
    waitingQueries,
    deferredIndexes.length,
  );
}

/// The database file's page accounting in the `storage` result.
final class StorageFile {
  const StorageFile({
    required this.dbBytes,
    required this.walBytes,
    required this.freelistBytes,
    required this.pageSize,
    required this.pageCount,
  });

  /// Parses the `storage` result's `file` entry.
  factory StorageFile.fromJson(Object? json) {
    final map = _mapOf(json, 'file');
    return StorageFile(
      dbBytes: _intOf(map['dbBytes'], 'dbBytes'),
      walBytes: _intOf(map['walBytes'], 'walBytes'),
      freelistBytes: _intOf(map['freelistBytes'], 'freelistBytes'),
      pageSize: _intOf(map['pageSize'], 'pageSize'),
      pageCount: _intOf(map['pageCount'], 'pageCount'),
    );
  }

  /// The main database file (`page_count * page_size`), free pages included.
  final int dbBytes;

  /// The `-wal` sidecar's size on disk, 0 when checkpointed away.
  final int walBytes;

  /// Free pages (`freelist_count * page_size`): what a `VACUUM` would give
  /// back.
  final int freelistBytes;

  /// The page size in bytes.
  final int pageSize;

  /// How many pages the main file holds ([dbBytes] / [pageSize]).
  final int pageCount;

  /// The on-disk footprint the tab's headline shows: database file plus
  /// WAL sidecar.
  int get totalBytes => dbBytes + walBytes;

  /// The reclaimable bytes ([freelistBytes]).
  int get reclaimableBytes => freelistBytes;

  /// Encodes back to the documented wire shape.
  Map<String, Object?> toJson() => {
    'dbBytes': dbBytes,
    'walBytes': walBytes,
    'freelistBytes': freelistBytes,
    'pageSize': pageSize,
    'pageCount': pageCount,
  };

  @override
  bool operator ==(Object other) =>
      other is StorageFile &&
      dbBytes == other.dbBytes &&
      walBytes == other.walBytes &&
      freelistBytes == other.freelistBytes &&
      pageSize == other.pageSize &&
      pageCount == other.pageCount;

  @override
  int get hashCode =>
      Object.hash(dbBytes, walBytes, freelistBytes, pageSize, pageCount);
}

/// What a stacked-bar slice of a collection's bytes stands for.
enum StorageSegmentKind {
  /// The collection table's rows.
  rows,

  /// The `path UNIQUE` autoindex.
  pathIndex,

  /// The `(param, id)` scope index.
  scopeIndex,

  /// One declared secondary index ([StorageSegment.index] carries it).
  secondary,

  /// The collection's share of the change-log table.
  changeLog,
}

/// One slice of a collection's stacked bar in the Storage tab: a byte count
/// plus what the tap detail shows (share, average bytes per row).
///
/// Segments are derived views ([storageSegments], [changeLogSegment]); they
/// are not part of the wire shape.
final class StorageSegment {
  const StorageSegment({
    required this.kind,
    required this.label,
    required this.bytes,
    required this.shareTotalBytes,
    this.sqlName,
    this.entries,
    this.index,
  });

  /// Which kind of object the slice stands for.
  final StorageSegmentKind kind;

  /// The human label ("Documents", "Change log", "Index: account, newest
  /// first").
  final String label;

  /// The bytes the slice's pages take.
  final int bytes;

  /// The total the segment's [share] is taken against (the database file).
  final int shareTotalBytes;

  /// The physical SQL object name, for the tooltip.
  final String? sqlName;

  /// The rows the slice covers, for the average-bytes-per-row detail.
  final int? entries;

  /// The declared index, when [kind] is [StorageSegmentKind.index].
  final StorageIndex? index;

  /// The slice's share of [shareTotalBytes], 0 to 1.
  double get share => shareTotalBytes <= 0 ? 0 : bytes / shareTotalBytes;

  /// The average bytes per row across [entries]; 0 when unknown.
  double get avgBytesPerRow {
    final rows = entries;
    if (rows == null || rows == 0) {
      return 0;
    }
    return bytes / rows;
  }

  /// The stable key the tab tracks the tapped segment by across rebuilds.
  String get key => '$kind:$sqlName:$label';
}

/// The stacked-bar slices for [collection] out of [report]: rows, path
/// index, scope index, every secondary index that is in the file, the
/// change-log share — sorted by size, largest first, zero-byte objects
/// (deferred indexes) dropped. Shares are taken against the database file.
List<StorageSegment> storageSegments(
  CollectionStorage collection,
  StorageReport report,
) {
  final shareTotalBytes = report.file.dbBytes;
  final segments = [
    StorageSegment(
      kind: StorageSegmentKind.rows,
      label: 'Documents',
      bytes: collection.tableBytes,
      shareTotalBytes: shareTotalBytes,
      sqlName: collection.table,
      entries: collection.documentCount,
    ),
    if (collection.pathIndex != null)
      StorageSegment(
        kind: StorageSegmentKind.pathIndex,
        label: 'Path index',
        bytes: collection.pathIndex!.bytes,
        shareTotalBytes: shareTotalBytes,
        sqlName: collection.pathIndex!.name,
        entries: collection.documentCount,
      ),
    if (collection.scopeIndex != null)
      StorageSegment(
        kind: StorageSegmentKind.scopeIndex,
        label: 'Scope (account, id)',
        bytes: collection.scopeIndex!.bytes,
        shareTotalBytes: shareTotalBytes,
        sqlName: collection.scopeIndex!.name,
        entries: collection.documentCount,
      ),
    for (final index in collection.indexes)
      StorageSegment(
        kind: StorageSegmentKind.secondary,
        label: 'Index: ${index.fieldsLabel}',
        bytes: index.bytes,
        shareTotalBytes: shareTotalBytes,
        sqlName: index.name,
        entries: collection.documentCount,
        index: index,
      ),
    StorageSegment(
      kind: StorageSegmentKind.changeLog,
      label: 'Change log',
      bytes: collection.changeLogBytes,
      shareTotalBytes: shareTotalBytes,
      sqlName: '_cocoon_changes',
      entries: report.changeLog.rows,
    ),
  ];
  final inFile = [
    for (final segment in segments)
      if (segment.bytes > 0) segment,
  ]..sort((a, b) => b.bytes.compareTo(a.bytes));
  return inFile;
}

/// The change-log table's own stacked-bar slice: the separate row the tab
/// shows under the collection bars.
StorageSegment changeLogSegment(
  ChangeLogStorage changeLog,
  int shareTotalBytes,
) => StorageSegment(
  kind: StorageSegmentKind.changeLog,
  label: 'Change log',
  bytes: changeLog.bytes,
  shareTotalBytes: shareTotalBytes,
  sqlName: '_cocoon_changes',
  entries: changeLog.rows,
);

/// The human label for a declared index's fields: camelCase splits into
/// lowercase words and a trailing " id" is dropped ("accountId" reads
/// "account"), and a descending date-like sort field ("bookedOn") reads
/// "newest first" — e.g. `[accountId, -bookedOn]` reads
/// "account, newest first".
String storageIndexFieldsLabel(List<({String name, bool descending})> parts) =>
    parts
        .map((part) {
          if (!part.descending) {
            return _humanFieldName(part.name);
          }
          return _dateLikeField(part.name)
              ? 'newest first'
              : '${_humanFieldName(part.name)}, descending';
        })
        .join(', ');

bool _dateLikeField(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('on') || lower.endsWith('at');
}

String _humanFieldName(String name) {
  final words = name
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .toLowerCase()
      .split(' ');
  if (words.length > 1 && words.last == 'id') {
    words.removeLast();
  }
  return words.join(' ');
}

/// Human byte size in the monorepo benchmark convention (MB = 1024², GB =
/// 1024³, matching RESULTS.md / STORAGE.md / CEILING.md): "425.8 MB",
/// "35.6 MB", "32 KB", "48 B".
String formatBytes(num bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${_oneDecimal(bytes / (1024 * 1024 * 1024))} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${_oneDecimal(bytes / (1024 * 1024))} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).round()} KB';
  }
  return '${bytes.round()} B';
}

/// Human count with thousands separators: "1,000,025".
String formatCount(int count) => count.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (match) => ',',
);

/// Human share, 0 to 1: "40.5%".
String formatPercent(double fraction) =>
    '${(fraction * 100).toStringAsFixed(1)}%';

/// Human elapsed milliseconds: "10.4 s" under a minute, "1 m 05 s" above.
String formatElapsed(int milliseconds) {
  if (milliseconds < 60000) {
    return '${_oneDecimal(milliseconds / 1000)} s';
  }
  final minutes = milliseconds ~/ 60000;
  final seconds = (milliseconds % 60000) ~/ 1000;
  return '$minutes m ${seconds.toString().padLeft(2, '0')} s';
}

String _oneDecimal(double value) => value.toStringAsFixed(1);

Map<String, Object?> _previewIndex(
  String name,
  int pages,
  List<({String name, bool descending})> parts, {
  String state = 'live',
}) => {
  'name': name,
  'unique': false,
  'parts': [
    for (final part in parts)
      {'name': part.name, 'descending': part.descending},
  ],
  'bytes': pages * 4096,
  'state': state,
};

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _mapOf(Object? value, String what) =>
    value is Map<String, Object?>
    ? value
    : throw FormatException('$what: expected a JSON object');

List<Object?> _listOf(Object? value, String what) => value is List<Object?>
    ? value
    : throw FormatException('$what: expected a JSON array');

String _stringOf(Object? value, String what) =>
    value is String ? value : throw FormatException('$what: expected a string');

int _intOf(Object? value, String what) =>
    value is int ? value : throw FormatException('$what: expected an integer');
