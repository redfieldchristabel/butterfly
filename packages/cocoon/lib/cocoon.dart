/// A typed, disk-backed, Firestore-style local database built on SQLite.
///
/// See `doc/design.md` for the architecture and the decisions behind it.
library;

export 'src/annotations.dart';
export 'src/cursor.dart';
export 'src/engine/adapter.dart';
export 'src/engine/cocoon.dart';
export 'src/engine/query.dart'
    show CocoonQuery, MissingIndexException, QueryPage;
export 'src/engine/refs.dart';
export 'src/id.dart';
export 'src/path.dart';
export 'src/schema.dart';
export 'src/wire.dart';
