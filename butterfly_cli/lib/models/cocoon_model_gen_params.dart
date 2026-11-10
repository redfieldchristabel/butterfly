import 'dart:io';

/// Parameters for the `cocoon_model` mason brick: a `@Collection` model
/// scaffold.
class CocoonModelGenParams {
  final String name;
  final String fileName;
  final Directory path;

  /// The collection path written into `@Collection(...)`; `{param}` segments
  /// are included as-is.
  final String collectionPath;

  CocoonModelGenParams({
    required this.name,
    required this.fileName,
    required this.path,
    required this.collectionPath,
  });
}
