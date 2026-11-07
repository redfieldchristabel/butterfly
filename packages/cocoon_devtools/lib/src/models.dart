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

/// One column of a collection's SQL table: an indexed field or a path param.
final class CollectionColumn {
  const CollectionColumn({
    required this.name,
    required this.type,
    required this.nullable,
  });

  /// Parses one entry of `listCollections`'s `columns`.
  factory CollectionColumn.fromJson(Object? json) {
    final map = _mapOf(json, 'column');
    return CollectionColumn(
      name: _stringOf(map['name'], 'name'),
      type: _stringOf(map['type'], 'type'),
      nullable: map['nullable'] == true,
    );
  }

  /// The field or path param name the query runner filters and sorts by.
  final String name;

  /// The SQL storage type (`text`, `integer`, `real`, `blob`).
  final String type;

  /// Whether the field can be absent; nullable columns cannot be sorted.
  final bool nullable;
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
  });

  /// Parses one entry of the `schema` result's `columns`.
  factory TableColumn.fromJson(Object? json) {
    final map = _mapOf(json, 'table column');
    return TableColumn(
      name: _stringOf(map['name'], 'name'),
      type: _stringOf(map['type'], 'type'),
      notNull: map['notNull'] == true,
      isPrimaryKey: map['isPrimaryKey'] == true,
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

  /// The parsed `cocoon.lock.json` the app passed to `Cocoon.open`, or
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
