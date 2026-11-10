import 'package:cocoon/cocoon.dart';

part '{{fileName.snakeCase()}}.cocoon.dart';

/// TODO: describe what one {{name.pascalCase()}} document stores.
///
/// To query or sort by a field, add it to `indexes`, e.g.
/// `indexes: [Index(['name'])]` or, descending, `Index(['-createdAt'])`.
/// A field you total or group by but never filter on takes `@Mirrored()`
/// instead (it gets its own column without an index).
@Collection('{{{collectionPath}}}', indexes: [])
class {{name.pascalCase()}} {
  const {{name.pascalCase()}}({required this.name});

  final String name;
}
