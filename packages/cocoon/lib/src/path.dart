import 'package:meta/meta.dart';

final _collectionIdPattern = RegExp(r'^[a-z][a-z0-9_]*$');
final _paramPattern = RegExp(r'^\{([a-zA-Z][a-zA-Z0-9]*)\}$');

/// Longest document id Cocoon accepts, in UTF-16 code units.
const maxDocIdLength = 256;

/// Throws an [ArgumentError] when [id] can't be used as a document id.
///
/// Ids are path segments, so they can't be empty, contain `/`, or be `.`/`..`.
void validateDocId(String id) {
  if (id.isEmpty) {
    throw ArgumentError.value(id, 'id', 'Document ids must not be empty');
  }
  if (id.contains('/')) {
    throw ArgumentError.value(id, 'id', 'Document ids must not contain "/"');
  }
  if (id == '.' || id == '..') {
    throw ArgumentError.value(id, 'id', 'Document ids must not be "." or ".."');
  }
  if (id.length > maxDocIdLength) {
    throw ArgumentError.value(
      id,
      'id',
      'Document ids must be at most $maxDocIdLength characters',
    );
  }
}

/// A declared collection path such as `accounts/{accountId}/txns`.
///
/// Even segments are collection ids (`[a-z][a-z0-9_]*`), odd segments are
/// `{param}` placeholders for parent document ids. A pattern always ends with
/// a collection id.
@immutable
class CollectionPattern {
  CollectionPattern._(
    this.pattern,
    this._segments,
    this.collectionIds,
    this.params,
  );

  /// Parses and validates [pattern], throwing a [FormatException] when invalid.
  factory CollectionPattern.parse(String pattern) {
    if (pattern.isEmpty) {
      throw FormatException('Collection pattern must not be empty', pattern);
    }
    final segments = pattern.split('/');
    if (segments.length.isEven) {
      throw FormatException(
        'Collection pattern must end with a collection id',
        pattern,
      );
    }
    final ids = <String>[];
    final params = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (i.isEven) {
        if (!_collectionIdPattern.hasMatch(segment)) {
          throw FormatException(
            'Invalid collection id "$segment": use lowercase letters, digits '
            'and underscores, starting with a letter',
            pattern,
          );
        }
        ids.add(segment);
      } else {
        final match = _paramPattern.firstMatch(segment);
        if (match == null) {
          throw FormatException(
            'Invalid placeholder "$segment": expected {paramName}',
            pattern,
          );
        }
        final name = match.group(1)!;
        if (params.contains(name)) {
          throw FormatException('Duplicate placeholder "{$name}"', pattern);
        }
        params.add(name);
      }
    }
    return CollectionPattern._(
      pattern,
      List.unmodifiable(segments),
      List.unmodifiable(ids),
      List.unmodifiable(params),
    );
  }

  /// The pattern text, e.g. `accounts/{accountId}/txns`.
  final String pattern;

  final List<String> _segments;

  /// Collection ids from root to leaf, e.g. `['accounts', 'txns']`.
  final List<String> collectionIds;

  /// Parent id placeholders from root to leaf, e.g. `['accountId']`.
  final List<String> params;

  /// The leaf collection id, e.g. `txns`.
  String get collectionId => collectionIds.last;

  /// Whether this is a root collection with no parent document.
  bool get isTopLevel => params.isEmpty;

  /// The pattern of the parent document's collection, or `null` at the root.
  CollectionPattern? get parent => isTopLevel
      ? null
      : CollectionPattern.parse(
          _segments.sublist(0, _segments.length - 2).join('/'),
        );

  /// Builds a concrete path by filling every placeholder from [values].
  CollectionPath resolve(Map<String, String> values) {
    final missing = params.where((p) => !values.containsKey(p)).toList();
    if (missing.isNotEmpty) {
      throw ArgumentError('Missing values for $pattern: ${missing.join(', ')}');
    }
    final extra = values.keys.where((k) => !params.contains(k)).toList();
    if (extra.isNotEmpty) {
      throw ArgumentError('Unknown params for $pattern: ${extra.join(', ')}');
    }
    final parts = <String>[];
    for (var i = 0; i < _segments.length; i++) {
      if (i.isEven) {
        parts.add(_segments[i]);
      } else {
        final value = values[params[i ~/ 2]]!;
        validateDocId(value);
        parts.add(value);
      }
    }
    return CollectionPath._(parts.join('/'), collectionId);
  }

  @override
  bool operator ==(Object other) =>
      other is CollectionPattern && other.pattern == pattern;

  @override
  int get hashCode => pattern.hashCode;

  @override
  String toString() => pattern;
}

/// A concrete collection path such as `accounts/a1/txns`.
@immutable
class CollectionPath {
  const CollectionPath._(this.path, this.collectionId);

  /// The full path text.
  final String path;

  /// The leaf collection id, e.g. `txns`.
  final String collectionId;

  /// The document [id] inside this collection.
  DocPath doc(String id) {
    validateDocId(id);
    return DocPath._('$path/$id', this, id);
  }

  @override
  bool operator ==(Object other) =>
      other is CollectionPath && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => path;
}

/// A concrete document path such as `accounts/a1/txns/t9`.
@immutable
class DocPath {
  const DocPath._(this.path, this.collection, this.id);

  /// The full path text.
  final String path;

  /// The collection this document lives in.
  final CollectionPath collection;

  /// The document id, unique within [collection].
  final String id;

  /// A subcollection under this document.
  CollectionPath subcollection(String collectionId) {
    if (!_collectionIdPattern.hasMatch(collectionId)) {
      throw ArgumentError.value(
        collectionId,
        'collectionId',
        'Invalid collection id',
      );
    }
    return CollectionPath._('$path/$collectionId', collectionId);
  }

  /// The half-open range `[from, to)` covering every descendant path.
  ///
  /// `'0'` is the character right after `'/'`, so a binary-collated
  /// `path >= from AND path < to` matches exactly this document's subtree,
  /// which is how cascade deletes and subtree exports are scanned.
  ({String from, String to}) get descendants =>
      (from: '$path/', to: '${path}0');

  @override
  bool operator ==(Object other) => other is DocPath && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => path;
}
