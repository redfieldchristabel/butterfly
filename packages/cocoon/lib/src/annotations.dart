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
