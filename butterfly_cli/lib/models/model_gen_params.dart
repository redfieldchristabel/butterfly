import 'dart:io';

class ModelGenParams {
  final String name;
  final String fileName;
  final Directory path;
  final bool serializable;

  ModelGenParams({
    required this.name,
    required this.fileName,
    required this.path,
    required this.serializable,
  });
}
