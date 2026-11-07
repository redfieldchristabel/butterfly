import '../cursor.dart';
import '../path.dart';
import 'adapter.dart';
import 'naming.dart';

/// The SQL declaration of one `f_` column mirrored from a model field.
final class ColumnDdl {
  const ColumnDdl({
    required this.name,
    required this.sqlType,
    required this.nullable,
    required this.checkType,
  });

  /// SQL column name, e.g. `f_booked_on`.
  final String name;

  /// SQL type keyword, e.g. `INTEGER`.
  final String sqlType;

  /// Whether SQL `NULL` is allowed.
  final bool nullable;

  /// The `typeof()` value the CHECK constraint enforces (`integer`, `real`,
  /// `text`), or `null` for unchecked blob columns.
  final String? checkType;
}

/// The SQL declaration of one physical index, with the document id appended
/// as the final part.
final class IndexDdl {
  const IndexDdl({
    required this.name,
    required this.parts,
    required this.unique,
    required this.canonical,
  });

  /// Index name, e.g. `cx_txn_1a2b3c4d5e6f7a8b`.
  final String name;

  /// Physical parts: SQL column names with sort directions, id last.
  final List<IndexPartDdl> parts;

  /// Whether the index is created `UNIQUE`.
  final bool unique;

  /// The logical canonical definition the name is fingerprinted from; also
  /// stored in `_cocoon_meta` for diagnostics.
  final String canonical;
}

/// One physical index part: SQL column name plus direction.
final class IndexPartDdl {
  const IndexPartDdl(this.name, {this.descending = false});

  /// SQL column name (`f_booked_on`, `p_account_id` or `id`).
  final String name;

  /// Whether the part is descending.
  final bool descending;
}

/// The physical name of a declared index: `cx_<table>_<8x2 hex>`, where the
/// hex is the fingerprint of the canonical definition.
String indexName(String table, String canonicalIndex) =>
    'cx_${table}_${queryFingerprint(canonicalIndex)}';

/// The name of a table's implicit scope index: `(p_params..., id)`, unique,
/// created together with the table.
String scopeIndexName(String table) => 'cx_${table}_scope';

/// The `CREATE TABLE` statement for one collection.
String createTableSql(
  String table,
  List<String> paramSqlNames,
  List<ColumnDdl> columns,
) {
  final defs = <String>[
    'path TEXT NOT NULL UNIQUE',
    'id TEXT NOT NULL',
    for (final param in paramSqlNames) '$param TEXT NOT NULL',
    'data BLOB NOT NULL',
    for (final column in columns) _columnDef(column),
  ];
  return 'CREATE TABLE IF NOT EXISTS $table (\n  ${defs.join(',\n  ')}\n)';
}

String _columnDef(ColumnDdl column) {
  final parts = <String>[
    column.name,
    column.sqlType,
    if (!column.nullable) 'NOT NULL',
    if (column.checkType != null)
      column.nullable
          ? "CHECK (${column.name} IS NULL OR typeof(${column.name}) = '${column.checkType}')"
          : "CHECK (typeof(${column.name}) = '${column.checkType}')",
  ];
  return parts.join(' ');
}

/// The `CREATE UNIQUE INDEX` for a table's implicit `(p_params..., id)` index.
String createScopeIndexSql(String table, List<String> paramSqlNames) {
  final parts = [...paramSqlNames, 'id'];
  return 'CREATE UNIQUE INDEX IF NOT EXISTS ${scopeIndexName(table)} '
      'ON $table (${parts.join(' ASC, ')} ASC)';
}

/// The `CREATE [UNIQUE] INDEX` statement for a declared index.
String createIndexSql(String table, IndexDdl index) {
  final parts = [
    for (final part in index.parts)
      '${part.name} ${part.descending ? 'DESC' : 'ASC'}',
  ].join(', ');
  return 'CREATE ${index.unique ? 'UNIQUE ' : ''}INDEX IF NOT EXISTS '
      '${index.name} ON $table ($parts)';
}

/// The `ALTER TABLE ADD COLUMN` for a backfilled `f_` column.
///
/// SQLite cannot add a `NOT NULL` column to a table with rows, so backfilled
/// columns are declared nullable and the adapter's non-null invariant is
/// enforced at write time instead.
String alterAddColumnSql(String table, ColumnDdl column) {
  final check = column.checkType == null
      ? ''
      : " CHECK (${column.name} IS NULL OR typeof(${column.name}) = '${column.checkType}')";
  return 'ALTER TABLE $table ADD COLUMN ${column.name} ${column.sqlType}$check';
}

/// The internal metadata table.
String createMetaTableSql() =>
    'CREATE TABLE IF NOT EXISTS $metaTableName '
    '(key TEXT PRIMARY KEY, value TEXT NOT NULL)';

/// The `CREATE TABLE` statement for the internal change log: one row per
/// touched document, appended in the same transaction as every write.
String createChangesTableSql() =>
    'CREATE TABLE IF NOT EXISTS $changesTableName (\n'
    '  seq INTEGER PRIMARY KEY AUTOINCREMENT,\n'
    '  tbl TEXT NOT NULL,\n'
    '  path TEXT NOT NULL,\n'
    "  op TEXT NOT NULL CHECK (op IN ('set','delete')),\n"
    '  at INTEGER NOT NULL\n'
    ')';

/// A stable fingerprint of one table's physical shape (params, columns,
/// declared indexes). Stored in `_cocoon_meta`; when it matches on open, the
/// reconciler does no DDL at all.
String tableShapeHash({
  required String table,
  required List<String> paramSqlNames,
  required List<ColumnDdl> columns,
  required List<String> indexCanonicals,
}) {
  final description = [
    table,
    paramSqlNames.join(','),
    for (final column in columns)
      '${column.name}:${column.sqlType}:${column.nullable ? '?' : '!'}:'
          '${column.checkType ?? '-'}',
    ...indexCanonicals,
  ].join('|');
  return queryFingerprint(description);
}

/// The logical shape of an index as the query planner sees it: model-level
/// names (fields, path params and the trailing document id) with directions.
final class IndexPlan {
  const IndexPlan({
    required this.name,
    required this.parts,
    required this.unique,
  });

  /// Physical index name, for diagnostics.
  final String name;

  /// Logical parts: field/param names plus the trailing `id`.
  final List<IndexPartDdl> parts;

  /// Whether the index is unique.
  final bool unique;
}

/// A validated adapter together with everything derived from it: table name,
/// SQL column names, DDL declarations and the shape hash.
final class RegistryEntry {
  RegistryEntry._({
    required this.adapter,
    required this.table,
    required this.paramNames,
    required this.paramSqlNames,
    required this.fieldColumns,
    required this.columnDdls,
    required this.indexes,
    required this.indexPlans,
    required this.scopeIndex,
    required this.shapeHash,
  });

  /// The registered adapter.
  final CollectionAdapter<Object?> adapter;

  /// The SQL table name.
  final String table;

  /// Pattern param names in path order.
  final List<String> paramNames;

  /// Pattern param SQL column names, parallel to [paramNames].
  final List<String> paramSqlNames;

  /// The adapter's field columns, seen through the `Object?` view.
  final List<FieldColumn<Object?, Object?>> fieldColumns;

  /// The `f_` column declarations, parallel to [fieldColumns].
  final List<ColumnDdl> columnDdls;

  /// Declared indexes in physical form (id appended), without the scope index.
  final List<IndexDdl> indexes;

  /// Logical index shapes for the query planner: the implicit scope index
  /// first, then every declared index.
  final List<IndexPlan> indexPlans;

  /// The implicit `(p_params..., id)` index declaration.
  final IndexDdl scopeIndex;

  /// Fingerprint of the table shape, stored in `_cocoon_meta`.
  final String shapeHash;

  /// The SQL name of a model field or path param of this collection.
  String sqlNameOf(String name) {
    final paramIndex = paramNames.indexOf(name);
    if (paramIndex >= 0) {
      return paramSqlNames[paramIndex];
    }
    return fieldColumnName(name);
  }
}

/// Every registered collection of a `Cocoon` database, with the checks that
/// keep adapters honest: unique models and patterns, known index fields,
/// registered parents, and valid SQL-derived names.
final class SchemaRegistry {
  SchemaRegistry._(this._entries)
    : _byPattern = {for (final entry in _entries) entry.adapter.pattern: entry},
      _byModel = {for (final entry in _entries) entry.adapter.model: entry};

  /// Validates [collections] and builds the registry.
  ///
  /// Throws an [ArgumentError] with a specific message for the first problem
  /// found. Subcollection adapters require their parent collection's adapter
  /// to be registered too.
  factory SchemaRegistry.build(List<CollectionAdapter<Object?>> collections) {
    final entries = <RegistryEntry>[];
    final models = <String>{};
    final patterns = <String>{};
    final tables = <String>{};
    for (final adapter in collections) {
      _validateAdapter(adapter);
      if (!models.add(adapter.model)) {
        throw ArgumentError.value(
          adapter.model,
          'model',
          'Model is registered twice',
        );
      }
      if (!patterns.add(adapter.pattern.pattern)) {
        throw ArgumentError.value(
          adapter.pattern.pattern,
          'pattern',
          'Two models use the same collection path',
        );
      }
      final table = tableNameFor(adapter.model);
      if (!tables.add(table)) {
        throw ArgumentError.value(
          adapter.model,
          'model',
          'Two models map to the same table "$table"',
        );
      }
      entries.add(_buildEntry(adapter, table));
    }
    for (final entry in entries) {
      final parent = entry.adapter.pattern.parent;
      if (parent != null && !_patternsOf(entries).contains(parent)) {
        throw ArgumentError(
          'Collection ${entry.adapter.pattern} is a subcollection, but its '
          'parent collection $parent has no registered adapter',
        );
      }
    }
    return SchemaRegistry._(List.unmodifiable(entries));
  }

  final List<RegistryEntry> _entries;
  final Map<CollectionPattern, RegistryEntry> _byPattern;
  final Map<String, RegistryEntry> _byModel;

  /// All entries, in registration order.
  List<RegistryEntry> get entries => _entries;

  /// The entry for [model], or `null` when no adapter with that model name
  /// was registered.
  RegistryEntry? byModel(String model) => _byModel[model];

  static Iterable<CollectionPattern> _patternsOf(
    Iterable<RegistryEntry> entries,
  ) => entries.map((entry) => entry.adapter.pattern);

  /// The entry for [pattern], or `null` when it is not registered.
  RegistryEntry? byPattern(CollectionPattern pattern) => _byPattern[pattern];

  /// The entry for [adapter], throwing an [ArgumentError] when the adapter
  /// was not registered at open.
  RegistryEntry entryFor(CollectionAdapter<Object?> adapter) {
    final entry = _byPattern[adapter.pattern];
    if (entry == null) {
      throw ArgumentError.value(
        adapter.pattern.pattern,
        'adapter',
        'No adapter for this collection was registered when the database was '
            'opened',
      );
    }
    return entry;
  }

  /// Whether [descendant] is strictly deeper than [ancestor]: the document
  /// collection `ancestor` contains documents of collection `descendant`.
  static bool descendsFrom(
    CollectionPattern descendant,
    CollectionPattern ancestor,
  ) => descendant.pattern.startsWith('${ancestor.pattern}/');

  static void _validateAdapter(CollectionAdapter<Object?> adapter) {
    final pattern = adapter.pattern;
    for (final param in pattern.params) {
      if (!isValidColumnName(param)) {
        throw ArgumentError.value(
          param,
          'param',
          'Param of ${pattern.pattern} must match ${validNamePattern.pattern}',
        );
      }
    }
    final fieldNames = <String>{};
    final fieldSqlNames = <String>{};
    for (final column in adapter.columns) {
      if (!isValidColumnName(column.name)) {
        throw ArgumentError.value(
          column.name,
          'column',
          'Field name of ${adapter.model} must match ${validNamePattern.pattern}',
        );
      }
      if (pattern.params.contains(column.name)) {
        throw ArgumentError.value(
          column.name,
          'column',
          'Field of ${adapter.model} shadows the path param {${column.name}}',
        );
      }
      if (!fieldNames.add(column.name)) {
        throw ArgumentError.value(
          column.name,
          'column',
          'Duplicate field in ${adapter.model}',
        );
      }
      final sqlName = fieldColumnName(column.name);
      if (!fieldSqlNames.add(sqlName)) {
        throw ArgumentError.value(
          column.name,
          'column',
          'Two fields of ${adapter.model} map to the same column "$sqlName"',
        );
      }
    }
    for (final index in adapter.indexes) {
      if (index.parts.isEmpty) {
        throw ArgumentError.value(
          adapter.model,
          'model',
          'Empty index declared',
        );
      }
      final seen = <String>{};
      for (final part in index.parts) {
        final known =
            fieldNames.contains(part.name) ||
            pattern.params.contains(part.name);
        if (!known) {
          throw ArgumentError.value(
            part.name,
            'index part',
            'Index of ${adapter.model} references unknown field or param',
          );
        }
        if (!seen.add(part.name)) {
          throw ArgumentError.value(
            part.name,
            'index part',
            'Index of ${adapter.model} lists the same name twice',
          );
        }
      }
    }
  }

  static RegistryEntry _buildEntry(
    CollectionAdapter<Object?> adapter,
    String table,
  ) {
    final pattern = adapter.pattern;
    final paramNames = pattern.params;
    final paramSqlNames = [
      for (final param in paramNames) paramColumnName(param),
    ];
    final fieldColumns = List<FieldColumn<Object?, Object?>>.of(
      adapter.columns,
    );
    final columnDdls = [
      for (final column in fieldColumns)
        ColumnDdl(
          name: fieldColumnName(column.name),
          sqlType: switch (column.type) {
            ColumnType.integer => 'INTEGER',
            ColumnType.real => 'REAL',
            ColumnType.text => 'TEXT',
            ColumnType.blob => 'BLOB',
          },
          nullable: column.nullable,
          checkType: switch (column.type) {
            ColumnType.integer => 'integer',
            ColumnType.real => 'real',
            ColumnType.text => 'text',
            ColumnType.blob => null,
          },
        ),
    ];
    final indexes = <IndexDdl>[];
    final indexPlans = <IndexPlan>[
      // The implicit scope index first: (p_params..., id). The plan carries
      // the logical names the index checker compares against.
      IndexPlan(
        name: scopeIndexName(table),
        parts: [
          for (final param in paramNames) IndexPartDdl(param),
          const IndexPartDdl('id'),
        ],
        unique: true,
      ),
    ];
    for (final index in adapter.indexes) {
      final built = _buildIndexDdl(
        table,
        index,
        paramNames,
        unique: index.unique,
      );
      indexes.add(built.ddl);
      indexPlans.add(built.plan);
    }
    final scopeParts = [
      for (final param in paramNames) IndexPartDdl(paramColumnName(param)),
      const IndexPartDdl('id'),
    ];
    final scopeCanonical = '$table|u|${paramNames.join(',')}|id';
    final scopeIndex = IndexDdl(
      name: scopeIndexName(table),
      parts: scopeParts,
      unique: true,
      canonical: scopeCanonical,
    );
    final shapeHash = tableShapeHash(
      table: table,
      paramSqlNames: paramSqlNames,
      columns: columnDdls,
      indexCanonicals: [for (final index in indexes) index.canonical],
    );
    return RegistryEntry._(
      adapter: adapter,
      table: table,
      paramNames: List.unmodifiable(paramNames),
      paramSqlNames: List.unmodifiable(paramSqlNames),
      fieldColumns: List.unmodifiable(fieldColumns),
      columnDdls: List.unmodifiable(columnDdls),
      indexes: List.unmodifiable(indexes),
      indexPlans: List.unmodifiable(indexPlans),
      scopeIndex: scopeIndex,
      shapeHash: shapeHash,
    );
  }

  static ({IndexDdl ddl, IndexPlan plan}) _buildIndexDdl(
    String table,
    IndexDef index,
    List<String> paramNames, {
    required bool unique,
  }) {
    // The document id is appended as the final part, with the direction of
    // the last declared part, so keyset pagination stays stable.
    final lastDescending =
        index.parts.isNotEmpty && index.parts.last.descending;
    final logicalParts = <IndexPartDdl>[
      for (final part in index.parts)
        IndexPartDdl(part.name, descending: part.descending),
      IndexPartDdl('id', descending: lastDescending),
    ];
    final physicalParts = <IndexPartDdl>[
      for (final part in index.parts)
        IndexPartDdl(
          paramNames.contains(part.name)
              ? paramColumnName(part.name)
              : fieldColumnName(part.name),
          descending: part.descending,
        ),
      // A unique index must not end with the id, or the constraint could
      // never fire (two documents always differ in id). The planner still
      // treats id as the tiebreaker: with unique keys there are no ties.
      if (!unique) IndexPartDdl('id', descending: lastDescending),
    ];
    final canonicalParts = [
      for (final part in logicalParts)
        part.descending ? '-${part.name}' : part.name,
    ];
    final canonical =
        '$table|${unique ? 'u' : 'n'}|${canonicalParts.join(',')}';
    return (
      ddl: IndexDdl(
        name: indexName(table, canonical),
        parts: List.unmodifiable(physicalParts),
        unique: unique,
        canonical: canonical,
      ),
      plan: IndexPlan(
        name: indexName(table, canonical),
        parts: List.unmodifiable(logicalParts),
        unique: unique,
      ),
    );
  }
}
