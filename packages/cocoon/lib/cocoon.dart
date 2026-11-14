/// A typed, disk-backed, Firestore-style local database built on SQLite.
///
/// See `doc/design.md` for the architecture and the decisions behind it.
library;

export 'src/annotations.dart';
export 'src/cursor.dart';
export 'src/engine/adapter.dart';
export 'src/engine/aggregate.dart';
export 'src/engine/backup.dart'
    show
        BackupDamagedException,
        BackupFormatTooNewException,
        BackupInfo,
        NotCocoonBackupException,
        backupFormatVersion,
        cocoonLibraryVersion;
export 'src/engine/batch.dart' show BatchOp, BatchOpKind, WriteBatch;
export 'src/engine/bulk_writer.dart' show BulkWriter, BulkWriterOptions;
export 'src/engine/isolate/isolate_options.dart'
    show CocoonIsolate, CocoonAutoThresholds, CocoonIsolateStats;
export 'src/engine/isolate/error_envelope.dart' show CocoonIsolateException;
export 'src/engine/naming.dart' show snakeCase, tableNameFor, validNamePattern;
export 'src/engine/changes.dart' show Change, ChangeOp, ChangesPrunedException;
export 'src/engine/cocoon.dart';
export 'src/engine/format_migration.dart' show StorageFormatTooNewException;
export 'src/engine/query.dart'
    show
        AggregateGroupQuery,
        AggregateQuery,
        CocoonQuery,
        GroupByQuery,
        MissingIndexException,
        MissingIndexMode,
        MissingIndexReport,
        QueryPage,
        maxAggregatesPerCall,
        maxGroupKeys;
export 'src/engine/refs.dart';
export 'src/engine/transaction_guard.dart' show TransactionMisuseError;
export 'src/id.dart';
export 'src/migration.dart';
export 'src/path.dart';
export 'src/schema.dart';
export 'src/wire.dart';
