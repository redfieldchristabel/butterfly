import 'package:meta/meta_meta.dart';

/// Marks a class as a Cocoon collection model.
///
/// The model class is the schema: field names and types are read by the
/// generator, and field numbers are pinned in `cocoon.lock`, so the
/// order of fields in the class never matters.
///
/// ```dart
/// @Collection('accounts/{accountId}/txns', indexes: [
///   Index(['accountId', '-bookedOn']),
/// ])
/// class Txn { ... }
/// ```
@Target({TargetKind.classType})
class Collection {
  /// Marks the annotated class as a Cocoon collection at [path] with
  /// [indexes].
  const Collection(this.path, {this.indexes = const []});

  /// Path pattern: collection ids separated by `{param}` placeholders,
  /// e.g. `accounts` or `accounts/{accountId}/txns`.
  final String path;

  /// Indexes Cocoon creates and keeps in sync with this declaration.
  final List<Index> indexes;
}

/// A composite index over model fields and path params.
///
/// Prefix a field with `-` to sort it descending. The document id is always
/// appended as the final tiebreaker so keyset pagination stays stable.
///
/// For an index over ONE model field, prefer [Indexed] on the field itself;
/// this class is for composites (two or more parts) and for indexes over path
/// params.
class Index {
  /// Indexes [fields] in order; set [unique] to make the combination unique
  /// within the collection.
  const Index(this.fields, {this.unique = false});

  /// Field (or path param) names in sort order, e.g. `['accountId', '-bookedOn']`.
  final List<String> fields;

  /// Whether the indexed fields must be unique within the collection.
  final bool unique;
}

/// Indexes a single field: the annotation declares the one-field index
/// `Index(['field'])` (or `Index(['-field'])` when [descending]) exactly as
/// if it were written in `@Collection(indexes: [...])`.
///
/// For one field prefer this over the class-level [Index] list: the
/// declaration sits on the field it indexes, and the generator produces the
/// same index either way — same canonical form, same physical index name, no
/// schema version bump when a one-field index moves between the two. Composite
/// indexes (two or more parts, or any path param) stay on the class: path
/// params are not fields and cannot carry this annotation.
///
/// ```dart
/// @Collection('accounts/{accountId}/txns', indexes: [
///   Index(['accountId', '-bookedOn']),
/// ])
/// class Txn {
///   @Indexed()
///   final String currency; // same index as Index(['currency']) on the class
///   ...
/// }
/// ```
///
/// Allowed on the field types an index field allows (`int`, `double`, `bool`,
/// `String`, `DateTime`, `Uint8List`, enums); anything else (lists, maps,
/// embedded classes) is a generator error, in the same style as `@Mirrored()`.
/// Not allowed inside `@Embedded` classes: embedded fields live inside the
/// document blob and have no column. A field that is both `@Mirrored()` and
/// `@Indexed()` is just indexed — one column, one index, no duplicate.
/// `@Indexed(unique: true)` makes the field's value unique within the
/// collection, like `Index(['field'], unique: true)`.
@Target({TargetKind.field, TargetKind.getter})
class Indexed {
  /// Declares the single-field index for the annotated field.
  const Indexed({this.descending = false, this.unique = false});

  /// Whether the index sorts the field descending (`Index(['-field'])`).
  final bool descending;

  /// Whether the field's value must be unique within the collection.
  final bool unique;
}

/// Copies a field into its own typed `f_` column WITHOUT creating an index,
/// so aggregates and group-by can read it while filters and sorts stay
/// index-only.
///
/// Aggregates (`query.aggregate([sum(...)])`, `query.groupBy([key(...)])`)
/// run inside SQLite, which reads only the mirrored `f_` columns — never the
/// protobuf document blob. Without this annotation a field gets a column
/// only when some `Index([...])` lists it, so a total over a field the app
/// never filters on would force an index the app never uses. `@Mirrored()`
/// keeps the column (same type mapping, nullability and CHECK as an index
/// field) and skips the index: sums, averages and group keys work, while a
/// `where()` or `orderBy()` on the field still follows the index rule and
/// throws a `MissingIndexException` (or `.allowFullScan()` opts out).
///
/// ```dart
/// @Collection('accounts/{accountId}/txns', indexes: [
///   Index(['accountId', '-bookedOn']),
/// ])
/// class Txn {
///   @Mirrored()
///   final int amountMinor; // sum() works; where(amountMinor > x) needs an Index
///   ...
/// }
/// ```
///
/// Allowed on the field types an index field allows (`int`, `double`,
/// `bool`, `String`, `DateTime`, `Uint8List`, enums); anything else is a
/// generator error. Not allowed inside `@Embedded` classes: embedded fields
/// live inside the document blob and have no column. A field that is both
/// mirrored and indexed is just indexed — one column, one index, no
/// duplicate. Adding the annotation to an existing collection adds and
/// backfills the column on the next open (one pass, in a transaction);
/// removing it drops the column the same way.
@Target({TargetKind.field, TargetKind.getter})
class Mirrored {
  /// Marks the annotated field as mirrored (column, no index).
  const Mirrored();
}

/// Excludes a field from storage. It is neither encoded nor tracked by the lock.
@Target({TargetKind.field, TargetKind.getter})
class Ignore {
  /// Excludes the annotated field from storage.
  const Ignore();
}

/// Marks a class as embeddable: it is stored inline inside a [Collection]
/// model's document, encoded as a nested protobuf message.
///
/// The embedded class follows the same rules as a collection model: one
/// generative constructor whose parameters are named exactly like the stored
/// final fields (named or positional), and the same supported field types.
/// Its field numbers are pinned in `cocoon.lock` under its type name,
/// in a number space of its own.
///
/// ```dart
/// @Embedded()
/// class Address {
///   const Address({required this.city, this.line2});
///   final String city;
///   final String? line2;
/// }
/// ```
@Target({TargetKind.classType})
class Embedded {
  /// Marks the annotated class as embeddable.
  const Embedded();
}
