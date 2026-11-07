import 'package:meta/meta_meta.dart';

/// Marks a class as a Cocoon collection model.
///
/// The model class is the schema: field names and types are read by the
/// generator, and field numbers are pinned in `cocoon.lock.json`, so the
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
class Index {
  const Index(this.fields, {this.unique = false});

  /// Field (or path param) names in sort order, e.g. `['accountId', '-bookedOn']`.
  final List<String> fields;

  /// Whether the indexed fields must be unique within the collection.
  final bool unique;
}

/// Excludes a field from storage. It is neither encoded nor tracked by the lock.
@Target({TargetKind.field, TargetKind.getter})
class Ignore {
  const Ignore();
}

/// Marks a class as embeddable: it is stored inline inside a [Collection]
/// model's document, encoded as a nested protobuf message.
///
/// The embedded class follows the same rules as a collection model: one
/// generative constructor whose parameters are named exactly like the stored
/// final fields (named or positional), and the same supported field types.
/// Its field numbers are pinned in `cocoon.lock.json` under its type name,
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
  const Embedded();
}
