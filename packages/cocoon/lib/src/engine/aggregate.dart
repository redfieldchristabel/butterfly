/// Server-style aggregation pushdown: Firestore's `count`/`sum`/`average`
/// aggregates, plus Cocoon's `groupBy` extension (`key`/`bucket`/`year`/
/// `month`/`day` keys with `minOf`/`maxOf`).
///
/// The math runs in one SQLite statement over the mirrored `f_` columns —
/// the document blob is never decoded. Build the queries from a query's
/// `aggregate([...])` and `groupBy([...])` builders.
library;

import 'package:meta/meta.dart';

import 'adapter.dart';

/// Thrown when a query aggregates or groups by a field that has no `f_`
/// column.
///
/// Only mirrored fields can be aggregated: aggregates run inside SQLite,
/// which cannot read the protobuf document blob. A field is mirrored when an
/// `Index([...])` lists it or it carries `@Mirrored()`, so the fix is one of
/// those two declarations (or reading the documents and aggregating in
/// Dart): `@Mirrored()` for totals and group keys, an `Index([...])` when
/// the query also filters or sorts on the field.
class UnmirroredFieldException implements Exception {
  /// Builds the exception with a human-readable [message] and, when there
  /// is something to declare, the ready-to-paste [suggestedDeclaration].
  UnmirroredFieldException(this.message, {this.suggestedDeclaration});

  /// Explains which field failed and how to mirror it.
  final String message;

  /// The declaration that would mirror the field (`@Mirrored()` on the
  /// field, or an `Index([...])` on the `@Collection`), or `null` when
  /// there is nothing to declare.
  final String? suggestedDeclaration;

  @override
  String toString() => 'UnmirroredFieldException: $message';
}

/// Thrown when an integer `sum` exceeds SQLite's 64-bit range.
///
/// SQLite refuses to wrap: summing past ±2^63 aborts the statement with an
/// integer-overflow error, which surfaces here instead of as a wrapped
/// value. Split the sum (per month, per account) or aggregate in Dart when
/// totals can overflow.
class AggregateOverflowException implements Exception {
  /// Builds the exception with a human-readable [message].
  AggregateOverflowException(this.message);

  /// Explains which aggregation overflowed.
  final String message;

  @override
  String toString() => 'AggregateOverflowException: $message';
}

/// One requested aggregation: the [count]/[sum]/[average]/[min]/[max]
/// functions a `.aggregate([...])` call lists.
///
/// Value equality is by kind and field name, so a getter on the result
/// snapshot or group finds its value by the same handle.
@immutable
sealed class AggregateFunction<T extends Object?> {
  /// Builds an aggregate function; use the top-level [count], [sum],
  /// [average], [min] and [max] helpers.
  const AggregateFunction();

  /// The field the function aggregates, or `null` for [count].
  FieldColumn<T, Object?>? get column;

  /// A short human name for error messages, e.g. `sum(amountMinor)`.
  String get label;
}

/// `count()`: how many documents match, whatever their field values —
/// Firestore's `COUNT(*)`, nulls included.
@immutable
final class CountAggregate<T extends Object?> extends AggregateFunction<T> {
  /// Builds the count; prefer the top-level [count] function.
  const CountAggregate();

  @override
  FieldColumn<T, Object?>? get column => null;

  @override
  String get label => 'count()';

  @override
  bool operator ==(Object other) => other is CountAggregate<T>;

  @override
  int get hashCode => 'count'.hashCode;
}

/// `sum(column)`: the total of a numeric field over the matching documents,
/// skipping nulls. Never null: an empty sum is `0` (Firestore semantics).
@immutable
final class SumAggregate<T extends Object?> extends AggregateFunction<T> {
  /// Builds the sum; prefer the top-level [sum] function.
  const SumAggregate(this.column);

  @override
  final FieldColumn<T, Object?> column;

  @override
  String get label => 'sum(${column.name})';

  @override
  bool operator ==(Object other) =>
      other is SumAggregate<T> && other.column.name == column.name;

  @override
  int get hashCode => Object.hash('sum', column.name);
}

/// `average(column)`: the mean of a numeric field over the matching
/// documents, skipping nulls. Always a `double`; `null` when no document
/// has a value (Firestore semantics).
@immutable
final class AverageAggregate<T extends Object?> extends AggregateFunction<T> {
  /// Builds the average; prefer the top-level [average] function.
  const AverageAggregate(this.column);

  @override
  final FieldColumn<T, Object?> column;

  @override
  String get label => 'average(${column.name})';

  @override
  bool operator ==(Object other) =>
      other is AverageAggregate<T> && other.column.name == column.name;

  @override
  int get hashCode => Object.hash('average', column.name);
}

/// `minOf(column)`: the smallest value of a field over the matching
/// documents, skipping nulls — `null` when no document has a value. A
/// Cocoon extension (Firestore has no min/max aggregates); SQL ordering
/// semantics apply.
@immutable
final class MinAggregate<T extends Object?> extends AggregateFunction<T> {
  /// Builds the min; prefer the top-level [min] function.
  const MinAggregate(this.column);

  @override
  final FieldColumn<T, Object?> column;

  @override
  String get label => 'min(${column.name})';

  @override
  bool operator ==(Object other) =>
      other is MinAggregate<T> && other.column.name == column.name;

  @override
  int get hashCode => Object.hash('min', column.name);
}

/// `maxOf(column)`: the largest value of a field over the matching documents,
/// skipping nulls — `null` when no document has a value. A Cocoon extension
/// (Firestore has no min/max aggregates); SQL ordering semantics apply.
@immutable
final class MaxAggregate<T extends Object?> extends AggregateFunction<T> {
  /// Builds the max; prefer the top-level [max] function.
  const MaxAggregate(this.column);

  @override
  final FieldColumn<T, Object?> column;

  @override
  String get label => 'max(${column.name})';

  @override
  bool operator ==(Object other) =>
      other is MaxAggregate<T> && other.column.name == column.name;

  @override
  int get hashCode => Object.hash('max', column.name);
}

/// `count()`: counts the matching documents (`COUNT(*)`), whatever their
/// field values — nulls included, like Firestore.
AggregateFunction<T> count<T extends Object?>() => CountAggregate<T>();

/// `sum(column)`: total of a numeric field (`int`/`double`, nullable
/// allowed) over the matching documents, skipping nulls.
///
/// Integer fields sum to `int`, double fields to `double`; an empty result
/// sums to zero. Summing past ±2^63 throws an
/// [AggregateOverflowException] instead of wrapping. Passing a non-numeric
/// field is a compile-time error.
AggregateFunction<T> sum<T extends Object?, V extends num?>(
  FieldColumn<T, V> column,
) => SumAggregate<T>(column);

/// `average(column)`: mean of a numeric field (`int`/`double`, nullable
/// allowed) over the matching documents, skipping nulls.
///
/// Always a `double`; `null` when no matching document has a value.
/// Passing a non-numeric field is a compile-time error.
AggregateFunction<T> average<T extends Object?, V extends num?>(
  FieldColumn<T, V> column,
) => AverageAggregate<T>(column);

/// `minOf(column)`: smallest value of a field over the matching documents,
/// skipping nulls; `null` when no document has a value.
///
/// A Cocoon extension, not in Firestore. Values compare in SQL order (so
/// `DateTime` fields compare by their stored UTC instant); the result is
/// converted back to the field's type.
AggregateFunction<T> minOf<T extends Object?, V extends Object?>(
  FieldColumn<T, V> column,
) => MinAggregate<T>(column);

/// `maxOf(column)`: largest value of a field over the matching documents,
/// skipping nulls; `null` when no document has a value.
///
/// A Cocoon extension, not in Firestore. Values compare in SQL order (so
/// `DateTime` fields compare by their stored UTC instant); the result is
/// converted back to the field's type.
AggregateFunction<T> maxOf<T extends Object?, V extends Object?>(
  FieldColumn<T, V> column,
) => MaxAggregate<T>(column);

/// One group-by key of a `query.groupBy([...])` call: how matching
/// documents are bucketed into groups.
///
/// [K] is the Dart type the group's `key()` getter returns for this spec.
/// Value equality is by kind, field name and parameters, so a group's
/// `key()` getter finds its value by the same handle.
@immutable
sealed class GroupKeySpec<T extends Object?, K extends Object?> {
  /// Builds a key spec; use the top-level [key], [paramKey], [bucket],
  /// [year], [month] and [day] helpers.
  const GroupKeySpec();

  /// A short human name for error messages, e.g. `bucket(bookedOn, 100)`.
  String get label;
}

/// `key(column)`: groups by the field's own value, converted back to the
/// field's type (`DateTime`, enum, ...). Null values form their own group.
@immutable
final class FieldKey<T extends Object?, K extends Object?>
    extends GroupKeySpec<T, K> {
  /// Builds the key; prefer the top-level [key] function.
  const FieldKey(this.column);

  /// The field to group by.
  final FieldColumn<T, K> column;

  @override
  String get label => 'key(${column.name})';

  @override
  bool operator ==(Object other) =>
      other is FieldKey<T, K> && other.column.name == column.name;

  @override
  int get hashCode => Object.hash('key', column.name);
}

/// `paramKey(column)`: groups a collection-group query by one of its path
/// params (`p_` columns) — the parent id, for example, to aggregate one
/// group per parent.
@immutable
final class ParamKey<T extends Object?> extends GroupKeySpec<T, String> {
  /// Builds the key; prefer the top-level [paramKey] function.
  const ParamKey(this.column);

  /// The path param to group by.
  final ParamColumn column;

  @override
  String get label => 'paramKey(${column.name})';

  @override
  bool operator ==(Object other) =>
      other is ParamKey<T> && other.column.name == column.name;

  @override
  int get hashCode => Object.hash('paramKey', column.name);
}

/// `bucket(column, width:)`: groups a numeric field into fixed-width bands
/// `floor(value / width) * width` — `yyyymmdd` dates into `yyyymm00`
/// months with `width: 100`, prices into bands.
///
/// An integer field with an integer width yields `int` keys; anything
/// else yields `double` keys. Null values form their own group.
@immutable
final class BucketKey<T extends Object?, K extends num?>
    extends GroupKeySpec<T, K> {
  /// Builds the key; prefer the top-level [bucket] function.
  const BucketKey(this.column, this.width);

  /// The numeric field to bucket.
  final FieldColumn<T, K> column;

  /// The band width (positive).
  final num width;

  @override
  String get label => 'bucket(${column.name}, $width)';

  @override
  bool operator ==(Object other) =>
      other is BucketKey<T, K> &&
      other.column.name == column.name &&
      other.width == width;

  @override
  int get hashCode => Object.hash('bucket', column.name, width);
}

/// What a [CalendarKey] buckets a `DateTime` field into.
enum CalendarPeriod {
  /// The calendar year in the key's fixed offset, e.g. `2026`.
  year,

  /// The calendar month as `yyyymm` in the key's fixed offset, e.g.
  /// `202602`.
  month,

  /// The calendar day as `yyyymmdd` in the key's fixed offset, e.g.
  /// `20260201`.
  day,
}

/// `year`/`month`/`day`: groups a `DateTime` field (stored as UTC
/// microseconds) into calendar buckets computed at a fixed [utcOffset].
@immutable
final class CalendarKey<T extends Object?> extends GroupKeySpec<T, int> {
  /// Builds the key; prefer the top-level [year], [month] and [day]
  /// functions.
  const CalendarKey(this.column, this.period, this.utcOffset);

  /// The `DateTime` field to bucket.
  final FieldColumn<T, DateTime> column;

  /// Which calendar bucket the key produces.
  final CalendarPeriod period;

  /// The fixed offset from UTC the calendar runs at.
  final Duration utcOffset;

  @override
  String get label => '${period.name}(${column.name})';

  @override
  bool operator ==(Object other) =>
      other is CalendarKey<T> &&
      other.column.name == column.name &&
      other.period == period &&
      other.utcOffset == utcOffset;

  @override
  int get hashCode => Object.hash('calendar', column.name, period, utcOffset);
}

/// `key(column)`: a group-by key over the field's own value, converted back
/// to the field's type (`DateTime`, enum, ...).
///
/// Null values form their own group (sorted first). Keys must be mirrored
/// fields — see [UnmirroredFieldException].
GroupKeySpec<T, K> key<T extends Object?, K extends Object?>(
  FieldColumn<T, K> column,
) => FieldKey<T, K>(column);

/// `paramKey(column)`: a group-by key over a path param of the collection's
/// pattern — the parent id of a collection-group query, for example:
///
/// ```dart
/// db.collectionGroup(txns)
///     .groupBy([paramKey(txnAccountId), bucket(Txn$.bookedOn, width: 100)])
///     .aggregate([sum(Txn$.amountMinor)])
///     .get();
/// ```
///
/// The type argument [T] is inferred from the query.
GroupKeySpec<T, String> paramKey<T extends Object?>(ParamColumn column) =>
    ParamKey<T>(column);

/// `bucket(column, width:)`: a group-by key of fixed-width numeric bands
/// `floor(value / width) * width` — `yyyymmdd` booking days into months
/// with `bucket(Txn$.bookedOn, width: 100)`, prices into bands.
///
/// An integer field with an integer width produces `int` keys; a double
/// field (or a fractional width on an integer field, which the engine
/// rejects) would produce `double` keys. The width must be positive. Null
/// values form their own group (sorted first).
GroupKeySpec<T, V> bucket<T extends Object?, V extends num?>(
  FieldColumn<T, V> column, {
  required num width,
}) => BucketKey<T, V>(column, width);

/// `year(column, utcOffset:)`: a group-by key of calendar years, computed
/// at the fixed [utcOffset] — `2026`, for example.
///
/// ## The utcOffset rule
///
/// The bucket is computed by shifting the stored UTC instant by this fixed
/// offset and reading the calendar — no IANA zones, no DST. For a zone
/// with DST a fixed offset is wrong part of the year: months and days near
/// a transition can land in the wrong bucket SILENTLY. For such zones,
/// don't group by calendar keys; run one aggregate per period with range
/// filters on the instant itself (one query per month, `isGreaterThanOrEqualTo`
/// the month's start and `isLessThan` the next month's start, each with the
/// offset that applies inside it), or store the local wall-clock date as a
/// separate `int` `yyyymmdd` field and [bucket] on it. Fixed-offset zones
/// (UTC, `+08:00`, ...) are exact.
GroupKeySpec<T, int> year<T extends Object?>(
  FieldColumn<T, DateTime> column, {
  required Duration utcOffset,
}) => CalendarKey<T>(column, CalendarPeriod.year, utcOffset);

/// `month(column, utcOffset:)`: a group-by key of calendar months as
/// `yyyymm`, computed at the fixed [utcOffset] — `202602`, for example.
///
/// ## The utcOffset rule
///
/// The bucket is computed by shifting the stored UTC instant by this fixed
/// offset and reading the calendar — no IANA zones, no DST. For a zone
/// with DST a fixed offset is wrong part of the year: months and days near
/// a transition can land in the wrong bucket SILENTLY. For such zones,
/// don't group by calendar keys; run one aggregate per period with range
/// filters on the instant itself (one query per month, `isGreaterThanOrEqualTo`
/// the month's start and `isLessThan` the next month's start, each with the
/// offset that applies inside it), or store the local wall-clock date as a
/// separate `int` `yyyymmdd` field and [bucket] on it. Fixed-offset zones
/// (UTC, `+08:00`, ...) are exact.
GroupKeySpec<T, int> month<T extends Object?>(
  FieldColumn<T, DateTime> column, {
  required Duration utcOffset,
}) => CalendarKey<T>(column, CalendarPeriod.month, utcOffset);

/// `day(column, utcOffset:)`: a group-by key of calendar days as `yyyymmdd`,
/// computed at the fixed [utcOffset] — `20260201`, for example.
///
/// ## The utcOffset rule
///
/// The bucket is computed by shifting the stored UTC instant by this fixed
/// offset and reading the calendar — no IANA zones, no DST. For a zone
/// with DST a fixed offset is wrong part of the year: months and days near
/// a transition can land in the wrong bucket SILENTLY. For such zones,
/// don't group by calendar keys; run one aggregate per period with range
/// filters on the instant itself (one query per day, `isGreaterThanOrEqualTo`
/// the day's start and `isLessThan` the next day's start, each with the
/// offset that applies inside it), or store the local wall-clock date as a
/// separate `int` `yyyymmdd` field and [bucket] on it. Fixed-offset zones
/// (UTC, `+08:00`, ...) are exact.
GroupKeySpec<T, int> day<T extends Object?>(
  FieldColumn<T, DateTime> column, {
  required Duration utcOffset,
}) => CalendarKey<T>(column, CalendarPeriod.day, utcOffset);

/// The result of an [AggregateQuery.get]: one row of computed values over
/// the whole (or limited) result set — no documents decoded.
///
/// Getters for functions the query did not request throw an
/// [ArgumentError]. The snapshot implements `==` by function and value, so
/// watch streams can deduplicate.
final class AggregateQuerySnapshot<T extends Object?> {
  /// Builds a snapshot; the engine assembles them from one SQL row.
  @internal
  const AggregateQuerySnapshot(
    List<AggregateFunction<T>> specs,
    List<Object?> values,
    int count,
  ) : _specs = specs,
      _values = values,
      _count = count;

  final List<AggregateFunction<T>> _specs;
  final List<Object?> _values;

  final int _count;

  /// How many documents the query matched — `count()`'s value. Nulls are
  /// counted; every matching document counts, like Firestore's `COUNT(*)`.
  int get count => _count;

  /// The value of a requested [sum] over [column].
  ///
  /// Never null: an empty sum is `0`. An integer field sums to `int`, a
  /// double field to `double`.
  R getSum<R extends num>(FieldColumn<T, R?> column) =>
      _valueOf<SumAggregate<T>>(column, 'sum') as R;

  /// The value of a requested [average] over [column]: a `double`, or
  /// `null` when no matching document had a value.
  double? getAverage<R extends num>(FieldColumn<T, R?> column) =>
      _valueOf<AverageAggregate<T>>(column, 'average') as double?;

  /// The value of a requested [min] over [column], converted back to the
  /// field's type; `null` when no matching document had a value.
  R? getMin<R extends Object?>(FieldColumn<T, R?> column) =>
      _valueOf<MinAggregate<T>>(column, 'min') as R?;

  /// The value of a requested [max] over [column], converted back to the
  /// field's type; `null` when no matching document had a value.
  R? getMax<R extends Object?>(FieldColumn<T, R?> column) =>
      _valueOf<MaxAggregate<T>>(column, 'max') as R?;

  Object? _valueOf<F extends AggregateFunction<T>>(
    FieldColumn<T, Object?> column,
    String kind,
  ) {
    for (var i = 0; i < _specs.length; i++) {
      final spec = _specs[i];
      if (spec is F && spec.column!.name == column.name) {
        return _values[i];
      }
    }
    throw ArgumentError.value(
      column.name,
      'column',
      'This aggregate query did not request $kind(${column.name}); it '
          'requested ${_specs.map((spec) => spec.label).join(', ')}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AggregateQuerySnapshot<T> &&
      other.count == count &&
      _listEquals(other._specs, _specs) &&
      _listEquals(other._values, _values);

  @override
  int get hashCode => Object.hash(count, Object.hashAll(_values));

  @override
  String toString() =>
      'AggregateQuerySnapshot(count: $count, '
      'values: ${[for (var i = 0; i < _specs.length; i++) '${_specs[i].label}: ${_values[i]}'].join(', ')})';
}

/// One group of a [group-by query](AggregateGroupQuery): its key values
/// plus the same aggregates as a whole-result snapshot, plus `minOf`/`maxOf`.
///
/// Groups come ordered by their keys ascending; groups whose key values
/// are null sort first. Getters for keys or functions the query did not
/// request throw an [ArgumentError]. The group implements `==` by key and
/// value, so watch streams can deduplicate.
final class AggregateGroup<T extends Object?> {
  /// Builds a group; the engine assembles them from one SQL row.
  @internal
  const AggregateGroup(
    List<GroupKeySpec<T, Object?>> keys,
    List<Object?> keyValues,
    List<AggregateFunction<T>> specs,
    List<Object?> values,
    int count,
  ) : _keys = keys,
      _keyValues = keyValues,
      _specs = specs,
      _values = values,
      _count = count;

  final List<GroupKeySpec<T, Object?>> _keys;
  final List<Object?> _keyValues;
  final List<AggregateFunction<T>> _specs;
  final List<Object?> _values;
  final int _count;

  /// How many documents this group holds — the group's `count()` value.
  int get count => _count;

  /// The value of a requested key [spec], converted back to the field's
  /// type (`DateTime`, enum, ...) — `null` for the null group.
  K key<K extends Object?>(GroupKeySpec<T, K> spec) {
    for (var i = 0; i < _keys.length; i++) {
      if (_keys[i] == spec) {
        return _keyValues[i] as K;
      }
    }
    throw ArgumentError.value(
      spec.label,
      'spec',
      'This group-by query did not group by ${spec.label}; it groups by '
          '${_keys.map((key) => key.label).join(', ')}',
    );
  }

  /// The group's value of a requested [sum] over [column]: never null
  /// (an empty sum is `0`); an integer field sums to `int`, a double field
  /// to `double`.
  R getSum<R extends num>(FieldColumn<T, R?> column) =>
      _valueOf<SumAggregate<T>>(column, 'sum') as R;

  /// The group's value of a requested [average] over [column]: a `double`,
  /// or `null` when no document in the group had a value.
  double? getAverage<R extends num>(FieldColumn<T, R?> column) =>
      _valueOf<AverageAggregate<T>>(column, 'average') as double?;

  /// The group's value of a requested [min] over [column], converted back
  /// to the field's type; `null` when no document in the group had a value.
  R? getMin<R extends Object?>(FieldColumn<T, R?> column) =>
      _valueOf<MinAggregate<T>>(column, 'min') as R?;

  /// The group's value of a requested [max] over [column], converted back
  /// to the field's type; `null` when no document in the group had a value.
  R? getMax<R extends Object?>(FieldColumn<T, R?> column) =>
      _valueOf<MaxAggregate<T>>(column, 'max') as R?;

  Object? _valueOf<F extends AggregateFunction<T>>(
    FieldColumn<T, Object?> column,
    String kind,
  ) {
    for (var i = 0; i < _specs.length; i++) {
      final spec = _specs[i];
      if (spec is F && spec.column!.name == column.name) {
        return _values[i];
      }
    }
    throw ArgumentError.value(
      column.name,
      'column',
      'This group-by query did not request $kind(${column.name}); it '
          'requested ${_specs.map((spec) => spec.label).join(', ')}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AggregateGroup<T> &&
      other.count == count &&
      _listEquals(other._keyValues, _keyValues) &&
      _listEquals(other._keys, _keys) &&
      _listEquals(other._specs, _specs) &&
      _listEquals(other._values, _values);

  @override
  int get hashCode =>
      Object.hash(count, Object.hashAll(_keyValues), Object.hashAll(_values));

  @override
  String toString() =>
      'AggregateGroup(keys: ${_keyValues.join(', ')}, count: $count, '
      'values: ${[for (var i = 0; i < _specs.length; i++) '${_specs[i].label}: ${_values[i]}'].join(', ')})';
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
