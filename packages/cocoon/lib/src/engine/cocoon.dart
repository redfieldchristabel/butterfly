import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../migration.dart';
import '../path.dart';
import '../schema.dart';
import '../inspector/service.dart';
import 'adapter.dart';
import 'aggregate.dart';
import 'backup.dart';
import 'batch.dart';
import 'bulk_writer.dart';
import 'changes.dart';
import 'executor.dart';
import 'format_migration.dart';
import 'isolate/auto.dart';
import 'isolate/background.dart';
import 'isolate/isolate_options.dart';
import 'local_runtime.dart';
import 'naming.dart';
import 'query.dart';
import 'refs.dart';
import 'runtime.dart';
import 'schema_sql.dart';
import 'sqlite_executor.dart';
import 'transaction_guard.dart';
import 'watch.dart';
import 'write_buffer.dart';

/// How eagerly commits hit the disk.
enum Durability {
  /// `PRAGMA synchronous = FULL`: every commit waits for the OS to flush.
  /// Slowest, nothing is lost on power loss. The default.
  full,

  /// `PRAGMA synchronous = NORMAL`: safe with WAL (commits are durable
  /// against application crashes, may lose the last transactions on power
  /// loss), and much faster for write-heavy workloads.
  normal,
}

/// A bound for the on-disk change log, applied by the engine after commits.
///
/// Pass it as [CocoonOptions.changeRetention]. Both fields are optional and
/// combine: the engine keeps at most [maxChanges] newest rows AND every row
/// newer than [maxAge]; anything older is deleted in small batches after a
/// commit that wrote change rows — never inside a user transaction, and at
/// most [CocoonOptions.defaultRetentionBatchRows] rows per commit, so a
/// large backlog shrinks over subsequent writes instead of stalling one.
///
/// The default (no [CocoonOptions.changeRetention]) keeps everything: the
/// log only grows when the app lets it, exactly as before.
final class ChangeRetention {
  /// Builds a retention policy; at least one bound must be set, and both
  /// must be non-negative — checked when the database opens
  /// ([CocoonOptions.changeRetention] is validated in `Cocoon.open`).
  const ChangeRetention({this.maxChanges, this.maxAge});

  /// Keep at most this many of the newest change rows.
  final int? maxChanges;

  /// Keep no change row older than this duration.
  final Duration? maxAge;

  /// Throws an [ArgumentError] when the policy is unusable (no bounds, or a
  /// negative one). Called when the database opens.
  void validate() {
    if (maxChanges == null && maxAge == null) {
      throw ArgumentError('ChangeRetention needs maxChanges, maxAge, or both');
    }
    if (maxChanges != null && maxChanges! < 0) {
      throw ArgumentError.value(
        maxChanges,
        'maxChanges',
        'Must not be negative',
      );
    }
    if (maxAge != null && maxAge!.isNegative) {
      throw ArgumentError.value(maxAge, 'maxAge', 'Must not be negative');
    }
  }
}

/// Options for opening a [Cocoon] database.
final class CocoonOptions {
  /// Builds options; the defaults are safe for money-style data.
  const CocoonOptions({
    this.durability = Durability.full,
    this.cacheSize = defaultCacheSize,
    this.keepChanges = true,
    this.changeRetention,
    this.pageCacheMiB = defaultPageCacheMiB,
    this.tempStoreInMemory = true,
    this.walAutoCheckpointPages = defaultWalAutoCheckpointPages,
    this.compactAfterUpgrade = true,
    this.onCompactionFailed,
    this.onMissingIndex = MissingIndexMode.throwError,
    this.isolate = CocoonIsolate.caller,
    this.autoThresholds = const CocoonAutoThresholds(),
  });

  /// The default hot-document cache size.
  static const int defaultCacheSize = 2000;

  /// The default SQLite page-cache budget ([pageCacheMiB]).
  static const int defaultPageCacheMiB = 64;

  /// The default WAL auto-checkpoint interval ([walAutoCheckpointPages]).
  static const int defaultWalAutoCheckpointPages = 8000;

  /// The `PRAGMA synchronous` level commits run at.
  final Durability durability;

  /// The bounded hot-document cache size, in documents. `0` disables the
  /// cache; reads then always hit SQLite.
  final int cacheSize;

  /// Whether every commit appends its change rows to the on-disk change log
  /// that [Cocoon.changesSince] reads.
  ///
  /// `true` (the default) keeps the log. `false` skips writing the rows —
  /// the log stays empty — while in-process watch notifications are
  /// unaffected; pick it when only `watch()` streams are needed.
  final bool keepChanges;

  /// An optional bound for the change log, enforced by the engine after
  /// commits (see [ChangeRetention]). `null` — the default — keeps every
  /// change row until the app calls [Cocoon.pruneChanges] itself.
  final ChangeRetention? changeRetention;

  /// Rows deleted per batched `DELETE` while enforcing
  /// [changeRetention], and the most rows one commit's enforcement may
  /// delete in total (more is left for the next commits, so a large
  /// backlog shrinks without stalling any single write).
  static const int defaultRetentionBatchRows = 2000;

  /// How many batched deletes one commit's retention enforcement may run
  /// ([defaultRetentionBatchRows] rows per batch).
  static const int defaultRetentionBatchStatements = 10;

  /// The SQLite page-cache budget in MiB, applied as
  /// `PRAGMA cache_size = -<MiB * 1024>` on the write connection. Reader
  /// connections keep SQLite's default (2 MiB each), so the extra memory is
  /// paid once, not once per pooled reader.
  ///
  /// SQLite's own 2 MiB default keeps only the hottest B-tree pages resident
  /// once a database outgrows it; a bigger cache is what keeps bulk imports
  /// into a multi-index table from degrading superlinearly (measured: 63 s
  /// -> 36 s for a 1M-document import with this default and
  /// [tempStoreInMemory], see `benchmarks/cocoon_rivals/IMPORT.md`). Values
  /// `<= 0` leave SQLite's default in place.
  final int pageCacheMiB;

  /// Whether temp B-trees (sorting, spilling index builds) stay in memory
  /// (`PRAGMA temp_store = MEMORY`) instead of spilling through temp
  /// storage, on the write connection (readers keep the default).
  ///
  /// Measured together with [pageCacheMiB] for the 1M import above. Turn it
  /// off only on devices where the extra resident memory hurts more than
  /// write throughput.
  final bool tempStoreInMemory;

  /// How many WAL pages accumulate before SQLite checkpoints them back into
  /// the database file (`PRAGMA wal_autocheckpoint`), applied on every
  /// writable connection the database opens.
  ///
  /// SQLite's default, 1000 pages (~4 MiB), checkpoints after nearly every
  /// commit of a bulk import into a multi-index table — the checkpoint cost
  /// grows with the database size and dominates a 1M-document import.
  /// Raising the interval to 8000 pages (32 MiB) halved that import (measured:
  /// 45.6 s -> ~19-24 s through the raw probe, see
  /// `benchmarks/cocoon_rivals/IMPORT.md`) while keeping the WAL bounded —
  /// unlike disabling checkpointing altogether, which grows the WAL without
  /// bound (4.2 GB measured) and was rejected. The WAL file therefore
  /// transiently holds up to ~32 MiB during heavy writes; crash safety is
  /// unchanged (the WAL is durable; checkpointing only moves pages into the
  /// database file, and a larger interval only costs some of that work at
  /// open after a crash). Values `<= 0` keep SQLite's default.
  final int walAutoCheckpointPages;

  /// Whether an open that upgraded the file's storage format compacts the
  /// file afterwards (a one-time `VACUUM`) when the upgrade left more than a
  /// fifth of the file on the freelist.
  ///
  /// A format upgrade rebuilds every collection table; the dropped tables'
  /// pages stay on the freelist until something reclaims them — measured on
  /// the 1M rivals file, 409 MB grew to 544 MB and stayed there until a
  /// compaction. On a phone that is wasted storage until the next backup, so
  /// by default the upgrade open compacts once after its transaction commits
  /// (see [onCompactionFailed] for the failure path — the open itself never
  /// fails over this). Normal opens are unaffected either way.
  final bool compactAfterUpgrade;

  /// Called when the post-upgrade compaction ([compactAfterUpgrade]) could
  /// not run — most often a full disk: `VACUUM` needs roughly the file size
  /// in free space. The file is left exactly as the upgrade made it, the
  /// open succeeds, and the freelist is reclaimed by the next `backupTo` (or
  /// any explicit `VACUUM`). `null` — the default — reports nothing.
  ///
  /// Delivered on the isolate that called [Cocoon.open], in every isolate
  /// mode.
  final void Function(Object error)? onCompactionFailed;

  /// How a query no declared index serves behaves:
  /// [MissingIndexMode.throwError] (the default) throws the
  /// `MissingIndexException` whose message carries the ready
  /// `dart run cocoon_generator:index add` command;
  /// [MissingIndexMode.scanAndWarn] is the debug-only fallback — the query
  /// runs as a full scan, the missing index is printed once per process and
  /// listed in [Cocoon.missingIndexes].
  ///
  /// `scanAndWarn` is honoured ONLY while asserts are enabled (debug and
  /// profile-with-asserts builds). In a release build it behaves exactly like
  /// [MissingIndexMode.throwError] regardless, so a forgotten
  /// `.allowFullScan()` can never silently degrade a shipped query. The
  /// fallback never creates an index at runtime.
  final MissingIndexMode onMissingIndex;

  /// Which isolate runs the engine ([CocoonIsolate.caller] by default — the
  /// behaviour of every earlier Cocoon version). [CocoonIsolate.background]
  /// moves decode/encode/planning/the write lock into one worker isolate;
  /// [CocoonIsolate.auto] keeps the engine on the caller and moves heavy
  /// reads and encodes to a helper. See [CocoonIsolate] and the docs page
  /// "Isolates".
  final CocoonIsolate isolate;

  /// The auto mode's routing thresholds; used only with
  /// [CocoonIsolate.auto].
  final CocoonAutoThresholds autoThresholds;
}

/// A typed, disk-backed, Firestore-style local database on SQLite.
///
/// Open it with the adapters of every collection the app stores, then work
/// through typed references:
///
/// ```dart
/// final db = await Cocoon.open(file, collections: [accounts, txns, splits]);
/// final a1 = db.collection(accounts).doc('a1');
/// await a1.set(Account(name: 'Acme', active: true));
/// final txRef = await a1.collection(txns).add(Txn(...));
/// final snap = await txRef.get();
/// await a1.delete(); // removes a1 and its whole subtree
/// ```
///
/// One `Cocoon` instance must own its database file: do not open the same
/// file from two instances (or processes) at once — the hot-document cache
/// and SQLite's write lock both assume a single writer.
///
/// By default the engine (document decode/encode, planning, the write lock,
/// the hot-document cache, watch notifications) runs on the isolate that
/// called [open] — in a Flutter app, the UI isolate. Apps with big pages,
/// bulk imports, heavy aggregates or 100k restores can move that work off
/// the UI isolate with one option, without changing any other call:
///
/// ```dart
/// final db = await Cocoon.open(
///   path,
///   collections: [...],
///   options: const CocoonOptions(isolate: CocoonIsolate.background),
/// );
/// ```
///
/// See [CocoonIsolate] (and the docs page "Isolates") for the three modes
/// and what they cost.
final class Cocoon {
  /// Builds a facade for the isolate plumbing: the background host and the
  /// auto open path install their runtime on it right after construction.
  @internal
  factory Cocoon.isolate({
    required SchemaRegistry registry,
    String? databasePath,
    SchemaLock? schemaLock,
    required String instanceId,
    required CocoonIsolate isolateMode,
  }) => Cocoon._(
    registry,
    databasePath: databasePath,
    schemaLock: schemaLock,
    instanceId: instanceId,
    isolateMode: isolateMode,
  );

  Cocoon._(
    this._registry, {
    this.databasePath,
    this.schemaLock,
    required this.instanceId,
    this.isolateMode = CocoonIsolate.caller,
  });

  /// The runtime behind this facade; set by the open paths before the
  /// facade escapes (the isolate plumbing replaces it for background and
  /// auto modes).
  @internal
  CocoonRuntime get runtime => _runtime;

  /// The engine behind this facade; set by the open paths before the
  /// facade escapes.
  @internal
  set runtime(CocoonRuntime runtime) => _runtime = runtime;

  /// The engine behind this facade.
  late CocoonRuntime _runtime;

  final SchemaRegistry _registry;

  /// The file path the database was opened from, or `null` when it was
  /// opened over a custom executor via [openWith]. Surfaced by the DevTools
  /// inspector's database list.
  @internal
  final String? databasePath;

  /// The schema lock the app handed to [open], or `null`. When present, the
  /// DevTools inspector's schema view can also show pinned field numbers
  /// and reserved numbers; without it, only what the engine knows.
  @internal
  final SchemaLock? schemaLock;

  /// The database instance's id: a random id created with the database and
  /// stored in `_cocoon_meta`, regenerated by [restoreBackup].
  ///
  /// Restoring replaces the database's contents with a snapshot whose change
  /// log and `lastChangeSeq` belong to an earlier point in time — a sync
  /// consumer's saved watermark may then be AHEAD of the database. The
  /// instance id is how consumers detect that: save it next to the
  /// watermark, and compare on the next open. Different ids mean the
  /// watermark must be discarded (or reconciled); within one instance the
  /// old guarantee holds unchanged — `lastChangeSeq` never goes backwards.
  final String instanceId;

  /// Which isolate mode this database was opened in.
  final CocoonIsolate isolateMode;

  /// The paths (in absolute form) of the databases currently open through
  /// [Cocoon.open] in this isolate. `restoreBackup` refuses a target in
  /// this set — swapping the file under an open database would corrupt it.
  static final Set<String> _openDatabasePaths = {};

  /// Opens (or creates) the database at [path] and reconciles the schema
  /// with [collections] inside one write transaction.
  ///
  /// The parent directory of [path] must exist. Throws an [ArgumentError]
  /// when the adapters are invalid (duplicate models, unknown index fields,
  /// a subcollection whose parent collection has no adapter, ...).
  ///
  /// With [schemaVersion] (the generated `cocoonSchemaVersion`) the open
  /// also tracks the schema version in `_cocoon_meta`: a fresh database just
  /// stores it, an older one runs every step of [migrations] with a greater
  /// version once, in order, in the same transaction, and a database written
  /// by a NEWER version refuses to open with a [SchemaTooNewException].
  /// [onMigrationProgress] reports `(documents processed, documents total)`
  /// per batch while the steps run — always on the isolate that called
  /// [open]. See the README's "Schema migrations".
  ///
  /// With [schemaLock] (the parsed `cocoon.lock`) the DevTools
  /// inspector's schema view can also show pinned field numbers and
  /// reserved numbers; without it, it shows only what the engine knows.
  ///
  /// With `options.isolate` the engine runs on the calling isolate (the
  /// default), in a dedicated worker isolate ([CocoonIsolate.background]),
  /// or on the calling isolate with a helper for heavy work
  /// ([CocoonIsolate.auto]). The returned [Cocoon] has the same API in
  /// every mode.
  static Future<Cocoon> open(
    String path, {
    required List<CollectionAdapter<Object?>> collections,
    CocoonOptions options = const CocoonOptions(),
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
  }) async {
    // Fail fast on an unusable retention policy or thresholds, before the
    // file is touched.
    options.changeRetention?.validate();
    options.autoThresholds.validate();
    if (options.isolate == CocoonIsolate.caller) {
      return openLocalFile(
        path,
        collections: collections,
        options: options,
        schemaVersion: schemaVersion,
        migrations: migrations,
        onMigrationProgress: onMigrationProgress,
        schemaLock: schemaLock,
        onCompactionFailed: options.onCompactionFailed,
      );
    }
    if (options.isolate == CocoonIsolate.auto) {
      return openAutoOnCaller(
        path,
        collections: collections,
        options: options,
        schemaVersion: schemaVersion,
        migrations: migrations,
        onMigrationProgress: onMigrationProgress,
        schemaLock: schemaLock,
      );
    }
    // background: the isolate plumbing owns the connections.
    return CocoonIsolateHost.open(
      path,
      collections: collections,
      options: options,
      schemaVersion: schemaVersion,
      migrations: migrations,
      onMigrationProgress: onMigrationProgress,
      schemaLock: schemaLock,
    );
  }

  /// Opens over an existing [executor]; used by tests to spy on statements.
  ///
  /// Same schema-version handling as [open]: see its [schemaVersion],
  /// [migrations] and [onMigrationProgress] documentation. [schemaLock] and
  /// [databasePath] are only surfaced to the DevTools inspector (a
  /// [schemaLock] is additionally fingerprinted into `_cocoon_meta` so
  /// backups can carry it), and [databasePath] registers the file as open
  /// so `restoreBackup` can refuse it.
  ///
  /// The engine here always runs on the calling isolate: the executor is an
  /// in-isolate object, so `options.isolate` other than
  /// [CocoonIsolate.caller] throws an [ArgumentError]. Use [open] (a file
  /// path) for background and auto mode.
  @visibleForTesting
  static Future<Cocoon> openWith(
    CocoonExecutor executor, {
    required List<CollectionAdapter<Object?>> collections,
    CocoonOptions options = const CocoonOptions(),
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
    String? databasePath,
  }) async {
    options.changeRetention?.validate();
    options.autoThresholds.validate();
    if (options.isolate != CocoonIsolate.caller) {
      throw ArgumentError.value(
        options.isolate,
        'options.isolate',
        'openWith runs the engine on the calling isolate: the executor is an '
        'in-isolate object a worker or helper isolate cannot reach. Pass '
        'CocoonIsolate.caller here, or use Cocoon.open (a file path) for '
        'CocoonIsolate.background and CocoonIsolate.auto.',
      );
    }
    return _openOverExecutor(
      executor,
      collections: collections,
      options: options,
      schemaVersion: schemaVersion,
      migrations: migrations,
      onMigrationProgress: onMigrationProgress,
      schemaLock: schemaLock,
      databasePath: databasePath,
      onCompactionFailed: options.onCompactionFailed,
    );
  }

  /// The caller-mode local open: the executor, the local runtime, the open
  /// transaction, the facade.
  @internal
  static Future<Cocoon> openLocalFile(
    String path, {
    required List<CollectionAdapter<Object?>> collections,
    required CocoonOptions options,
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
    void Function(Object error)? onCompactionFailed,
  }) async {
    final executor = _executorFor(path, options);
    final runtime = LocalCocoonRuntime(onCompactionFailed: onCompactionFailed);
    try {
      return await _openWithRuntime(
        executor,
        runtime,
        collections: collections,
        options: options,
        schemaVersion: schemaVersion,
        migrations: migrations,
        onMigrationProgress: onMigrationProgress,
        schemaLock: schemaLock,
        databasePath: path,
        isolateMode: options.isolate,
      );
    } on Object {
      await executor.close();
      rethrow;
    }
  }

  /// The auto mode's open path (the isolate host calls it): the engine
  /// opens on the caller exactly as caller mode does, then the auto runtime
  /// wraps it with the helper isolate. A helper that fails to spawn
  /// degrades the database to inline execution; the open itself never
  /// fails over it.
  @internal
  static Future<Cocoon> openAutoOnCaller(
    String path, {
    required List<CollectionAdapter<Object?>> collections,
    required CocoonOptions options,
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
  }) async {
    final executor = _executorFor(path, options);
    final local = LocalCocoonRuntime(
      onCompactionFailed: options.onCompactionFailed,
    );
    Cocoon db;
    try {
      db = await _openWithRuntime(
        executor,
        local,
        collections: collections,
        options: options,
        schemaVersion: schemaVersion,
        migrations: migrations,
        onMigrationProgress: onMigrationProgress,
        schemaLock: schemaLock,
        databasePath: path,
        isolateMode: CocoonIsolate.auto,
      );
    } on Object {
      await executor.close();
      rethrow;
    }
    // The engine is committed; wrap it with the auto router and spawn the
    // helper next to it (a failed spawn degrades to inline, logged).
    final helper = await spawnAutoHelper(path, collections);
    final auto = AutoCocoonRuntime(local, options.autoThresholds, helper);
    db._runtime = auto;
    auto.host = db;
    return db;
  }

  /// The SQLite connections a file-backed open builds.
  static SqliteExecutor _executorFor(String path, CocoonOptions options) =>
      SqliteExecutor(
        SqliteDatabase.withFactory(
          CocoonSqliteOpenFactory(
            path: path,
            sqliteOptions: SqliteOptions(
              synchronous: _synchronousOf(options.durability),
              // sqlite_async's dev-mode timeline tracing costs a TimelineTask
              // plus an arguments map per executed statement (measured: ~5 s
              // of a 100k-document import, see
              // benchmarks/cocoon_rivals/IMPORT.md). Cocoon's DevTools
              // integration does not use those events, so the engine opens
              // its connections with them off.
              profileQueries: false,
            ),
            pageCacheKib: options.pageCacheMiB <= 0
                ? 0
                : options.pageCacheMiB * 1024,
            tempStoreInMemory: options.tempStoreInMemory,
            walAutoCheckpointPages: options.walAutoCheckpointPages,
          ),
        ),
      );

  /// Builds the facade over an opened local runtime: registers the open
  /// path and attaches the DevTools inspector.
  static Future<Cocoon> _openWithRuntime(
    CocoonExecutor executor,
    LocalCocoonRuntime runtime, {
    required List<CollectionAdapter<Object?>> collections,
    required CocoonOptions options,
    required int? schemaVersion,
    required List<CocoonMigration> migrations,
    required void Function(int done, int total)? onMigrationProgress,
    required SchemaLock? schemaLock,
    required String? databasePath,
    required CocoonIsolate isolateMode,
  }) async {
    final registry = SchemaRegistry.build(collections);
    final instanceId = await runtime.open(
      executor,
      registry,
      options: options,
      schemaLock: schemaLock,
      schemaVersion: schemaVersion,
      migrations: migrations,
      onMigrationProgress: onMigrationProgress,
      databasePath: databasePath,
    );
    final db = Cocoon._(
      registry,
      databasePath: databasePath,
      schemaLock: schemaLock,
      instanceId: instanceId,
      isolateMode: isolateMode,
    ).._runtime = runtime;
    runtime.host = db;
    final openPath = databasePath;
    if (openPath != null) {
      registerOpenPath(openPath);
    }
    CocoonInspectorService.attach(db);
    return db;
  }

  /// The shared open path for an executor owned by this isolate (tests spy
  /// through it): builds the local runtime, runs the open transaction, then
  /// assembles the facade.
  static Future<Cocoon> _openOverExecutor(
    CocoonExecutor executor, {
    required List<CollectionAdapter<Object?>> collections,
    required CocoonOptions options,
    required int? schemaVersion,
    required List<CocoonMigration> migrations,
    required void Function(int done, int total)? onMigrationProgress,
    required SchemaLock? schemaLock,
    required String? databasePath,
    required void Function(Object error)? onCompactionFailed,
  }) => _openWithRuntime(
    executor,
    LocalCocoonRuntime(onCompactionFailed: onCompactionFailed),
    collections: collections,
    options: options,
    schemaVersion: schemaVersion,
    migrations: migrations,
    onMigrationProgress: onMigrationProgress,
    schemaLock: schemaLock,
    databasePath: databasePath,
    isolateMode: options.isolate,
  );

  /// Closes the database. Every watch stream this instance created
  /// completes; using references of a closed database throws. A query still
  /// waiting for a bulk writer's deferred indexes fails with a [StateError].
  Future<void> close() {
    CocoonInspectorService.detach(this);
    final openPath = databasePath;
    if (openPath != null) {
      _openDatabasePaths.remove(_absolutePath(openPath));
    }
    return _runtime.close();
  }

  /// Copies the whole database to [path] as one consistent, compacted
  /// backup, while the app keeps reading and writing.
  ///
  /// The copy is one read snapshot (SQLite's `VACUUM INTO`, which also
  /// compacts the file): every committed write is either fully in the copy
  /// or not at all, and the copy's change log, `lastChangeSeq`, schema
  /// version and bulk-writer state are exactly the snapshot's. The copy is
  /// written to `<path>.partial`, fsynced and renamed onto [path], so a
  /// failure leaves no file at [path] and removes the partial. An existing
  /// [path] is refused unless [overwrite]; with `overwrite: true` the
  /// previous file is still only replaced by the final atomic rename.
  ///
  /// The copy carries Cocoon's backup metadata in its `_cocoon_meta` table
  /// (format version, created-at, the snapshot's `lastChangeSeq`, schema
  /// version and lock hash, and the Cocoon version); `Cocoon.inspectBackup`
  /// reads it back. The app owns the policy around this — when to back up,
  /// where the file lives, compression, encryption — see the README's
  /// "Backup and restore".
  ///
  /// Throws [StateError] when this instance was opened over a custom
  /// executor (`openWith`) instead of a file, and [ArgumentError] when
  /// [path] exists and [overwrite] is false, or names the database file
  /// itself.
  Future<BackupInfo> backupTo(String path, {bool overwrite = false}) {
    final source = databasePath;
    if (source == null) {
      throw StateError(
        'backupTo needs a database opened with Cocoon.open; this instance '
        'was opened over a custom executor and has no file to copy',
      );
    }
    // A backup reads a committed snapshot: inside a transaction body it
    // would silently miss the transaction's own uncommitted writes.
    checkNotInTransaction(this, 'Cocoon.backupTo', read: true);
    return _runtime.backupTo(path, overwrite: overwrite);
  }

  /// Reads [path]'s backup metadata without touching its contents.
  ///
  /// Verifies that the file IS a Cocoon backup (the `_cocoon_meta` table
  /// with a backup marker) and that `PRAGMA integrity_check` passes, then
  /// reports format version, created-at, schema version/lock hash,
  /// `lastChangeSeq` and the Cocoon version that wrote it.
  ///
  /// Throws [ArgumentError] when the file does not exist,
  /// [NotCocoonBackupException] when it is not a Cocoon backup,
  /// [BackupDamagedException] when SQLite cannot read it or its metadata
  /// does not parse, and [BackupFormatTooNewException] when a newer app
  /// wrote it in an unknown format version.
  static Future<BackupInfo> inspectBackup(String path) =>
      BackupOperations.inspect(path);

  /// Restores the backup file at [backup] onto the database file at [path].
  ///
  /// The database at [path] must be CLOSED; a `Cocoon` still holding it
  /// open in this isolate is refused with a [StateError] (swapping the file
  /// under an open database would corrupt it). Then:
  ///
  /// 1. [inspectBackup] verifies and reads the backup (integrity included);
  /// 2. compatibility is checked against [collections] and [schemaVersion]
  ///    BEFORE the target file is touched — [SchemaRegistry] validation is
  ///    the same `open` runs, and a backup written by a NEWER schema is
  ///    refused with [SchemaTooNewException] (the same rule as [open]);
  ///    an older one is fine, its migrations run at the next `open`;
  /// 3. the backup is copied to `<path>.restoring`, fsynced, and the
  ///    current database moves to `<path>.before-restore` (with its WAL and
  ///    journal sidecars) when [keepPrevious] is set — the default — or is
  ///    deleted after the swap when not; stale `-wal`/`-shm`/`-journal`
  ///    files at the target path are removed and the copy is renamed onto
  ///    [path]. A failure at any point undoes everything and leaves the
  ///    original database usable.
  ///
  /// The restored database is a NEW instance: its instance id is
  /// regenerated, so sync consumers comparing [Cocoon.instanceId] with the
  /// one they saved will correctly distrust a watermark saved against the
  /// previous instance. The app then calls [open] as usual.
  ///
  /// A crash mid-restore (not an exception — the process dying) leaves the
  /// pieces on disk: no file at [path], the previous database at
  /// `<path>.before-restore` and the copy at `<path>.restoring`. Re-run the
  /// restore, or move a piece into place by hand.
  static Future<BackupInfo> restoreBackup({
    required String backup,
    required String path,
    required List<CollectionAdapter<Object?>> collections,
    int? schemaVersion,
    bool keepPrevious = true,
  }) async {
    _ensureNotOpen(path, 'restore a backup over it');
    _ensureNotOpen(backup, 'read a backup from it');
    final info = await BackupOperations.inspect(backup);
    // The same adapter validation `open` runs, before anything on disk
    // changes; the actual table reconciliation happens at the next open.
    SchemaRegistry.build(collections);
    if (schemaVersion != null) {
      // The same rule as open: a database (here, a backup) written by a
      // NEWER schema is refused; an older one migrates at the next open.
      final stored = info.schemaVersion ?? 0;
      if (stored > schemaVersion) {
        throw SchemaTooNewException(stored, schemaVersion);
      }
    }
    // The same rule for the storage layout: a backup written by a NEWER
    // storage format cannot be read by this engine, so refuse before the
    // target file is touched. An OLDER format is fine: the restored file's
    // tables are rebuilt at the next `Cocoon.open` (see the README's
    // "Backup and restore").
    final storedFormat = info.storageFormatVersion;
    if (storedFormat != null && storedFormat > storageFormatVersion) {
      throw StorageFormatTooNewException(
        path: backup,
        formatVersion: storedFormat,
        maxSupported: storageFormatVersion,
      );
    }
    return BackupOperations.restore(
      backupPath: backup,
      targetPath: path,
      keepPrevious: keepPrevious,
      info: info,
    );
  }

  static void _ensureNotOpen(String path, String what) {
    if (_openDatabasePaths.contains(_absolutePath(path))) {
      throw StateError(
        'Cannot $what: a Cocoon database is still open on $path in this '
        'isolate; close it first',
      );
    }
  }

  /// Registers [path] as open in this isolate (the isolate plumbing calls
  /// this for background and auto databases; the restore-backup guard reads
  /// the set).
  @internal
  static void registerOpenPath(String path) =>
      _openDatabasePaths.add(_absolutePath(path));

  static String _absolutePath(String path) => File(path).absolute.path;

  /// Starts a Firestore-style BulkWriter: queue `set`/`update`/`delete`
  /// synchronously, and the writer commits them in chunks of
  /// [BulkWriterOptions.chunkSize] rows — one write transaction per chunk,
  /// atomic per chunk, not atomic as a whole. `await bulk.close()` flushes
  /// the rest, rebuilds the deferred secondary indexes and resolves when
  /// everything is durable. See [BulkWriter] — this is the bulk-load path
  /// for imports far larger than [batch].
  ///
  /// Starting one inside a [runTransaction] body throws a
  /// [TransactionMisuseError]: its chunks would wait forever for the write
  /// lock the transaction holds. Queue through the transaction instead, or
  /// start the writer after `runTransaction` returns.
  BulkWriter bulkWriter([
    BulkWriterOptions options = const BulkWriterOptions(),
  ]) => _runtime.createBulkWriter(this, options);

  /// The root collection backed by a top-level [adapter].
  ///
  /// Throws an [ArgumentError] for a subcollection adapter; use
  /// `doc(...).collection(...)` for those.
  CollectionRef<V> collection<V extends Object>(CollectionAdapter<V> adapter) {
    final pattern = adapter.pattern;
    if (!pattern.isTopLevel) {
      throw ArgumentError.value(
        pattern.pattern,
        'adapter',
        'Only top-level collections can be used here; use '
            'doc(...).collection(...) for subcollections',
      );
    }
    _registry.entryFor(adapter);
    return CollectionRef<V>(this, adapter, pattern.resolve(const {}));
  }

  /// Starts a Firestore-style batch: queue `set`/`update`/`delete` calls
  /// synchronously, then `await batch.commit()` to run them all inside one
  /// write transaction. See [WriteBatch] — this is the bulk-write path.
  WriteBatch batch() => _runtime.createWriteBatch(this);

  /// Every document of [adapter]'s pattern, whatever parent it belongs to.
  CollectionGroupRef<V> collectionGroup<V extends Object>(
    CollectionAdapter<V> adapter,
  ) {
    _registry.entryFor(adapter);
    return CollectionGroupRef<V>(this, adapter);
  }

  /// Runs [body] inside one write transaction: reads see the transaction's
  /// own writes, and an exception rolls everything back — including the
  /// hot-document cache, which is only updated after a successful commit.
  ///
  /// Inside the body every database access goes through the
  /// [CocoonTransaction] object. A call on the database itself —
  /// `DocRef.set`/`get`/`delete`, `CollectionRef.add`, a query's
  /// `get`/`count`, `getAll`, `batch().commit()`, a `BulkWriter`, a nested
  /// [runTransaction] on this database — fails immediately with a
  /// [TransactionMisuseError] instead of waiting forever for the write lock
  /// the body already holds (writes) or silently reading committed data
  /// without the transaction's own writes (reads). Calls on a DIFFERENT
  /// open [Cocoon] (another database file) are allowed. Watching
  /// (`DocRef.watch`, a query's `watch`) is allowed; a watch's first value
  /// inside the body reflects committed data, and the transaction's writes
  /// arrive with its commit event.
  ///
  /// The body always runs on the isolate that called [runTransaction] (it
  /// is user code with captured state); the engine work behind each `tx`
  /// call follows the database's isolate mode. In every mode a body that
  /// throws rolls the transaction back and the error is rethrown here.
  Future<R> runTransaction<R>(Future<R> Function(CocoonTransaction tx) body) {
    if (currentScopeFor(this) != null) {
      return Future.error(TransactionMisuseError.nested());
    }
    final scope = TransactionScope(this);
    return runInTransactionScope(
      scope,
      () => _runtime.runTransactionBody<R>(
        (wtx) => body(CocoonTransaction(wtx)),
        txScope: scope,
      ),
    );
  }

  /// Every database of [refs] in as few trips as possible: results come
  /// back in the same order as [refs], `null` at every position whose
  /// document does not exist. Duplicate references are allowed — every
  /// position is answered.
  ///
  /// All references must share one model type [T] (they may span different
  /// parents and subcollections of it); passing `<DocRef<Object>>[...]`
  /// mixes models at the cost of an untyped [DocSnapshot.data]. An empty
  /// list answers immediately with an empty list, without SQL.
  ///
  /// Documents the bounded cache already holds answer without SQL; only the
  /// misses go to SQLite, grouped per table and fetched with one statement
  /// per [getAllChunkKeys] scope keys. Every chunk of one call runs inside
  /// ONE read transaction, so the whole answer is one consistent snapshot,
  /// and fetched documents populate the cache exactly like [DocRef.get]
  /// does. Reads by id never wait for a bulk writer's deferred indexes (the
  /// scope index is never deferred). Inside a transaction use
  /// [CocoonTransaction.getAll] instead — it also sees the transaction's own
  /// uncommitted writes.
  ///
  /// ```dart
  /// final snaps = await db.getAll([
  ///   for (final id in participantIds) a1.collection(txns).doc(id),
  /// ]);
  /// ```
  Future<List<DocSnapshot<T>?>> getAll<T extends Object>(
    List<DocRef<T>> refs,
  ) async {
    checkNotInTransaction(this, 'Cocoon.getAll', read: true);
    if (refs.isEmpty) {
      return const [];
    }
    return _runtime.getAll<T>(refs);
  }

  /// How many documents the hot-document cache currently holds (a message
  /// in background mode).
  @visibleForTesting
  Future<int> get debugCacheLength => _runtime.debugCacheLength;

  /// How many watch streams are currently registered (listening) — a
  /// message in background mode.
  @visibleForTesting
  Future<int> get debugWatcherCount => _runtime.debugWatcherCount;

  /// Returns the change-log rows newer than [seq], oldest first.
  ///
  /// Every committed write appends one row per touched document — including
  /// one row per cascaded delete — in the same transaction as the write.
  /// Returns at most [limit] rows; keep calling with the last row's
  /// [Change.seq] until the list comes back empty. With
  /// `CocoonOptions.keepChanges` disabled the log is never written and this
  /// always returns an empty list.
  ///
  /// Throws a [ChangesPrunedException] when [seq] predates the log's pruned
  /// floor ([earliestChangeSeq] - 1): the changes between [seq] and the
  /// floor are gone, so a sync consumer must resync fully instead of
  /// silently skipping them.
  Future<List<Change>> changesSince(int seq, {int limit = 1000}) =>
      _runtime.changesSince(seq, limit: limit);

  /// The oldest change seq still readable from the log: the lowest [seq]
  /// present, or `lastChangeSeq() + 1` when the log is empty (nothing was
  /// ever logged, or everything logged was pruned).
  Future<int> earliestChangeSeq() => _runtime.earliestChangeSeq();

  /// The highest seq ever assigned to a change, or `0` when nothing was
  /// logged yet.
  ///
  /// It never goes backwards: pruning and retention remove rows but the
  /// AUTOINCREMENT head in `sqlite_sequence` (where this value lives, not
  /// in `MAX(seq)`) is never rewound, so a sync outbox can compare its own
  /// watermark against it at any time.
  Future<int> lastChangeSeq() => _runtime.lastChangeSeq();

  /// Deletes every change row with `seq <= upToSeq`, returning how many
  /// rows were removed.
  ///
  /// Call it once changes are durably processed elsewhere (synced, audited);
  /// the log would otherwise grow forever. `lastChangeSeq()` does not move
  /// — a consumer that reads from a seq below the new floor
  /// ([earliestChangeSeq]) gets a [ChangesPrunedException] and knows to
  /// resync, never a silent gap.
  Future<int> pruneChanges({required int upToSeq}) =>
      _runtime.pruneChanges(upToSeq: upToSeq);

  /// The auto mode's counters since the database opened (inline vs helper
  /// calls, approximate helper bytes moved), or `null` outside
  /// [CocoonIsolate.auto]. See [CocoonIsolateStats].
  CocoonIsolateStats? get isolateStats => _runtime.isolateStats;

  /// The hub every live watch registers with.
  @internal
  WatchHub get watchHub => _runtime.watchHub;

  /// The schema registry (adapters, tables, columns, indexes) behind this
  /// database; read by the DevTools inspector.
  @internal
  SchemaRegistry get registry => _registry;

  /// The raw executor; used by the DevTools inspector for its read-only
  /// SQL (`EXPLAIN QUERY PLAN`, `PRAGMA table_info`, `sqlite_master`) and
  /// by the bulk writer's deferred-index rebuild. Only a database whose
  /// engine runs in this isolate has one; a background-mode proxy throws.
  @internal
  CocoonExecutor get executor => _runtime.executor;

  /// The isolate mode this database runs in, as a name for the inspector's
  /// database list: `caller`, `background` or `auto`.
  @internal
  String get isolateModeName => isolateMode.name;

  // -- Engine internals (forwarded to the runtime) ---------------------------

  /// Runs [body] in one write transaction, applying its staged cache updates
  /// only after the commit succeeds, then delivers one commit event with the
  /// touched paths to the watch hub. Rolled-back transactions report nothing.
  ///
  /// Document writes buffer in the transaction's [WriteTx] and flush as
  /// batched statements before the COMMIT (and before any read or delete in
  /// the same transaction, and every [writeFlushThreshold] rows).
  ///
  /// With `logChanges: false` the transaction appends no change-log rows
  /// (a [BulkWriter] chunk can opt out); watch notifications and cache
  /// updates are unaffected. After the commit — never inside it — the
  /// change log's [CocoonOptions.changeRetention] bound is enforced in
  /// small batches.
  @internal
  Future<R> writeTx<R>(
    Future<R> Function(CocoonWriteTx wtx) body, {
    bool logChanges = true,
    TransactionScope? txScope,
  }) => _runtime.writeTx<R>(body, logChanges: logChanges, txScope: txScope);

  /// The live stream behind [DocRef.watch].
  @internal
  Stream<DocSnapshot<T>?> watchDoc<T extends Object>(DocRef<T> ref) =>
      _runtime.watchDoc<T>(ref);

  /// The live stream behind [CocoonQuery.watch].
  @internal
  Stream<QueryPage<T>> watchQuery<T extends Object>(CocoonQuery<T> query) =>
      _runtime.watchQuery<T>(query);

  @internal
  Future<DocSnapshot<T>?> getDoc<T extends Object>(DocRef<T> ref) =>
      _runtime.getDoc<T>(ref);

  @internal
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonRead tx,
    DocRef<T> ref,
  ) => _runtime.readDocInTx<T>(tx, ref);

  /// Scope keys bound per `getAll` SELECT, per table per statement. Chosen
  /// by measurement on the 1M rivals dataset
  /// (`benchmarks/cocoon_rivals/GETALL.md`); the widest collections bind
  /// a few thousand placeholders per statement, far under SQLite's variable
  /// limit, and one chunk stays a single fast index scan.
  @internal
  static const int getAllChunkKeys = 500;

  /// [getAll]'s engine inside a transaction: reads through [tx] — seeing the
  /// transaction's own writes exactly like [readDocInTx] — never the cache,
  /// and caches nothing (a transaction's cache updates stay staged until its
  /// commit succeeds). Answers in [refs] order, `null` for missing
  /// documents, duplicates allowed.
  @internal
  Future<List<DocSnapshot<T>?>> getAllDocsInTx<T extends Object>(
    CocoonRead tx,
    List<DocRef<T>> refs,
  ) => _runtime.getAllDocsInTx<T>(tx, refs);

  @internal
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value) =>
      _runtime.putDoc<T>(ref, value);

  @internal
  Future<DocRef<T>> addDoc<T extends Object>(CollectionRef<T> ref, T value) =>
      _runtime.addDoc<T>(ref, value);

  @internal
  Future<void> deleteDoc(DocRef<Object> ref) => _runtime.deleteDoc(ref);

  /// Deletes the one row of [table] (via [entry]) identified by the scope
  /// key [paramValues] + [id], returning its `(table, path)` pair only when
  /// a row was actually removed. The path is derived from the deleted row's
  /// key columns.
  @internal
  Future<List<(String, String)>> deleteRow(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
    String id,
  ) => _runtime.deleteRow(tx, entry, paramValues, id);

  /// Deletes every row of [entry]'s table whose leading param columns match
  /// [paramValues] — the whole subtree of the document whose ancestor scope
  /// those values are — returning one `(table, path)` pair per removed row,
  /// path derived from each row's key columns.
  @internal
  Future<List<(String, String)>> deleteScopePrefix(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
  ) => _runtime.deleteScopePrefix(tx, entry, paramValues);

  /// Whether every commit appends its change rows to the on-disk log.
  @internal
  bool get keepsChanges => _runtime.keepsChanges;

  /// The missing indexes that [MissingIndexMode.scanAndWarn] queries of this
  /// database have run over, first hit first: the model, the index parts to
  /// declare, the query shape, the ready fix command and when it was first
  /// seen. One report per distinct missing index. Filled only while asserts
  /// are enabled — a release build throws instead, so the list stays empty.
  ///
  /// The debug fallback never creates an index: run the report's
  /// `fixCommand` in the project, then `dart run cocoon_generator:migrate`
  /// and `dart run build_runner build -d`.
  List<MissingIndexReport> get missingIndexes => _runtime.missingIndexes;

  @internal
  Future<QueryPage<T>> runQuery<T extends Object>(CocoonQuery<T> query) =>
      _runtime.runQuery<T>(query);

  /// Runs [query], also returning each document's stored wire bytes in page
  /// order — the signature query watches deduplicate pages by.
  ///
  /// A query whose plan needs an index a bulk writer currently has deferred
  /// waits until the writer rebuilds it, then runs.
  @internal
  Future<(QueryPage<T>, List<Uint8List>)> runQueryWithBytes<T extends Object>(
    CocoonQuery<T> query,
  ) => _runtime.runQueryWithBytes<T>(query);

  @internal
  Future<int> runCount<T extends Object>(CocoonQuery<T> query) =>
      _runtime.runCount<T>(query);

  /// Runs an [AggregateQuery]: one statement over the mirrored columns, no
  /// documents decoded.
  ///
  /// A plan whose serving index a bulk writer currently has deferred waits
  /// until the writer rebuilds it, then runs — exactly like a query.
  @internal
  Future<AggregateQuerySnapshot<T>> runAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) => _runtime.runAggregate<T>(aggregate);

  /// Runs a group-by query: one statement, one [AggregateGroup] per row.
  ///
  /// Waits for deferred bulk-writer indexes exactly like [runAggregate].
  @internal
  Future<List<AggregateGroup<T>>> runGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) => _runtime.runGroupAggregate<T>(aggregate);

  /// The live stream behind [AggregateQuery.watch].
  @internal
  Stream<AggregateQuerySnapshot<T>> watchAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) => _runtime.watchAggregate<T>(aggregate);

  /// The live stream behind [AggregateGroupQuery.watch].
  @internal
  Stream<List<AggregateGroup<T>>> watchGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) => _runtime.watchGroupAggregate<T>(aggregate);

  // -- Bulk-writer deferred indexes ----------------------------------------

  /// Registers a live bulk writer (for the deferred-index accounting).
  @internal
  void noteBulkWriterActive() => _runtime.noteBulkWriterActive();

  /// Unregisters a finished bulk writer.
  @internal
  void noteBulkWriterClosed() => _runtime.noteBulkWriterClosed();

  /// Marks [indexNames] as dropped by a bulk writer: queries whose plan
  /// needs one of them wait until they are rebuilt.
  @internal
  void noteIndexesDeferred(Iterable<String> indexNames) =>
      _runtime.noteIndexesDeferred(indexNames);

  /// Marks [indexNames] as rebuilt by a bulk writer's close, releasing the
  /// queries that waited for them.
  @internal
  void noteIndexesRestored(Iterable<String> indexNames) =>
      _runtime.noteIndexesRestored(indexNames);

  /// Resolves when [servingIndex] is no longer deferred by a bulk writer
  /// (immediately when it never was). Queries call this between planning
  /// and execution.
  @internal
  Future<void> waitForBulkIndexes(String? servingIndex) =>
      _runtime.waitForBulkIndexes(servingIndex);

  @internal
  List<String> paramValuesInOrder(RegistryEntry entry, CollectionPath path) =>
      _runtime.paramValuesInOrder(entry, path);

  // -- Engine statics shared with the runtime -------------------------------

  /// Creates the `_cocoon_meta` table when missing, inside the open or a
  /// write transaction.
  @internal
  static Future<void> createMetaTableIfMissing(CocoonTx tx) async {
    final exists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [metaTableName],
    );
    if (exists == null) {
      await tx.execute(createMetaTableSql());
    }
  }

  /// Creates the `_cocoon_changes` table when missing, inside the open or a
  /// write transaction.
  @internal
  static Future<void> createChangesTableIfMissing(CocoonTx tx) async {
    final exists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [changesTableName],
    );
    if (exists == null) {
      await tx.execute(createChangesTableSql());
    }
  }

  /// The freelist share above which the post-upgrade compaction runs: the
  /// check is `freelist * compactFreelistDenominator > pages`, so the
  /// default (5) compacts when MORE than a fifth of the file is reclaimable.
  ///
  /// Below that the one-time `VACUUM` rewrite of the whole file is not worth
  /// the reclaimed bytes; the next `backupTo` compacts anyway.
  @visibleForTesting
  static const int compactFreelistDenominator = 5;

  static SqliteSynchronous _synchronousOf(Durability durability) =>
      switch (durability) {
        Durability.full => SqliteSynchronous.full,
        Durability.normal => SqliteSynchronous.normal,
      };
}
