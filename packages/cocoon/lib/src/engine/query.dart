import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:meta/meta.dart';

import '../cursor.dart';
import '../path.dart';
import 'adapter.dart';
import 'aggregate.dart';
import 'cocoon.dart';
import 'naming.dart';
import 'refs.dart';
import 'schema_sql.dart';

/// Thrown when no declared (or implicit) index can serve a query's filters
/// and sort order.
///
/// The message spells the `Index([...])` to add to the `@Collection`
/// declaration, or points at `.allowFullScan()` when there is nothing to
/// index. When there is something to declare, the message ends with a
/// `Fix:` line carrying the ready one-line command
/// (`dart run cocoon_generator:index add ...`) that edits the model for you,
/// and the declaration that command writes.
class MissingIndexException implements Exception {
  /// Builds the exception with a human-readable [message] and, when there is
  /// something to declare, the ready-to-paste [suggestedIndex] and the
  /// ready-to-run [fixCommand].
  MissingIndexException(this.message, {this.suggestedIndex, this.fixCommand});

  /// Explains which query failed and how to fix it. Ends with exactly one
  /// `Fix:` line when [fixCommand] is set.
  final String message;

  /// The `Index([...])` declaration that would serve the query, or `null`
  /// when the query has nothing to anchor an index on.
  final String? suggestedIndex;

  /// The `dart run cocoon_generator:index add <Model> <fields>` command that
  /// edits the model's source to declare the missing index, or `null` when
  /// the query has nothing to anchor an index on.
  final String? fixCommand;

  @override
  String toString() => 'MissingIndexException: $message';
}

/// How the engine behaves when no declared index serves a query.
enum MissingIndexMode {
  /// Throw a [MissingIndexException] — the default, and the behaviour of a
  /// release build under every mode (see [CocoonOptions.onMissingIndex]).
  throwError,

  /// Debug-only full-scan fallback: run the query without an index guarantee,
  /// print the missing index's message (with its `Fix:` line) once per
  /// distinct missing index per process, and record it in
  /// [Cocoon.missingIndexes]. Honoured only while asserts are enabled —
  /// debug and profile-with-asserts builds; a release build behaves like
  /// [throwError] regardless. Never creates an index at runtime.
  scanAndWarn,
}

/// One missing index a debug [MissingIndexMode.scanAndWarn] query hit: what
/// to declare, and where to look for the query that needs it.
final class MissingIndexReport {
  /// Built by the engine when a scanAndWarn query first hits the index.
  @internal
  MissingIndexReport({
    required this.model,
    required this.fields,
    required this.query,
    required this.fixCommand,
    required this.firstSeen,
  });

  /// The model class the query ran on, e.g. `Txn`.
  final String model;

  /// The index parts to declare, `-` prefixing a descending part, e.g.
  /// `['accountId', '-bookedOn']` — the argument of the `index add` command.
  final List<String> fields;

  /// The query's shape, e.g. `where(accountId == ?, status == ?);
  /// orderBy(-bookedOn)` — names and operators, not values.
  final String query;

  /// The one-line command that edits the model to declare the index.
  final String fixCommand;

  /// When the first query in this process hit the missing index.
  final DateTime firstSeen;

  @override
  String toString() =>
      '$model: ${fields.join(', ')} ($query). Fix: $fixCommand';
}

/// The decision for a query no index serves, made by the debug
/// [MissingIndexMode.scanAndWarn] fallback: return `true` to run the query as
/// a full scan, `false` to throw [error]. [model], [fields] (the index parts
/// to declare) and [queryShape] describe what the caller should record.
@internal
typedef MissingIndexScanDecision =
    bool Function(
      MissingIndexException error, {
      required String model,
      required List<String> fields,
      required String queryShape,
    });

/// The missing indexes already printed in this process, keyed by fix command:
/// one warning per distinct missing index, however many databases or queries
/// hit it.
final Set<String> _warnedMissingIndexes = {};

/// Prints [error] (the message with its `Fix:` line) once per distinct
/// missing index per process, on the `dart:developer` log and stderr.
@internal
void warnMissingIndexOnce(MissingIndexException error) {
  final command = error.fixCommand;
  if (command == null || !_warnedMissingIndexes.add(command)) {
    return;
  }
  log(
    error.toString(),
    name: 'cocoon',
    level: 900, // WARNING
  );
  stderr.writeln('[cocoon] $error');
}

/// Test seam for [warnMissingIndexOnce]'s process-wide once-only set.
@internal
@visibleForTesting
void resetMissingIndexWarnings() => _warnedMissingIndexes.clear();

/// Whether asserts are enabled in this isolate: debug and
/// profile-with-asserts builds. [MissingIndexMode.scanAndWarn] is honoured
/// only when they are.
bool get _assertsEnabled {
  var enabled = false;
  assert(() {
    enabled = true;
    return true;
  }());
  return enabled;
}

/// Whether a query whose plan found no index runs as a full scan under
/// [MissingIndexMode.scanAndWarn]: only in a build with asserts enabled.
/// A release build always throws, whatever the option says.
@internal
bool get missingIndexScanPossible => _assertsEnabled;

/// One sort key of a query: a model field or path param name with its
/// direction. The document id is always appended as the final tiebreaker.
final class QueryOrder {
  /// Builds a sort key for [name].
  const QueryOrder(this.name, {this.descending = false});

  /// The model field or path param name.
  final String name;

  /// Whether this key sorts descending.
  final bool descending;

  @override
  bool operator ==(Object other) =>
      other is QueryOrder &&
      other.name == name &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(name, descending);

  @override
  String toString() => '${descending ? '-' : ''}$name';
}

/// The first index that can serve a query, or `null` when none does.
///
/// A query is served when some index has, in order: all equality-filtered
/// names (any order among themselves, including the scoped path params),
/// then the sort keys with matching directions (or all reversed), and at
/// most one range-filtered name, which must be the first sort key — or, when
/// the query has no sort keys, the next index part after the equality prefix.
///
/// Pure function; unit-tested without a database.
IndexPlan? indexServingQuery({
  required List<IndexPlan> indexes,
  required Set<String> equalityNames,
  required String? rangeName,
  required bool hasUserOrder,
  required List<QueryOrder> orders,
}) {
  for (final index in indexes) {
    if (_serves(index, equalityNames, rangeName, hasUserOrder, orders)) {
      return index;
    }
  }
  return null;
}

bool _serves(
  IndexPlan index,
  Set<String> equalityNames,
  String? rangeName,
  bool hasUserOrder,
  List<QueryOrder> orders,
) {
  final names = [for (final part in index.parts) part.name];
  final directions = [for (final part in index.parts) part.descending];
  // Without sort keys, a range filter takes the index slot right after the
  // equality prefix; with sort keys it must be the first sort key itself.
  final rangeSlot = rangeName != null && !hasUserOrder ? 1 : 0;
  if (names.length != equalityNames.length + rangeSlot + orders.length) {
    return false;
  }
  final prefix = names.take(equalityNames.length).toSet();
  if (prefix.length != equalityNames.length ||
      !equalityNames.containsAll(prefix)) {
    return false;
  }
  final expectedTail = <String>[
    if (rangeSlot == 1) rangeName!,
    for (final order in orders) order.name,
  ];
  if (!_listEquals(names.skip(equalityNames.length).toList(), expectedTail)) {
    return false;
  }
  if (rangeName != null && hasUserOrder && orders.first.name != rangeName) {
    return false;
  }
  var allSame = true;
  var allReversed = true;
  for (var i = 0; i < orders.length; i++) {
    final indexDescending = directions[equalityNames.length + rangeSlot + i];
    if (indexDescending != orders[i].descending) {
      allSame = false;
    }
    if (indexDescending == orders[i].descending) {
      allReversed = false;
    }
  }
  return allSame || allReversed;
}

/// The index parts (`-` prefixing a descending part) that would serve a
/// query, or `null` when the query has no filters and no sort keys to anchor
/// an index on.
List<String>? suggestedIndexParts({
  required List<String> equalityNamesInOrder,
  required String? rangeName,
  required bool hasUserOrder,
  required List<QueryOrder> orders,
}) {
  final parts = <String>[...equalityNamesInOrder];
  if (rangeName != null && !hasUserOrder) {
    parts.add(rangeName);
  }
  for (final order in orders) {
    parts.add(order.descending ? '-${order.name}' : order.name);
  }
  if (parts.isEmpty) {
    return null;
  }
  return parts;
}

/// The `Index([...])` declaration that would serve a query, or `null` when
/// the query has no filters and no sort keys to anchor an index on.
String? suggestedIndexDdl({
  required List<String> equalityNamesInOrder,
  required String? rangeName,
  required bool hasUserOrder,
  required List<QueryOrder> orders,
}) => switch (suggestedIndexParts(
  equalityNamesInOrder: equalityNamesInOrder,
  rangeName: rangeName,
  hasUserOrder: hasUserOrder,
  orders: orders,
)) {
  null => null,
  final parts => indexDeclaration(parts),
};

/// The `Index([...])` source for [parts] (`-` prefixing a descending part).
String indexDeclaration(List<String> parts) =>
    "Index([${parts.map((part) => "'$part'").join(', ')}])";

/// The `dart run cocoon_generator:index add` command that edits [model]'s
/// source to declare the index [parts].
String indexFixCommand(String model, List<String> parts) =>
    'dart run cocoon_generator:index add $model ${parts.join(',')}';

/// What the fix command writes for [parts]: `@Indexed()` on the field for a
/// one-field index over a model field, the `Index([...])` composite
/// otherwise (path params are not fields, so they always stay in the
/// class-level composite).
String indexFixDeclaration(List<String> parts, Set<String> paramNames) {
  if (parts.length == 1) {
    final part = parts.single;
    final name = part.startsWith('-') ? part.substring(1) : part;
    if (!paramNames.contains(name)) {
      return part.startsWith('-')
          ? '@Indexed(descending: true) on $name'
          : '@Indexed() on $name';
    }
  }
  return '${indexDeclaration(parts)} in @Collection(indexes: [...])';
}

/// The executable form of a planned query: SQL, bound arguments, the cursor
/// fingerprint and the columns cursor keys are read from.
final class PlannedQuery {
  const PlannedQuery({
    required this.sql,
    required this.args,
    required this.fingerprint,
    required this.cursorColumns,
    required this.servingIndex,
  });

  /// The page `SELECT`, bound to [args], with `LIMIT ?` when limited.
  final String sql;

  /// Arguments for [sql], in placeholder order.
  final List<Object?> args;

  /// Fingerprint of the canonical query description; cursors carry it and a
  /// cursor from another query is rejected.
  final String fingerprint;

  /// SQL column names the cursor keys are read from, in order-part order.
  final List<String> cursorColumns;

  /// The physical index the planner selected for this query, or `null` when
  /// the query runs without an index guarantee (`.allowFullScan()`).
  ///
  /// The engine uses it to hold a query whose serving index a bulk writer
  /// currently has deferred (dropped for a bulk load): the query waits until
  /// the writer rebuilds the index, then runs.
  final String? servingIndex;
}

/// The shared front half of query planning: the scope param filters plus the
/// user filters, the effective sort order (the id tiebreaker appended), the
/// WHERE fragments with their bound values, and the first index that serves
/// the shape — `null` when the query opted out with `.allowFullScan()`.
///
/// [planQuery], [planAggregate] and [planGroupAggregate] share it, so the
/// index rule is decided once and identically for reads, counts and
/// aggregates.
final class ResolvedFilters {
  ResolvedFilters._(
    this.allFilters,
    this.effectiveOrders,
    this.whereFragments,
    this.whereArgs,
    this.servingIndex,
  );

  /// Every filter the statement applies: the scope's path params first, then
  /// the user's.
  final List<QueryFilter> allFilters;

  /// The sort keys with the document id appended as the final tiebreaker.
  final List<QueryOrder> effectiveOrders;

  /// SQL fragments for [allFilters], ANDed together.
  final List<String> whereFragments;

  /// Bound values for [whereFragments], in placeholder order.
  final List<Object?> whereArgs;

  /// The physical index the planner selected, or `null` for a full scan.
  /// The engine holds the read while a bulk writer has this index deferred.
  final String? servingIndex;
}

ResolvedFilters resolveQueryFilters({
  required RegistryEntry entry,
  required CollectionPath? scopePath,
  required List<QueryFilter> filters,
  required List<QueryOrder> orders,
  required bool fullScan,
  MissingIndexScanDecision? onMissingIndex,
}) {
  final scopeValues = scopePath == null
      ? const <String, String>{}
      : _scopeParamValues(entry, scopePath);
  final allFilters = <QueryFilter>[
    // A subcollection ref scopes by its parent params automatically.
    for (final name in entry.paramNames)
      if (scopeValues.containsKey(name))
        QueryFilter(name, paramColumnName(name), FilterOp.equal, [
          scopeValues[name]!,
        ]),
    ...filters,
  ];

  // The document id is always appended as the final tiebreaker, following
  // the direction of the last sort key so the index order can be reused.
  final effectiveOrders = <QueryOrder>[
    ...orders,
    QueryOrder(
      'id',
      descending: orders.isEmpty ? false : orders.last.descending,
    ),
  ];

  final equalityNames = <String>{};
  final rangeNames = <String>{};
  for (final filter in allFilters) {
    (filter.isEqualityClass ? equalityNames : rangeNames).add(filter.name);
  }

  // Which index serves the query (or none, for a full scan — or for a query
  // the debug scanAndWarn fallback accepts as a scan). The engine holds the
  // query while that index is deferred by a bulk writer.
  final serving = fullScan
      ? null
      : _servingIndexOrNull(
          entry,
          allFilters,
          equalityNames,
          rangeNames,
          orders,
          effectiveOrders,
          onMissingIndex,
        );

  final filterWhere = <String>[
    for (final filter in allFilters) _filterSql(filter),
  ];
  final whereArgs = <Object?>[
    for (final filter in allFilters) ...filter.sqlValues,
  ];

  return ResolvedFilters._(
    allFilters,
    effectiveOrders,
    filterWhere,
    whereArgs,
    serving?.name,
  );
}

/// Builds the SQL for a query: filters, index check, sort order, keyset
/// pagination and count. Pure function over the registry entry.
///
/// Throws a [MissingIndexException] when no index serves the query and it
/// was not marked as a full scan, and an [InvalidCursorException] or
/// [CursorMismatchException] when [cursor] does not belong to this query.
PlannedQuery planQuery({
  required RegistryEntry entry,
  required CollectionPath? scopePath,
  required List<QueryFilter> filters,
  required List<QueryOrder> orders,
  required int? limit,
  required String? cursor,
  required bool fullScan,
  MissingIndexScanDecision? onMissingIndex,
}) {
  final resolved = resolveQueryFilters(
    entry: entry,
    scopePath: scopePath,
    filters: filters,
    orders: orders,
    fullScan: fullScan,
    onMissingIndex: onMissingIndex,
  );
  final effectiveOrders = resolved.effectiveOrders;
  final fingerprint = _fingerprint(entry, scopePath, filters, effectiveOrders);
  final filterWhere = resolved.whereFragments;

  // Keyset predicate for the next page, bound after the filter values.
  final args = <Object?>[...resolved.whereArgs];
  var keysetWhere = '';
  if (cursor != null) {
    final keys = CursorCodec.decode(cursor, expectedFingerprint: fingerprint);
    if (keys.length != effectiveOrders.length) {
      throw const InvalidCursorException(
        'Cursor key count does not match the query sort order',
      );
    }
    keysetWhere = _keysetSql(entry, effectiveOrders, keys, args);
  }
  final pageWhere = <String>[
    ...filterWhere,
    if (keysetWhere != '') keysetWhere,
  ];

  var sql = _selectSql(entry, effectiveOrders);
  if (pageWhere.isNotEmpty) {
    sql = '$sql WHERE ${pageWhere.join(' AND ')}';
  }

  final orderSql = [
    for (final order in effectiveOrders)
      '${_orderSqlName(entry, order.name)} '
          '${order.descending ? 'DESC' : 'ASC'}',
  ].join(', ');
  sql = '$sql ORDER BY $orderSql';

  if (limit != null) {
    sql = '$sql LIMIT ?';
    // Fetch one extra row to know whether a next page exists.
    args.add(limit + 1);
  }

  return PlannedQuery(
    sql: sql,
    args: args,
    fingerprint: fingerprint,
    cursorColumns: _cursorColumns(entry, effectiveOrders),
    servingIndex: resolved.servingIndex,
  );
}

/// Firestore's limit of aggregate functions per `.aggregate([...])` call.
const int maxAggregatesPerCall = 5;

/// The most keys one `.groupBy([...])` call may list.
const int maxGroupKeys = 4;

/// The planned SQL of an aggregate or groupBy query: one statement, its
/// bound arguments, and the physical index the filters' plan needs (which a
/// running bulk writer may have deferred).
final class PlannedAggregate {
  const PlannedAggregate({
    required this.sql,
    required this.args,
    required this.servingIndex,
  });

  /// The aggregate `SELECT`, bound to [args].
  final String sql;

  /// Arguments for [sql], in placeholder order.
  final List<Object?> args;

  /// The physical index the planner selected for the filters, or `null`
  /// when the query runs without an index guarantee (`.allowFullScan()`).
  final String? servingIndex;
}

/// Builds the SQL for an aggregate query: one statement computing every
/// requested [count]/[sum]/[average]/[min]/[max] over the query's filtered
/// rows (the first [limit] rows in the query's order when it has both a
/// limit and sort keys — a subquery, because a top-level `LIMIT` would
/// apply to the single result row and do nothing; without a limit the
/// `ORDER BY` is dropped). Pure function over the registry entry.
///
/// Throws the same [MissingIndexException] [planQuery] throws — the index
/// rule is the query rule — and an [UnmirroredFieldException] for a field
/// without an `f_` column.
PlannedAggregate planAggregate({
  required RegistryEntry entry,
  required CollectionPath? scopePath,
  required List<QueryFilter> filters,
  required List<QueryOrder> orders,
  required int? limit,
  required bool fullScan,
  required List<AggregateFunction<Object?>> specs,
  MissingIndexScanDecision? onMissingIndex,
}) {
  if (specs.isEmpty) {
    throw ArgumentError.value(
      specs,
      'specs',
      'Needs at least one aggregate function',
    );
  }
  if (specs.length > maxAggregatesPerCall) {
    throw ArgumentError.value(
      specs.length,
      'specs',
      'At most $maxAggregatesPerCall aggregations per call',
    );
  }
  final resolved = resolveQueryFilters(
    entry: entry,
    scopePath: scopePath,
    filters: filters,
    orders: orders,
    fullScan: fullScan,
    onMissingIndex: onMissingIndex,
  );
  final where = resolved.whereFragments.isEmpty
      ? ''
      : ' WHERE ${resolved.whereFragments.join(' AND ')}';
  final selectParts = <String>['count(*) AS c'];
  for (var i = 0; i < specs.length; i++) {
    final fragment = _aggregateSelectSql(specs[i], entry, 'a$i');
    if (fragment.isNotEmpty) {
      selectParts.add(fragment);
    }
  }
  final args = <Object?>[...resolved.whereArgs];
  String sql;
  if (limit != null) {
    // Aggregate the first `limit` rows in the query's order: a subquery so
    // LIMIT applies to the rows before the aggregation.
    final columns = <String>[];
    for (final spec in specs) {
      final column = spec.column;
      if (column != null) {
        final name = _mirroredColumnName(column, entry);
        if (!columns.contains(name)) {
          columns.add(name);
        }
      }
    }
    final orderSql = [
      for (final order in resolved.effectiveOrders)
        '${_orderSqlName(entry, order.name)} '
            '${order.descending ? 'DESC' : 'ASC'}',
    ].join(', ');
    final inner =
        'SELECT ${columns.isEmpty ? '1' : columns.join(', ')} '
        'FROM ${entry.table}$where ORDER BY $orderSql LIMIT ?';
    args.add(limit);
    sql = 'SELECT ${selectParts.join(', ')} FROM ($inner)';
  } else {
    sql = 'SELECT ${selectParts.join(', ')} FROM ${entry.table}$where';
  }
  return PlannedAggregate(
    sql: sql,
    args: args,
    servingIndex: resolved.servingIndex,
  );
}

/// Builds the SQL for a group-by query: one statement computing the keys and
/// every requested aggregate per group, ordered by the keys ascending (null
/// keys first), optionally capped with `LIMIT ?`. Pure function over the
/// registry entry.
///
/// Throws the same [MissingIndexException] [planQuery] throws — the filters
/// follow the query index rule — and [ArgumentError] for empty or oversized
/// key/function lists.
PlannedAggregate planGroupAggregate({
  required RegistryEntry entry,
  required CollectionPath? scopePath,
  required List<QueryFilter> filters,
  required List<QueryOrder> orders,
  required int? limit,
  required bool fullScan,
  required List<GroupKeySpec<Object?, Object?>> keys,
  required List<AggregateFunction<Object?>> specs,
  MissingIndexScanDecision? onMissingIndex,
}) {
  if (keys.isEmpty) {
    throw ArgumentError.value(keys, 'keys', 'Needs at least one key');
  }
  if (keys.length > maxGroupKeys) {
    throw ArgumentError.value(
      keys.length,
      'keys',
      'At most $maxGroupKeys keys per group-by query',
    );
  }
  if (specs.isEmpty) {
    throw ArgumentError.value(
      specs,
      'specs',
      'Needs at least one aggregate function',
    );
  }
  if (specs.length > maxAggregatesPerCall) {
    throw ArgumentError.value(
      specs.length,
      'specs',
      'At most $maxAggregatesPerCall aggregations per call',
    );
  }
  final resolved = resolveQueryFilters(
    entry: entry,
    scopePath: scopePath,
    filters: filters,
    orders: orders,
    fullScan: fullScan,
    onMissingIndex: onMissingIndex,
  );
  final where = resolved.whereFragments.isEmpty
      ? ''
      : ' WHERE ${resolved.whereFragments.join(' AND ')}';
  final selectParts = <String>[];
  final keyAliases = <String>[];
  final keyArgs = <Object?>[];
  for (var i = 0; i < keys.length; i++) {
    final (expr, args) = _keySql(keys[i], entry);
    final alias = 'k$i';
    selectParts.add('$expr AS $alias');
    keyAliases.add(alias);
    keyArgs.addAll(args);
  }
  selectParts.add('count(*) AS c');
  for (var i = 0; i < specs.length; i++) {
    final fragment = _aggregateSelectSql(specs[i], entry, 'a$i');
    if (fragment.isNotEmpty) {
      selectParts.add(fragment);
    }
  }
  var sql =
      'SELECT ${selectParts.join(', ')} FROM ${entry.table}$where '
      'GROUP BY ${keyAliases.join(', ')} '
      'ORDER BY ${keyAliases.map((alias) => '$alias ASC').join(', ')}';
  // Placeholder order follows the SQL text: the key expressions sit in the
  // SELECT list, ahead of the WHERE clause.
  final args = <Object?>[...keyArgs, ...resolved.whereArgs];
  if (limit != null) {
    sql = '$sql LIMIT ?';
    args.add(limit);
  }
  return PlannedAggregate(
    sql: sql,
    args: args,
    servingIndex: resolved.servingIndex,
  );
}

/// The SELECT fragment of one aggregate function, bound under [alias].
/// `count(*)` is not re-emitted: the statement always computes `count(*)`
/// under `c`, and a [CountAggregate] reads that.
String _aggregateSelectSql(
  AggregateFunction<Object?> spec,
  RegistryEntry entry,
  String alias,
) => switch (spec) {
  CountAggregate() => '',
  SumAggregate(:final column) =>
    'COALESCE(SUM(${_numericColumnName(column, spec, entry)}), '
        '${column.type == ColumnType.integer ? 0 : 0.0}) AS $alias',
  AverageAggregate(:final column) =>
    'AVG(${_numericColumnName(column, spec, entry)}) AS $alias',
  MinAggregate(:final column) =>
    'MIN(${_mirroredColumnName(column, entry)}) AS $alias',
  MaxAggregate(:final column) =>
    'MAX(${_mirroredColumnName(column, entry)}) AS $alias',
};

/// The SQL column of a mirrored field, after checking it IS mirrored and
/// numeric for [spec].
String _numericColumnName(
  FieldColumn<Object?, Object?> column,
  AggregateFunction<Object?> spec,
  RegistryEntry entry,
) {
  if (column.type != ColumnType.integer && column.type != ColumnType.real) {
    throw ArgumentError.value(
      column.name,
      'column',
      '${spec.label} needs a numeric (int/double) field',
    );
  }
  return _mirroredColumnName(column, entry);
}

/// The SQL column of a mirrored field, throwing an
/// [UnmirroredFieldException] for a field without an `f_` column: aggregates
/// run in SQLite, which reads only the mirrored columns, never the document
/// blob. The error names both fixes: `@Mirrored()` on the field for totals
/// and groups, an `Index([...])` when the query also filters or sorts on it.
String _mirroredColumnName(
  FieldColumn<Object?, Object?> column,
  RegistryEntry entry,
) {
  final mirrored = entry.fieldColumns.any(
    (declared) => declared.name == column.name,
  );
  if (!mirrored) {
    final declaration =
        "@Mirrored() on the field, or Index(['${column.name}']) on its "
        '@Collection declaration';
    throw UnmirroredFieldException(
      'Field "${column.name}" of ${entry.adapter.model} '
      '(${entry.adapter.pattern}) is not mirrored into a column: only '
      'indexed and @Mirrored fields are copied into f_ columns, and '
      'aggregates read columns, never the document blob. Add $declaration '
      "to mirror it (or the FieldColumn to a hand-written adapter's "
      'columns), or read the documents and aggregate in Dart.',
      suggestedDeclaration: declaration,
    );
  }
  return fieldColumnName(column.name);
}

/// The SELECT/GROUP BY fragment of one group key, with its bound arguments.
(String, List<Object?>) _keySql(
  GroupKeySpec<Object?, Object?> key,
  RegistryEntry entry,
) => switch (key) {
  FieldKey(:final column) => (_mirroredColumnName(column, entry), const []),
  ParamKey(:final column) => (_paramKeyName(column, entry), const []),
  BucketKey(:final column, :final width) => _bucketSql(column, width, entry),
  CalendarKey(:final column, :final period, :final utcOffset) => _calendarSql(
    column,
    period,
    utcOffset,
    entry,
  ),
};

/// The SQL column of a path param key, after checking the param belongs to
/// this collection's pattern.
String _paramKeyName(ParamColumn column, RegistryEntry entry) {
  if (column.pattern != entry.adapter.pattern) {
    throw ArgumentError.value(
      column.name,
      'column',
      'paramKey needs a path param of ${entry.adapter.pattern}',
    );
  }
  return column.sqlName;
}

/// The SQL expression of a [bucket] key: exact integer floor-mod arithmetic
/// for an integer field with an integer width (value - floorMod(value,
/// width) = floor(value / width) * width, no floating point), `FLOOR`
/// division for double fields.
(String, List<Object?>) _bucketSql(
  FieldColumn<Object?, Object?> column,
  num width,
  RegistryEntry entry,
) {
  if (width <= 0) {
    throw ArgumentError.value(width, 'width', 'Must be positive');
  }
  final name = _mirroredColumnName(column, entry);
  if (column.type == ColumnType.integer && width is int) {
    final expr = '($name - ((($name % ?) + ?) % ?))';
    return (expr, [width, width, width]);
  }
  if (column.type == ColumnType.real) {
    // The column identifier is inlined (never a bound parameter); only the
    // width is bound.
    final expr = 'FLOOR($name / ?) * ?';
    return (expr, [width, width]);
  }
  throw ArgumentError.value(
    width,
    'width',
    'A fractional width on integer field "${column.name}" would produce '
        'double keys; use an integer width',
  );
}

/// The SQL expression of a [year]/[month]/[day] key: shift the stored UTC
/// microseconds by the fixed offset, take the containing UTC day with exact
/// integer floor division (no floating point, correct before 1970), and read
/// the calendar off the local midnight — so `+08:00` moves a 23:30 UTC
/// instant into the next local day.
(String, List<Object?>) _calendarSql(
  FieldColumn<Object?, Object?> column,
  CalendarPeriod period,
  Duration utcOffset,
  RegistryEntry entry,
) {
  if (column.type != ColumnType.integer) {
    throw ArgumentError.value(
      column.name,
      'column',
      'Calendar keys need a DateTime field',
    );
  }
  final name = _mirroredColumnName(column, entry);
  // floorDiv(micros + offset, 86400000000) * 86400 = the local midnight's
  // UTC seconds; date(.., 'unixepoch') reads its calendar date.
  const dayMicros = 86400000000;
  final shifted = '($name + ?)';
  final daySeconds =
      '((($shifted - ((($shifted % $dayMicros) + $dayMicros) '
      '% $dayMicros)) / $dayMicros) * 86400)';
  final format = switch (period) {
    CalendarPeriod.year => '%Y',
    CalendarPeriod.month => '%Y%m',
    CalendarPeriod.day => '%Y%m%d',
  };
  final offsetMicros = utcOffset.inMicroseconds;
  final expr =
      "CAST(strftime('$format', date($daySeconds, 'unixepoch')) "
      'AS INTEGER)';
  return (expr, [offsetMicros, offsetMicros]);
}

/// Converts one aggregate SELECT row into an [AggregateQuerySnapshot]: the
/// `c` column is the count, `a<i>` the value of specs[i].
@internal
AggregateQuerySnapshot<S> aggregateSnapshotFromRow<S extends Object>(
  List<AggregateFunction<S>> specs,
  Map<String, Object?> row,
) {
  final values = <Object?>[
    for (var i = 0; i < specs.length; i++) _aggregateValueOf(specs[i], row, i),
  ];
  return AggregateQuerySnapshot<S>(specs, values, row['c']! as int);
}

/// Converts group-by SELECT rows into [AggregateGroup]s: `k<i>` is key[i]'s
/// value, `c` the group's document count, `a<i>` the value of specs[i].
@internal
List<AggregateGroup<S>> aggregateGroupsFromRows<S extends Object>(
  List<GroupKeySpec<S, Object?>> keys,
  List<AggregateFunction<S>> specs,
  List<Map<String, Object?>> rows,
) => [
  for (final row in rows)
    AggregateGroup<S>(
      keys,
      [for (var i = 0; i < keys.length; i++) _keyValueOf(keys[i], row['k$i'])],
      specs,
      [
        for (var i = 0; i < specs.length; i++)
          _aggregateValueOf(specs[i], row, i),
      ],
      row['c']! as int,
    ),
];

/// The Dart value of one aggregate column: counts and integer sums are
/// `int`s, double sums `double`s, averages `double?`, and min/max values are
/// converted back to the field's type by its own `fromSql`.
Object? _aggregateValueOf(
  AggregateFunction<Object?> spec,
  Map<String, Object?> row,
  int index,
) => switch (spec) {
  CountAggregate() => row['c'],
  SumAggregate() => row['a$index'],
  AverageAggregate() => (row['a$index'] as num?)?.toDouble(),
  MinAggregate(:final column) || MaxAggregate(:final column) =>
    row['a$index'] == null ? null : column.fromSql(row['a$index']),
};

/// The Dart value of one group key column, converted back to the key's type.
Object? _keyValueOf(GroupKeySpec<Object?, Object?> key, Object? raw) =>
    switch (key) {
      FieldKey(:final column) => raw == null ? null : column.fromSql(raw),
      ParamKey() => raw as String?,
      BucketKey(:final column, :final width) =>
        column.type == ColumnType.integer && width is int
            ? raw as int?
            : (raw as num?)?.toDouble(),
      CalendarKey() => raw as int?,
    };

/// The first index that can serve the query: `null` when none does and the
/// query may run as a full scan (`.allowFullScan()`, or the debug
/// scanAndWarn fallback accepted it), otherwise the serving index.
///
/// Throws a [MissingIndexException] when no index serves the query and the
/// fallback did not accept a scan: the message ends with a `Fix:` line naming
/// the `dart run cocoon_generator:index add` command whenever there is
/// something to declare.
IndexPlan? _servingIndexOrNull(
  RegistryEntry entry,
  List<QueryFilter> allFilters,
  Set<String> equalityNames,
  Set<String> rangeNames,
  List<QueryOrder> orders,
  List<QueryOrder> effectiveOrders,
  MissingIndexScanDecision? onMissingIndex,
) {
  final target = '${entry.adapter.model} (${entry.adapter.pattern})';
  if (rangeNames.length > 1) {
    throw MissingIndexException(
      'Queries can use at most one range filter, but this query on $target '
      'range-filters ${rangeNames.join(' and ')}.',
    );
  }
  final rangeName = rangeNames.isEmpty ? null : rangeNames.single;
  final serving = indexServingQuery(
    indexes: entry.indexPlans,
    equalityNames: equalityNames,
    rangeName: rangeName,
    hasUserOrder: orders.isNotEmpty,
    orders: effectiveOrders,
  );
  if (serving != null) {
    return serving;
  }
  final equalityInOrder = <String>[];
  final seen = <String>{};
  for (final filter in allFilters) {
    if (filter.isEqualityClass && seen.add(filter.name)) {
      equalityInOrder.add(filter.name);
    }
  }
  final parts = suggestedIndexParts(
    equalityNamesInOrder: equalityInOrder,
    rangeName: rangeName,
    hasUserOrder: orders.isNotEmpty,
    orders: orders,
  );
  if (parts == null) {
    throw MissingIndexException(
      'No index serves this query on $target, and it has no filters or '
      'sort keys to anchor one. Call .allowFullScan() to read it anyway.',
    );
  }
  final suggestion = indexDeclaration(parts);
  final fixCommand = indexFixCommand(entry.adapter.model, parts);
  final error = MissingIndexException(
    'No index serves this query on $target. Add ${indexDeclaration(parts)} '
    "to its @Collection(indexes: [...]), or call .allowFullScan() to read "
    'it anyway.\n'
    'Fix: $fixCommand (writes ${indexFixDeclaration(parts, entry.paramNames.toSet())})',
    suggestedIndex: suggestion,
    fixCommand: fixCommand,
  );
  if (onMissingIndex != null &&
      onMissingIndex(
        error,
        model: entry.adapter.model,
        fields: List.unmodifiable(parts),
        queryShape: missingIndexQueryShape(allFilters, orders),
      )) {
    return null;
  }
  throw error;
}

/// The query's shape for a [MissingIndexReport]: filter names and operators,
/// then the sort keys — never the bound values.
String missingIndexQueryShape(
  List<QueryFilter> filters,
  List<QueryOrder> orders,
) {
  final shape = <String>[];
  if (filters.isNotEmpty) {
    shape.add(
      'where ${[for (final f in filters) '${f.name} ${_opSymbol(f.op)}'].join(', ')}',
    );
  }
  if (orders.isNotEmpty) {
    shape.add('orderBy ${orders.join(', ')}');
  }
  return shape.join('; ');
}

String _opSymbol(FilterOp op) => switch (op) {
  FilterOp.equal => '==',
  FilterOp.notEqual => '!=',
  FilterOp.less => '<',
  FilterOp.lessEqual => '<=',
  FilterOp.greater => '>',
  FilterOp.greaterEqual => '>=',
  FilterOp.inList => 'IN',
  FilterOp.isNull => 'IS NULL',
  FilterOp.isNotNull => 'IS NOT NULL',
};

String _selectSql(RegistryEntry entry, List<QueryOrder> orders) {
  // The param columns travel with every page so a row can be turned back
  // into a DocRef — its full path is derived from the params and the id,
  // which is also every row's stored identity (the scope key).
  final columns = <String>[
    'id',
    'data',
    ...entry.paramSqlNames,
    ..._cursorColumns(entry, orders),
  ];
  return 'SELECT ${columns.join(', ')} FROM ${entry.table}';
}

List<String> _cursorColumns(RegistryEntry entry, List<QueryOrder> orders) {
  final columns = <String>[];
  for (final order in orders) {
    if (order.name == 'id') {
      continue; // already selected
    }
    final sqlName = _orderSqlName(entry, order.name);
    if (!columns.contains(sqlName) && !entry.paramSqlNames.contains(sqlName)) {
      columns.add(sqlName);
    }
  }
  return columns;
}

String _orderSqlName(RegistryEntry entry, String name) {
  if (name == 'id') {
    return 'id';
  }
  return entry.sqlNameOf(name);
}

String _filterSql(QueryFilter filter) => switch (filter.op) {
  FilterOp.equal => '${filter.sqlName} = ?',
  FilterOp.notEqual => '${filter.sqlName} != ?',
  FilterOp.less => '${filter.sqlName} < ?',
  FilterOp.lessEqual => '${filter.sqlName} <= ?',
  FilterOp.greater => '${filter.sqlName} > ?',
  FilterOp.greaterEqual => '${filter.sqlName} >= ?',
  FilterOp.inList =>
    '${filter.sqlName} IN '
        '(${List.filled(filter.sqlValues.length, '?').join(', ')})',
  FilterOp.isNull => '${filter.sqlName} IS NULL',
  FilterOp.isNotNull => '${filter.sqlName} IS NOT NULL',
};

/// The keyset predicate for the next page: a row-value comparison when all
/// sort parts share a direction, otherwise the expanded OR form. The cursor
/// keys are appended to [args] in placeholder order.
String _keysetSql(
  RegistryEntry entry,
  List<QueryOrder> orders,
  List<Object> keys,
  List<Object?> args,
) {
  final names = [for (final order in orders) _orderSqlName(entry, order.name)];
  final sameDirection = orders.every(
    (order) => order.descending == orders.first.descending,
  );
  if (sameDirection) {
    final operator = orders.first.descending ? '<' : '>';
    args.addAll(keys);
    return '(${names.join(', ')}) $operator '
        '(${List.filled(names.length, '?').join(', ')})';
  }
  final orParts = <String>[];
  for (var i = 0; i < names.length; i++) {
    final conditions = <String>[
      for (var j = 0; j < i; j++) '${names[j]} = ?',
      '${names[i]} ${orders[i].descending ? '<' : '>'} ?',
    ];
    orParts.add('(${conditions.join(' AND ')})');
    for (var j = 0; j <= i; j++) {
      args.add(keys[j]);
    }
  }
  return orParts.join(' OR ');
}

/// Canonical query description behind the cursor fingerprint: table, parent
/// scope, filters including their values and sort order — limit excluded, so
/// cursors can be reused across page sizes.
String _fingerprint(
  RegistryEntry entry,
  CollectionPath? scopePath,
  List<QueryFilter> filters,
  List<QueryOrder> orders,
) {
  final description = [
    'v1',
    entry.table,
    scopePath == null ? 'group' : 'scope:${scopePath.path}',
    for (final filter in filters)
      '${filter.name}:${filter.op.name}:${jsonEncode(filter.sqlValues)}',
    for (final order in orders)
      '${order.name}:${order.descending ? 'desc' : 'asc'}',
  ].join('|');
  return queryFingerprint(description);
}

Map<String, String> _scopeParamValues(
  RegistryEntry entry,
  CollectionPath path,
) {
  final patternSegments = entry.adapter.pattern.pattern.split('/');
  final pathSegments = path.path.split('/');
  final values = <String, String>{};
  for (var i = 1; i < patternSegments.length; i += 2) {
    final name = patternSegments[i].substring(1, patternSegments[i].length - 1);
    values[name] = pathSegments[i];
  }
  return values;
}

bool _listEquals<T>(List<T> a, List<T> b) {
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

/// One page of query results.
final class QueryPage<T extends Object> {
  /// Builds a page; the engine assembles pages, queries return them.
  @internal
  const QueryPage(this.docs, this.nextCursor);

  /// The documents of this page, in query order.
  final List<DocSnapshot<T>> docs;

  /// Opaque cursor for the next page, or `null` when this was the last page.
  final String? nextCursor;
}

/// The engine-facing view of a [CocoonQuery]: everything needed to plan and
/// run it, without exposing the builder's private state.
final class QuerySpec<T extends Object> {
  const QuerySpec({
    required this.adapter,
    required this.scopePath,
    required this.filters,
    required this.orders,
    required this.limit,
    required this.startAfter,
    required this.fullScan,
  });

  /// The collection adapter the query runs against.
  final CollectionAdapter<T> adapter;

  /// The concrete parent collection, or `null` for a collection-group query.
  final CollectionPath? scopePath;

  /// The filters, in the order they were added.
  final List<QueryFilter> filters;

  /// The sort keys, in the order they were added (without the id
  /// tiebreaker, which the planner appends).
  final List<QueryOrder> orders;

  /// The page size, or `null` for unpaginated queries.
  final int? limit;

  /// The opaque cursor to continue after, or `null` for a first page.
  final String? startAfter;

  /// Whether the index requirement is opted out.
  final bool fullScan;
}

/// An immutable query over one collection: filters, sort order, limit,
/// cursor and the full-scan opt-out. Every builder method returns a new
/// query; the original is untouched.
///
/// ```dart
/// final q = a1.collection(txns)
///     .where(txnBookedOn.isGreaterThanOrEqualTo(20260101))
///     .orderBy(txnBookedOn, descending: true)
///     .limit(50);
/// final page = await q.get();
/// final next = page.nextCursor == null
///     ? null
///     : await q.startAfter(page.nextCursor!).get();
/// ```
final class CocoonQuery<T extends Object> {
  @internal
  CocoonQuery(
    this._db,
    this._adapter,
    this._scopePath, {
    List<QueryFilter> filters = const [],
    List<QueryOrder> orders = const [],
    int? limit,
    String? startAfter,
    bool fullScan = false,
  }) : _filters = List.unmodifiable(filters),
       _orders = List.unmodifiable(orders),
       _limit = limit,
       _startAfter = startAfter,
       _fullScan = fullScan;

  final Cocoon _db;
  final CollectionAdapter<T> _adapter;

  /// The concrete parent collection, or `null` for a collection-group query.
  final CollectionPath? _scopePath;
  final List<QueryFilter> _filters;
  final List<QueryOrder> _orders;
  final int? _limit;
  final String? _startAfter;
  final bool _fullScan;

  /// Adds a filter built from a [FieldColumn] or [ParamColumn] handle.
  CocoonQuery<T> where(QueryFilter filter) {
    _validateName(filter.name, 'filter');
    return _copy(filters: [..._filters, filter]);
  }

  /// Sorts by [column], ascending unless [descending]. The document id is
  /// always appended as the final tiebreaker. Ordering by a nullable column
  /// throws: sort keys are never null.
  CocoonQuery<T> orderBy(
    FieldColumn<T, Object?> column, {
    bool descending = false,
  }) {
    if (column.type == ColumnType.blob) {
      throw ArgumentError.value(
        column.name,
        'column',
        'Blob columns cannot be sorted',
      );
    }
    if (column.nullable) {
      throw ArgumentError.value(
        column.name,
        'column',
        'Ordering by a nullable column is not supported: sort keys are '
            'never null',
      );
    }
    _validateName(column.name, 'sort key');
    if (_orders.any((order) => order.name == column.name)) {
      throw ArgumentError.value(
        column.name,
        'column',
        'The query is already ordered by this column',
      );
    }
    return _copy(
      orders: [
        ..._orders,
        QueryOrder(column.name, descending: descending),
      ],
    );
  }

  /// Caps the page size. `get()` fetches one extra row to detect the next
  /// page, so [QueryPage.nextCursor] is accurate.
  CocoonQuery<T> limit(int maxRows) {
    if (maxRows < 1) {
      throw ArgumentError.value(maxRows, 'maxRows', 'Must be at least 1');
    }
    return _copy(limit: maxRows);
  }

  /// Continues after an opaque cursor from a previous page of this query.
  /// A cursor from a different query is rejected with
  /// [CursorMismatchException].
  CocoonQuery<T> startAfter(String cursor) => _copy(startAfter: cursor);

  /// Opts this query out of the index requirement: results are read without
  /// an index guarantee. Use sparingly; every other query throws a
  /// [MissingIndexException] unless a declared index serves it.
  CocoonQuery<T> allowFullScan() => _copy(fullScan: true);

  /// Runs the query and returns one page.
  Future<QueryPage<T>> get() => _db.runQuery(this);

  /// Watches the query.
  ///
  /// The stream starts work on the first listen and stops when the last
  /// listener cancels (the watcher unregisters; re-listening restarts it).
  /// It emits the current page on listen, then re-runs the query only when a
  /// committed transaction touched the query's collection — and, for
  /// subcollection queries, a path inside the parent scope; writes to other
  /// tables or other parents never re-run it. Re-runs are coalesced: commits
  /// landing while a re-run is in flight cause at most one more re-run. A
  /// page whose document paths and canonical bytes equal the previous page
  /// is not emitted. Closing the database completes the stream.
  Stream<QueryPage<T>> watch() => _db.watchQuery(this);

  /// Watches an anchored live range: rows from [cursor] onward, up to the
  /// query's limit, with the anchor fixed at [cursor] (pass `null` to anchor
  /// at the very start of the query).
  ///
  /// The anchor never moves, so rows inserted before it don't shift the
  /// window — this is how live paginated lists avoid shifting pages: anchor
  /// the window on the previous page's `nextCursor` and keep it there, while
  /// `nextCursor` from the emissions still pages further on demand. Beyond
  /// that, [watchFrom] behaves exactly like [watch] (coalescing, byte
  /// deduplication, lifecycle).
  Stream<QueryPage<T>> watchFrom(String? cursor) =>
      (cursor == null ? this : startAfter(cursor)).watch();

  /// Counts the matching documents, under the same index rule as [get].
  /// Sugar for `aggregate([count()])` — one `SELECT count(*)` statement.
  Future<int> count() => _db.runCount(this);

  /// Computes aggregates over this query's results in one SQLite statement:
  /// Firestore's [count]/[sum]/[average], plus Cocoon's [min]/[max].
  ///
  /// ```dart
  /// final snapshot = await a1.collection(txns)
  ///     .where(txnBookedOn.isGreaterThanOrEqualTo(20260101))
  ///     .aggregate([count(), sum(txnAmountMinor), average(txnAmountMinor)])
  ///     .get();
  /// print(snapshot.count); // documents matched
  /// print(snapshot.getSum(txnAmountMinor)); // int, nulls skipped
  /// ```
  ///
  /// The filters follow the same index rule as [get] (a
  /// [MissingIndexException] names the `Index([...])` to declare;
  /// `.allowFullScan()` opts out). An `orderBy` + `limit` on this query
  /// aggregate the first [limit] documents in that order; without a limit
  /// the sort order is irrelevant and dropped from the SQL. A `startAfter`
  /// cursor is ignored: aggregates always run over the whole filtered set.
  /// Nulls are skipped by [sum]/[average]/[min]/[max] and counted by
  /// [count]. At most [maxAggregatesPerCall] functions per call, like
  /// Firestore. Only mirrored fields can be aggregated — an `Index([...])`
  /// member or a `@Mirrored()` field; anything else throws an
  /// [UnmirroredFieldException] naming the declaration that would mirror it.
  AggregateQuery<T> aggregate(List<AggregateFunction<T>> specs) {
    if (specs.isEmpty) {
      throw ArgumentError.value(
        specs,
        'specs',
        'Needs at least one aggregate function',
      );
    }
    if (specs.length > maxAggregatesPerCall) {
      throw ArgumentError.value(
        specs.length,
        'specs',
        'At most $maxAggregatesPerCall aggregations per call',
      );
    }
    return AggregateQuery<T>(this, List.unmodifiable(specs));
  }

  /// Starts a group-by query (a Cocoon extension, not in Firestore):
  /// buckets this query's results by [keys] and aggregates per group.
  ///
  /// ```dart
  /// final currencyKey = key(txnCurrency);
  /// final groups = await a1.collection(txns)
  ///     .groupBy([currencyKey, bucket(txnBookedOn, width: 100)])
  ///     .aggregate([sum(txnAmountMinor), count()])
  ///     .get();
  /// for (final group in groups) {
  ///   print('${group.key(currencyKey)}: ${group.getSum(txnAmountMinor)}');
  /// }
  /// ```
  ///
  /// Key kinds: [key] (a field's own value), [paramKey] (a path param, so a
  /// collection-group query can group one aggregate per parent), [bucket]
  /// (fixed-width numeric bands) and [year]/[month]/[day] (calendar buckets
  /// on `DateTime` fields at a fixed `utcOffset` — see their dartdoc for
  /// the DST rule). At most [maxGroupKeys] keys; up to
  /// [maxAggregatesPerCall] functions per `.aggregate` call; groups come
  /// ordered by the keys ascending, null keys first. The filters follow the
  /// same index rule as [get].
  GroupByQuery<T> groupBy(List<GroupKeySpec<T, Object?>> keys) {
    if (keys.isEmpty) {
      throw ArgumentError.value(keys, 'keys', 'Needs at least one key');
    }
    if (keys.length > maxGroupKeys) {
      throw ArgumentError.value(
        keys.length,
        'keys',
        'At most $maxGroupKeys keys per group-by query',
      );
    }
    return GroupByQuery<T>._(this, List.unmodifiable(keys));
  }

  /// The engine-facing view of this query.
  @internal
  QuerySpec<T> get spec => QuerySpec<T>(
    adapter: _adapter,
    scopePath: _scopePath,
    filters: _filters,
    orders: _orders,
    limit: _limit,
    startAfter: _startAfter,
    fullScan: _fullScan,
  );

  CocoonQuery<T> _copy({
    List<QueryFilter>? filters,
    List<QueryOrder>? orders,
    int? limit,
    String? startAfter,
    bool? fullScan,
  }) => CocoonQuery(
    _db,
    _adapter,
    _scopePath,
    filters: filters ?? _filters,
    orders: orders ?? _orders,
    limit: limit ?? _limit,
    startAfter: startAfter ?? _startAfter,
    fullScan: fullScan ?? _fullScan,
  );

  void _validateName(String name, String kind) {
    final known = <String>{for (final column in _adapter.columns) column.name};
    known.addAll(_adapter.pattern.params);
    if (!known.contains(name)) {
      throw ArgumentError.value(
        name,
        kind,
        'Unknown field or path param for collection ${_adapter.pattern}',
      );
    }
  }
}

/// An aggregate query: computes the requested [count]/[sum]/[average]/
/// [min]/[max] over a [CocoonQuery]'s results in one SQLite statement —
/// Firestore's aggregate queries, pushdown included. Build with
/// [CocoonQuery.aggregate].
///
/// ```dart
/// final snapshot = await a1.collection(txns)
///     .aggregate([count(), sum(txnAmountMinor)])
///     .get();
/// print('${snapshot.count} documents, ${snapshot.getSum(txnAmountMinor)} total');
/// ```
final class AggregateQuery<T extends Object> {
  @internal
  AggregateQuery(this.query, this.specs);

  /// The query whose filters (and, with a limit, the first-N window) shape
  /// the aggregation.
  final CocoonQuery<T> query;

  /// The requested aggregate functions.
  final List<AggregateFunction<T>> specs;

  /// Runs the aggregation: one statement, no documents decoded.
  Future<AggregateQuerySnapshot<T>> get() => _db.runAggregate(this);

  /// Watches the aggregates.
  ///
  /// The stream starts work on the first listen and stops when the last
  /// listener cancels (the watcher unregisters; re-listening restarts it).
  /// It emits the current snapshot on listen, then re-runs only when a
  /// committed transaction touched this query's collection — and, for
  /// subcollection queries, a path inside the parent scope; writes to other
  /// tables or other parents never re-run it. Re-runs are coalesced like a
  /// query watch's, and a snapshot whose values equal the previous one is
  /// not emitted. Closing the database completes the stream.
  Stream<AggregateQuerySnapshot<T>> watch() => _db.watchAggregate(this);

  Cocoon get _db => query._db;
}

/// The builder a [CocoonQuery.groupBy] call returns: the group keys, ready
/// for `.aggregate([...])` (and an optional `.limit()` on groups).
final class GroupByQuery<T extends Object> {
  GroupByQuery._(this._query, this._keys);

  final CocoonQuery<T> _query;
  final List<GroupKeySpec<T, Object?>> _keys;

  /// Caps how many groups come back: the first [maxGroups] in key order.
  GroupByQuery<T> limit(int maxGroups) {
    _requirePositiveLimit(maxGroups);
    return GroupByQuery<T>._(_query, _keys).._limit = maxGroups;
  }

  /// Requests the aggregates each group carries — the same functions as
  /// [CocoonQuery.aggregate]. At most [maxAggregatesPerCall] per call.
  AggregateGroupQuery<T> aggregate(List<AggregateFunction<T>> specs) {
    if (specs.isEmpty) {
      throw ArgumentError.value(
        specs,
        'specs',
        'Needs at least one aggregate function',
      );
    }
    if (specs.length > maxAggregatesPerCall) {
      throw ArgumentError.value(
        specs.length,
        'specs',
        'At most $maxAggregatesPerCall aggregations per call',
      );
    }
    return AggregateGroupQuery<T>._(
      _query,
      _keys,
      _limit,
      List.unmodifiable(specs),
    );
  }

  int? _limit;
}

/// A group-by query ready to run: the keys, the requested aggregates and an
/// optional group cap. Build with [CocoonQuery.groupBy] and
/// [GroupByQuery.aggregate].
///
/// ```dart
/// final groups = await a1.collection(txns)
///     .groupBy([bucket(txnBookedOn, width: 100)])
///     .aggregate([sum(txnAmountMinor), count()])
///     .get();
/// ```
final class AggregateGroupQuery<T extends Object> {
  AggregateGroupQuery._(this.query, this.keys, this.maxGroups, this.specs);

  /// The query whose filters shape the groups.
  @internal
  final CocoonQuery<T> query;

  /// The group keys, in the order they were given.
  @internal
  final List<GroupKeySpec<T, Object?>> keys;

  /// The group cap, or `null` for every group.
  @internal
  final int? maxGroups;

  /// The requested aggregate functions.
  @internal
  final List<AggregateFunction<T>> specs;

  /// Caps how many groups come back: the first [maxGroups] in key order.
  AggregateGroupQuery<T> limit(int maxGroups) {
    _requirePositiveLimit(maxGroups);
    return AggregateGroupQuery<T>._(query, keys, maxGroups, specs);
  }

  /// Runs the group-by: one statement, no documents decoded. Groups come
  /// ordered by the keys ascending; groups whose key values are null sort
  /// first.
  Future<List<AggregateGroup<T>>> get() => _db.runGroupAggregate(this);

  /// Watches the groups.
  ///
  /// Behaves like [AggregateQuery.watch] — first emission on listen,
  /// table-(and scope-)scoped re-runs, coalescing, and no re-emission while
  /// the group list is equal to the previous one (same keys, same counts,
  /// same values).
  Stream<List<AggregateGroup<T>>> watch() => _db.watchGroupAggregate(this);

  Cocoon get _db => query._db;
}

void _requirePositiveLimit(int maxGroups) {
  if (maxGroups < 1) {
    throw ArgumentError.value(maxGroups, 'maxGroups', 'Must be at least 1');
  }
}
