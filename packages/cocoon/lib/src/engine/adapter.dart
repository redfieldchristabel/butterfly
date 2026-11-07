import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../path.dart';
import 'naming.dart';

/// The SQLite storage type an indexed field is copied into.
enum ColumnType {
  /// Signed 64-bit integer. Also used for booleans (0/1) and `DateTime`
  /// (UTC microseconds since epoch).
  integer,

  /// IEEE 754 double.
  real,

  /// UTF-8 text. Also used for enums (stored as their name).
  text,

  /// Raw bytes.
  blob,
}

/// One indexed field of a [CollectionAdapter]'s model.
///
/// A `FieldColumn` does three jobs:
///
/// * it declares the typed SQLite column the field is copied into at write
///   time ([name], [type], [nullable]);
/// * it converts between the model field and the SQL value ([read], [toSql],
///   [fromSql]);
/// * it is the typed handle used to build queries:
///   `txnBookedOn.isGreaterThanOrEqualTo(20260101)`.
///
/// The type parameter [V] is the model field's type, including its
/// nullability: a nullable `String?` field infers `V = String?`, and must be
/// declared with `nullable: true`.
@immutable
final class FieldColumn<T, V> {
  /// Builds a column with explicit conversions.
  ///
  /// The ready-made factories ([FieldColumn.integer] and friends) provide
  /// [toSql]/[fromSql] for the common types.
  FieldColumn({
    required this.name,
    required this.type,
    this.nullable = false,
    required this.read,
    required this.toSql,
    required this.fromSql,
  });

  /// The model field name, e.g. `bookedOn`.
  final String name;

  /// The SQLite column type the field is copied into.
  final ColumnType type;

  /// Whether the field may be absent. Nullable columns allow SQL `NULL`;
  /// sort keys are never null (ordering by a nullable column throws).
  final bool nullable;

  /// Reads the field from a model value.
  final V Function(T) read;

  /// Converts the field value to its SQL representation
  /// (bool -> 0/1, DateTime -> UTC microseconds, enum -> name text).
  final Object? Function(V) toSql;

  /// Converts a SQL value back to the field type.
  final V Function(Object?) fromSql;

  /// Reads [value]'s field and converts it to its SQL representation.
  ///
  /// Used by the engine when backfilling a newly added column.
  Object? sqlOf(T value) => toSql(read(value));

  /// Equality filter: `column IS ?`.
  ///
  /// Throws an [ArgumentError] for `null`; use [isNull] on a nullable column.
  QueryFilter isEqualTo(V value) {
    _requireValue(value, 'isEqualTo');
    return QueryFilter(name, sqlName, FilterOp.equal, [toSql(value)]);
  }

  /// Inequality filter: `column IS NOT ?`. SQL semantics apply, so rows where
  /// the column is `NULL` never match.
  QueryFilter isNotEqualTo(V value) {
    _requireValue(value, 'isNotEqualTo');
    return QueryFilter(name, sqlName, FilterOp.notEqual, [toSql(value)]);
  }

  /// Range filter: `column < value`.
  QueryFilter isLessThan(V value) {
    _requireValue(value, 'isLessThan');
    return QueryFilter(name, sqlName, FilterOp.less, [toSql(value)]);
  }

  /// Range filter: `column <= value`.
  QueryFilter isLessThanOrEqualTo(V value) {
    _requireValue(value, 'isLessThanOrEqualTo');
    return QueryFilter(name, sqlName, FilterOp.lessEqual, [toSql(value)]);
  }

  /// Range filter: `column > value`.
  QueryFilter isGreaterThan(V value) {
    _requireValue(value, 'isGreaterThan');
    return QueryFilter(name, sqlName, FilterOp.greater, [toSql(value)]);
  }

  /// Range filter: `column >= value`.
  QueryFilter isGreaterThanOrEqualTo(V value) {
    _requireValue(value, 'isGreaterThanOrEqualTo');
    return QueryFilter(name, sqlName, FilterOp.greaterEqual, [toSql(value)]);
  }

  /// Membership filter: `column IN (?, ...)`, at most 30 values.
  QueryFilter whereIn(List<V> values) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'Must not be empty');
    }
    if (values.length > 30) {
      throw ArgumentError.value(
        values.length,
        'values',
        'whereIn supports at most 30 values',
      );
    }
    for (final value in values) {
      _requireValue(value, 'whereIn');
    }
    return QueryFilter(name, sqlName, FilterOp.inList, [
      for (final value in values) toSql(value),
    ]);
  }

  /// Absence filter: `column IS NULL`. Only allowed on a nullable column.
  QueryFilter isNull() {
    if (!nullable) {
      throw ArgumentError.value(
        name,
        'column',
        'isNull() is only allowed on a nullable column',
      );
    }
    return QueryFilter(name, sqlName, FilterOp.isNull, const []);
  }

  /// Presence filter: `column IS NOT NULL`. Only allowed on a nullable column.
  QueryFilter isNotNull() {
    if (!nullable) {
      throw ArgumentError.value(
        name,
        'column',
        'isNotNull() is only allowed on a nullable column',
      );
    }
    return QueryFilter(name, sqlName, FilterOp.isNotNull, const []);
  }

  /// The SQL column name, e.g. `f_booked_on`.
  String get sqlName => fieldColumnName(name);

  void _requireValue(V value, String method) {
    if (value == null) {
      throw ArgumentError.value(
        value,
        'value',
        '$method(null) is not supported; use isNull() on a nullable column',
      );
    }
  }

  /// Integer column (`int` field, SQLite `INTEGER`).
  static FieldColumn<T, V> integer<T, V extends int?>(
    String name, {
    required V Function(T) read,
    bool nullable = false,
  }) => FieldColumn<T, V>(
    name: name,
    type: ColumnType.integer,
    nullable: nullable,
    read: read,
    toSql: (V value) => value,
    fromSql: (Object? value) => value as V,
  );

  /// Floating point column (`double` field, SQLite `REAL`).
  static FieldColumn<T, V> real<T, V extends double?>(
    String name, {
    required V Function(T) read,
    bool nullable = false,
  }) => FieldColumn<T, V>(
    name: name,
    type: ColumnType.real,
    nullable: nullable,
    read: read,
    toSql: (V value) => value,
    fromSql: (Object? value) => value as V,
  );

  /// Boolean column (`bool` field, stored as SQLite `INTEGER` 0/1).
  static FieldColumn<T, V> boolean<T, V extends bool?>(
    String name, {
    required V Function(T) read,
    bool nullable = false,
  }) => FieldColumn<T, V>(
    name: name,
    type: ColumnType.integer,
    nullable: nullable,
    read: read,
    toSql: (V value) => value == null ? null : (value ? 1 : 0),
    fromSql: (Object? value) => (value == null ? null : value != 0) as V,
  );

  /// Text column (`String` field, SQLite `TEXT`).
  static FieldColumn<T, V> text<T, V extends String?>(
    String name, {
    required V Function(T) read,
    bool nullable = false,
  }) => FieldColumn<T, V>(
    name: name,
    type: ColumnType.text,
    nullable: nullable,
    read: read,
    toSql: (V value) => value,
    fromSql: (Object? value) => value as V,
  );

  /// Timestamp column (`DateTime` field, stored as UTC microseconds in a
  /// SQLite `INTEGER`). Values read back are UTC.
  static FieldColumn<T, V> dateTime<T, V extends DateTime?>(
    String name, {
    required V Function(T) read,
    bool nullable = false,
  }) => FieldColumn<T, V>(
    name: name,
    type: ColumnType.integer,
    nullable: nullable,
    read: read,
    toSql: (V value) => value?.toUtc().microsecondsSinceEpoch,
    fromSql: (Object? value) =>
        (value == null
                ? null
                : DateTime.fromMicrosecondsSinceEpoch(
                    value as int,
                    isUtc: true,
                  ))
            as V,
  );

  /// Enum column, stored as its name in SQLite `TEXT`.
  static FieldColumn<T, V> enumerated<T, V extends Enum?>(
    String name, {
    required V Function(T) read,
    required List<V> values,
    bool nullable = false,
  }) {
    V fromSql(Object? value) {
      if (value == null) {
        return null as V;
      }
      final stored = value as String;
      for (final enumValue in values) {
        if (enumValue != null && enumValue.name == stored) {
          return enumValue;
        }
      }
      throw ArgumentError.value(
        stored,
        'value',
        'Not a value of the enum indexed by column "$name"',
      );
    }

    return FieldColumn<T, V>(
      name: name,
      type: ColumnType.text,
      nullable: nullable,
      read: read,
      toSql: (V value) => value?.name,
      fromSql: fromSql,
    );
  }

  /// Binary column (`Uint8List` field, SQLite `BLOB`).
  static FieldColumn<T, V> blob<T, V extends Uint8List?>(
    String name, {
    required V Function(T) read,
    bool nullable = false,
  }) => FieldColumn<T, V>(
    name: name,
    type: ColumnType.blob,
    nullable: nullable,
    read: read,
    toSql: (V value) => value,
    fromSql: (Object? value) => value as V,
  );
}

/// A path param of a [CollectionAdapter]'s pattern as a queryable handle.
///
/// Params are always non-null `TEXT` columns; a scoped query filters them
/// automatically, and collection-group queries can filter them explicitly:
/// `db.collectionGroup(txns).where(txnAccountId.isEqualTo('a1'))`.
@immutable
final class ParamColumn {
  /// Builds the handle for param [name] of [pattern].
  ///
  /// Throws an [ArgumentError] when [pattern] has no `{name}` placeholder.
  ParamColumn(this.pattern, this.name) {
    if (!pattern.params.contains(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Pattern "${pattern.pattern}" has no {$name} placeholder',
      );
    }
  }

  /// The collection pattern the param belongs to.
  final CollectionPattern pattern;

  /// The param name, e.g. `accountId`.
  final String name;

  /// The SQL column name, e.g. `p_account_id`.
  String get sqlName => paramColumnName(name);

  /// Equality filter on the param column.
  QueryFilter isEqualTo(String value) =>
      QueryFilter(name, sqlName, FilterOp.equal, [value]);

  /// Inequality filter on the param column. Rows never have `NULL` params.
  QueryFilter isNotEqualTo(String value) =>
      QueryFilter(name, sqlName, FilterOp.notEqual, [value]);

  /// Membership filter on the param column, at most 30 values.
  QueryFilter whereIn(List<String> values) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'Must not be empty');
    }
    if (values.length > 30) {
      throw ArgumentError.value(
        values.length,
        'values',
        'whereIn supports at most 30 values',
      );
    }
    return QueryFilter(name, sqlName, FilterOp.inList, [...values]);
  }
}

/// The comparison operator of a [QueryFilter].
enum FilterOp {
  /// `=`
  equal,

  /// `!=`
  notEqual,

  /// `<`
  less,

  /// `<=`
  lessEqual,

  /// `>`
  greater,

  /// `>=`
  greaterEqual,

  /// `IN (...)`
  inList,

  /// `IS NULL`
  isNull,

  /// `IS NOT NULL`
  isNotNull,
}

/// One `where()` condition, built by [FieldColumn] and [ParamColumn] handles.
///
/// The name is the model-level name used by the index planner; [sqlName] is
/// the physical column and [sqlValues] are the already-converted SQL values.
/// The engine also builds filters for a subcollection ref's parent params.
@immutable
final class QueryFilter {
  /// Builds a filter. Prefer the handles: `txnBookedOn.isGreaterThan(5)`.
  const QueryFilter(this.name, this.sqlName, this.op, this.sqlValues);

  /// The model field or path param name, e.g. `bookedOn`.
  final String name;

  /// The SQL column the filter applies to, e.g. `f_booked_on`.
  final String sqlName;

  /// The comparison operator.
  final FilterOp op;

  /// Bound SQL values, in placeholder order. Empty for [FilterOp.isNull] and
  /// [FilterOp.isNotNull].
  final List<Object?> sqlValues;

  /// Whether the filter behaves like an equality for the index planner
  /// (`=`, `IN`, `IS NULL`).
  bool get isEqualityClass =>
      op == FilterOp.equal || op == FilterOp.inList || op == FilterOp.isNull;

  /// Whether the filter is a range/inequality for the index planner
  /// (`!=`, comparisons, `IS NOT NULL`).
  bool get isRangeClass => !isEqualityClass;
}

/// One part of a declared [IndexDef].
@immutable
final class IndexPart {
  /// Builds a part for field or path param [name], ascending by default.
  const IndexPart(this.name, {this.descending = false});

  /// The field or path param name.
  final String name;

  /// Whether the part is sorted descending.
  final bool descending;
}

/// A declared index over model fields and path params.
///
/// The document id is always appended as the final part, with the direction
/// of the last declared part, so keyset pagination stays stable.
@immutable
final class IndexDef {
  /// Builds an index from parts.
  IndexDef(List<IndexPart> parts, {this.unique = false})
    : parts = List.unmodifiable(parts);

  /// Builds an index from `@Index` annotation strings, where `-` prefixes a
  /// descending part: `['accountId', '-bookedOn']`.
  factory IndexDef.fromFields(List<String> fields, {bool unique = false}) {
    final parts = <IndexPart>[];
    for (final field in fields) {
      if (field.startsWith('-')) {
        parts.add(IndexPart(field.substring(1), descending: true));
      } else {
        parts.add(IndexPart(field));
      }
    }
    return IndexDef(parts, unique: unique);
  }

  /// The indexed names, in order.
  final List<IndexPart> parts;

  /// Whether the index is created `UNIQUE`.
  final bool unique;
}

/// The per-collection glue between a Dart model class and its SQLite table.
///
/// This is the class the code generator emits for every `@Collection` model;
/// hand-write one the same way until then. One adapter is registered per
/// collection when the database is opened.
///
/// ```dart
/// final class TxnAdapter extends CollectionAdapter<Txn> {
///   @override
///   String get model => 'Txn';
///
///   @override
///   final pattern = CollectionPattern.parse('accounts/{accountId}/txns');
///
///   @override
///   List<FieldColumn<Txn, Object?>> get columns => [txnBookedOn, ...];
///
///   @override
///   List<IndexDef> get indexes => [IndexDef.fromFields(['accountId', '-bookedOn'])];
///
///   @override
///   Uint8List encode(Txn value) { ... } // WireWriter, ascending field numbers
///
///   @override
///   Txn decode(Uint8List bytes) { ... } // WireReader
/// }
/// ```
abstract class CollectionAdapter<T> {
  /// Builds an adapter. Const, so generated adapters can be `const`
  /// top-level instances.
  const CollectionAdapter();

  /// The model class name, e.g. `Txn`. Determines the table name.
  String get model;

  /// The collection path pattern, e.g. `accounts/{accountId}/txns`.
  CollectionPattern get pattern;

  /// The model fields copied into typed columns at write time.
  List<FieldColumn<T, Object?>> get columns;

  /// The declared indexes Cocoon creates and reconciles on open.
  List<IndexDef> get indexes;

  /// Encodes [value] into canonical `WireWriter` bytes (ascending field
  /// numbers, no unknown fields).
  Uint8List encode(T value);

  /// Decodes canonical wire bytes back into the model.
  T decode(Uint8List bytes);

  /// Decodes [value] into a JSON-shaped map for the DevTools inspector.
  ///
  /// The default returns an empty map, in which case the inspector falls
  /// back to showing the indexed columns. The code generator overrides this
  /// for every `@Collection` model with the full field tree: DateTime fields
  /// as UTC ISO-8601 strings, enums by name, binary fields as
  /// `<N bytes>`, embedded classes and lists as nested JSON.
  Map<String, Object?> toInspectorJson(T value) => const {};
}
