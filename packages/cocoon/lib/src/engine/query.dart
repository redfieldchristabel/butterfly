import 'dart:convert';

import 'package:meta/meta.dart';

import '../cursor.dart';
import '../path.dart';
import 'adapter.dart';
import 'cocoon.dart';
import 'naming.dart';
import 'refs.dart';
import 'schema_sql.dart';

/// Thrown when no declared (or implicit) index can serve a query's filters
/// and sort order.
///
/// The message spells the `Index([...])` to add to the `@Collection`
/// declaration, or points at `.allowFullScan()` when there is nothing to
/// index.
class MissingIndexException implements Exception {
  /// Builds the exception with a human-readable [message] and, when there is
  /// something to declare, the ready-to-paste [suggestedIndex].
  MissingIndexException(this.message, {this.suggestedIndex});

  /// Explains which query failed and how to fix it.
  final String message;

  /// The `Index([...])` declaration that would serve the query, or `null`
  /// when the query has nothing to anchor an index on.
  final String? suggestedIndex;

  @override
  String toString() => 'MissingIndexException: $message';
}

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

/// The `Index([...])` declaration that would serve a query, or `null` when
/// the query has no filters and no sort keys to anchor an index on.
String? suggestedIndexDdl({
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
  return "Index([${parts.map((part) => "'$part'").join(', ')}])";
}

/// The executable form of a planned query: SQL, bound arguments, the cursor
/// fingerprint and the columns cursor keys are read from.
final class PlannedQuery {
  const PlannedQuery({
    required this.sql,
    required this.args,
    required this.countSql,
    required this.countArgs,
    required this.fingerprint,
    required this.cursorColumns,
  });

  /// The page `SELECT`, bound to [args], with `LIMIT ?` when limited.
  final String sql;

  /// Arguments for [sql], in placeholder order.
  final List<Object?> args;

  /// The `SELECT count(*)` statement with the same filters and index rule.
  final String countSql;

  /// Arguments for [countSql].
  final List<Object?> countArgs;

  /// Fingerprint of the canonical query description; cursors carry it and a
  /// cursor from another query is rejected.
  final String fingerprint;

  /// SQL column names the cursor keys are read from, in order-part order.
  final List<String> cursorColumns;
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
  final fingerprint = _fingerprint(entry, scopePath, filters, effectiveOrders);

  if (!fullScan) {
    _checkIndex(
      entry,
      allFilters,
      equalityNames,
      rangeNames,
      orders,
      effectiveOrders,
    );
  }

  final filterWhere = <String>[
    for (final filter in allFilters) _filterSql(filter),
  ];
  final whereArgs = <Object?>[
    for (final filter in allFilters) ...filter.sqlValues,
  ];

  // Keyset predicate for the next page, bound after the filter values. The
  // count statement deliberately never sees it.
  var keysetWhere = '';
  final args = <Object?>[...whereArgs];
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
  var countSql = 'SELECT count(*) AS c FROM ${entry.table}';
  if (filterWhere.isNotEmpty) {
    countSql = '$countSql WHERE ${filterWhere.join(' AND ')}';
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
    countSql: countSql,
    countArgs: [...whereArgs],
    fingerprint: fingerprint,
    cursorColumns: _cursorColumns(entry, effectiveOrders),
  );
}

void _checkIndex(
  RegistryEntry entry,
  List<QueryFilter> allFilters,
  Set<String> equalityNames,
  Set<String> rangeNames,
  List<QueryOrder> orders,
  List<QueryOrder> effectiveOrders,
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
    return;
  }
  final equalityInOrder = <String>[];
  final seen = <String>{};
  for (final filter in allFilters) {
    if (filter.isEqualityClass && seen.add(filter.name)) {
      equalityInOrder.add(filter.name);
    }
  }
  final suggestion = suggestedIndexDdl(
    equalityNamesInOrder: equalityInOrder,
    rangeName: rangeName,
    hasUserOrder: orders.isNotEmpty,
    orders: orders,
  );
  throw MissingIndexException(
    suggestion == null
        ? 'No index serves this query on $target, and it has no filters or '
              'sort keys to anchor one. Call .allowFullScan() to read it anyway.'
        : 'No index serves this query on $target. Add $suggestion to its '
              "@Collection(indexes: [...]), or call .allowFullScan() to read "
              'it anyway.',
    suggestedIndex: suggestion,
  );
}

String _selectSql(RegistryEntry entry, List<QueryOrder> orders) {
  // The param columns travel with every page so a row can be turned back
  // into a DocRef, whatever parent it belongs to.
  final columns = <String>[
    'path',
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

  /// Counts the matching documents (`SELECT count(*)`), under the same index
  /// rule as [get].
  Future<int> count() => _db.runCount(this);

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
