import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import '../cursor.dart';
import '../id.dart' show newDocId;
import '../inspector/service.dart';
import '../migration.dart';
import '../path.dart';
import '../schema.dart';
import 'adapter.dart';
import 'aggregate.dart';
import 'backup.dart';
import 'batch.dart';
import 'bulk_writer.dart';
import 'cache.dart';
import 'changes.dart';
import 'executor.dart';
import 'format_migration.dart';
import 'migrate.dart';
import 'naming.dart';
import 'query.dart';
import 'refs.dart';
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
final class Cocoon {
  Cocoon._(
    this._executor,
    this._registry,
    this._cache,
    this._keepChanges,
    this._changeRetention, {
    this.databasePath,
    this.schemaLock,
    required this.instanceId,
    MissingIndexMode missingIndexMode = MissingIndexMode.throwError,
  }) : _missingIndexMode = missingIndexMode;

  final CocoonExecutor _executor;
  final SchemaRegistry _registry;
  final DocumentCache _cache;
  final bool _keepChanges;
  final ChangeRetention? _changeRetention;

  /// The configured behaviour for queries no index serves: the debug
  /// scanAndWarn fallback is honoured only while asserts are enabled.
  final MissingIndexMode _missingIndexMode;

  /// The missing indexes scanAndWarn queries of this database have hit, by
  /// fix command; exposed through [missingIndexes].
  final Map<String, MissingIndexReport> _missingIndexes = {};

  final WatchHub _watchHub = WatchHub();

  /// The paths (in absolute form) of the databases currently open through
  /// [Cocoon.open] in this isolate. `restoreBackup` refuses a target in
  /// this set — swapping the file under an open database would corrupt it.
  static final Set<String> _openDatabasePaths = {};

  /// Secondary indexes currently dropped by running bulk writers, as
  /// name -> active-writer count; queries whose plan needs one of them wait
  /// until the count reaches zero.
  final Map<String, int> _deferredIndexCounts = {};

  /// Live bulk writers (for the deferred-index accounting).
  var _bulkWriters = 0;

  /// Queries waiting for deferred indexes to come back.
  final List<({Set<String> needed, Completer<void> completer})> _bulkWaiters =
      [];

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
  /// per batch while the steps run. See the README's "Schema migrations".
  ///
  /// With [schemaLock] (the parsed `cocoon.lock`) the DevTools
  /// inspector's schema view can also show pinned field numbers and
  /// reserved numbers; without it, it shows only what the engine knows.
  static Future<Cocoon> open(
    String path, {
    required List<CollectionAdapter<Object?>> collections,
    CocoonOptions options = const CocoonOptions(),
    int? schemaVersion,
    List<CocoonMigration> migrations = const [],
    void Function(int done, int total)? onMigrationProgress,
    SchemaLock? schemaLock,
  }) async {
    final executor = SqliteExecutor(
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
    try {
      return await openWith(
        executor,
        collections: collections,
        options: options,
        schemaVersion: schemaVersion,
        migrations: migrations,
        onMigrationProgress: onMigrationProgress,
        schemaLock: schemaLock,
        databasePath: path,
      );
    } on Object {
      await executor.close();
      rethrow;
    }
  }

  /// Opens over an existing [executor]; used by tests to spy on statements.
  ///
  /// Same schema-version handling as [open]: see its [schemaVersion],
  /// [migrations] and [onMigrationProgress] documentation. [schemaLock] and
  /// [databasePath] are only surfaced to the DevTools inspector (a
  /// [schemaLock] is additionally fingerprinted into `_cocoon_meta` so
  /// backups can carry it), and [databasePath] registers the file as open
  /// so `restoreBackup` can refuse it.
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
    final registry = SchemaRegistry.build(collections);
    // Fail fast on an unusable retention policy, before the file is touched.
    options.changeRetention?.validate();
    var upgradedFormat = false;
    final instanceId = await executor.writeTransaction((tx) async {
      await _createMetaTableIfMissing(tx);
      await _createChangesTableIfMissing(tx);
      final instanceId = await _ensureInstanceId(tx);
      // The file's storage layout is brought up to the engine's before the
      // schema versions run: the format rebuild is shape-preserving, and
      // the migration runner and reconciler both assume the current layout.
      upgradedFormat = await _applyStorageFormat(
        tx,
        onMigrationProgress: onMigrationProgress,
        databasePath: databasePath ?? '',
      );
      if (schemaLock != null) {
        await tx.execute(
          'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
          [
            schemaLockHashMetaKey,
            queryFingerprint(jsonEncode(schemaLock.toJson())),
          ],
        );
      }
      final migratedTables = await _applySchemaVersion(
        tx,
        registry,
        schemaVersion: schemaVersion,
        migrations: migrations,
        keepChanges: options.keepChanges,
        onMigrationProgress: onMigrationProgress,
      );
      await _reconcile(tx, registry, forceTables: migratedTables);
      // A crashed bulk writer leaves its deferred indexes recorded in
      // `_cocoon_bulk`; rebuild them before the app sees the database.
      await _recoverBulkIndexes(tx, registry);
      return instanceId;
    });
    if (upgradedFormat && options.compactAfterUpgrade) {
      // The upgrade's dropped tables left their pages on the freelist;
      // reclaim them now, outside the open transaction, so a phone does not
      // carry the waste until its next backup. Never fails the open.
      await _compactAfterFormatUpgrade(executor, options.onCompactionFailed);
    }
    final db = Cocoon._(
      executor,
      registry,
      DocumentCache(options.cacheSize),
      options.keepChanges,
      options.changeRetention,
      databasePath: databasePath,
      schemaLock: schemaLock,
      instanceId: instanceId,
      missingIndexMode: options.onMissingIndex,
    );
    final openPath = databasePath;
    if (openPath != null) {
      _openDatabasePaths.add(_absolutePath(openPath));
    }
    CocoonInspectorService.attach(db);
    return db;
  }

  /// Closes the database. Every watch stream this instance created
  /// completes; using references of a closed database throws. A query still
  /// waiting for a bulk writer's deferred indexes fails with a [StateError].
  Future<void> close() {
    CocoonInspectorService.detach(this);
    final openPath = databasePath;
    if (openPath != null) {
      _openDatabasePaths.remove(_absolutePath(openPath));
    }
    _watchHub.close();
    for (final waiter in _bulkWaiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(
          StateError(
            'The database was closed while this query waited for a '
            'BulkWriter to finish',
          ),
        );
      }
    }
    _bulkWaiters.clear();
    return _executor.close();
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
    return BackupOperations.backupTo(
      sourcePath: source,
      targetPath: path,
      overwrite: overwrite,
    );
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

  static String _absolutePath(String path) => File(path).absolute.path;

  /// Returns the database's instance id, creating one (a fresh
  /// [newDocId]) when the file predates instance ids, inside the open
  /// transaction so creation is atomic with the rest of the open.
  static Future<String> _ensureInstanceId(CocoonTx tx) async {
    final row = await tx.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      [instanceIdMetaKey],
    );
    final stored = row?['value'];
    if (stored is String && stored.isNotEmpty) {
      return stored;
    }
    final id = newDocId();
    await tx.execute(
      'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
      [instanceIdMetaKey, id],
    );
    return id;
  }

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
  ]) {
    checkNotInTransaction(this, 'Cocoon.bulkWriter', read: false);
    return BulkWriter(this, options);
  }

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
  WriteBatch batch() => WriteBatch(this);

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
  Future<R> runTransaction<R>(Future<R> Function(CocoonTransaction tx) body) {
    if (currentScopeFor(this) != null) {
      return Future.error(TransactionMisuseError.nested());
    }
    final scope = TransactionScope(this);
    return runInTransactionScope(
      scope,
      () => writeTx<R>((wtx) => body(CocoonTransaction(wtx)), txScope: scope),
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
    final snapshots = List<DocSnapshot<T>?>.filled(refs.length, null);
    final pending = <String, _PendingDoc>{};
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      final entry = _registry.entryFor(ref.adapter);
      final path = ref.path.path;
      final cached = _cache.get(path);
      if (cached != null) {
        // A write cached the encoded bytes; decode once and promote the
        // value, so what a later read sees is exactly what the stored bytes
        // decode to — the same contract as [getDoc].
        if (cached is EncodedDoc) {
          final value = entry.adapter.decode(cached.bytes) as T;
          _cache.put(path, value);
          snapshots[i] = DocSnapshot<T>(ref, value);
        } else {
          snapshots[i] = DocSnapshot<T>(ref, cached as T);
        }
        continue;
      }
      _addPendingDoc(pending, entry, path, i);
    }
    if (pending.isEmpty) {
      return snapshots;
    }
    await _executor.readTransaction(
      (reader) =>
          _fillFromTables<T>(reader, pending, refs, snapshots, cachePut: true),
    );
    return snapshots;
  }

  /// How many documents the hot-document cache currently holds.
  @visibleForTesting
  int get debugCacheLength => _cache.length;

  /// How many watch streams are currently registered (listening).
  @visibleForTesting
  int get debugWatcherCount => _watchHub.length;

  /// The hub every live watch registers with.
  @internal
  WatchHub get watchHub => _watchHub;

  /// The schema registry (adapters, tables, columns, indexes) behind this
  /// database; read by the DevTools inspector.
  @internal
  SchemaRegistry get registry => _registry;

  /// The raw executor; used by the DevTools inspector for its read-only
  /// SQL (`EXPLAIN QUERY PLAN`, `PRAGMA table_info`, `sqlite_master`).
  @internal
  CocoonExecutor get executor => _executor;

  // -- Engine internals ----------------------------------------------------

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
    Future<R> Function(WriteTx wtx) body, {
    bool logChanges = true,
    TransactionScope? txScope,
  }) async {
    final stage = CacheStage();
    final result = await _endGuardAfter(
      txScope,
      () => _executor.writeTransaction((tx) async {
        final wtx = WriteTx(this, tx, stage, logChanges: logChanges);
        final out = await body(wtx);
        await wtx.flush();
        return out;
      }),
    );
    stage.applyTo(_cache);
    final touched = stage.takeTouched();
    if (touched.isNotEmpty) {
      _watchHub.emit(CommitEvent(touched));
    }
    if (_changeRetention != null && touched.isNotEmpty) {
      await _enforceChangeRetention();
    }
    return result;
  }

  /// Runs [action] and deactivates [scope] the moment it settles: the SQL
  /// transaction inside has then ended (commit OR rollback), before the
  /// cache apply, watch emit and retention that follow the commit — so
  /// futures and timers the transaction body created that run later never
  /// trip the guard.
  Future<R> _endGuardAfter<R>(
    TransactionScope? scope,
    Future<R> Function() action,
  ) async {
    try {
      return await action();
    } finally {
      scope?.deactivate();
    }
  }

  /// The live stream behind [DocRef.watch].
  @internal
  Stream<DocSnapshot<T>?> watchDoc<T extends Object>(DocRef<T> ref) {
    final table = _registry.entryFor(ref.adapter).table;
    return DocWatch<T>(this, ref, table).stream;
  }

  /// The live stream behind [CocoonQuery.watch].
  @internal
  Stream<QueryPage<T>> watchQuery<T extends Object>(CocoonQuery<T> query) {
    final spec = query.spec;
    final table = _registry.entryFor(spec.adapter).table;
    return QueryWatch<T>(this, query, table, spec.scopePath).stream;
  }

  @internal
  Future<DocSnapshot<T>?> getDoc<T extends Object>(DocRef<T> ref) async {
    final entry = _registry.entryFor(ref.adapter);
    final cached = _cache.get(ref.path.path);
    if (cached != null) {
      // A write cached the encoded bytes; decode once and promote the value,
      // so the decoded object a later read sees is exactly what the stored
      // bytes decode to.
      if (cached is EncodedDoc) {
        final value = entry.adapter.decode(cached.bytes) as T;
        _cache.put(ref.path.path, value);
        return DocSnapshot<T>(ref, value);
      }
      return DocSnapshot<T>(ref, cached as T);
    }
    return _readDoc<T>(_executor, ref, cachePut: true);
  }

  @internal
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonTx tx,
    DocRef<T> ref,
  ) => _readDoc<T>(tx, ref, cachePut: false);

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
    CocoonTx tx,
    List<DocRef<T>> refs,
  ) async {
    if (refs.isEmpty) {
      return const [];
    }
    final snapshots = List<DocSnapshot<T>?>.filled(refs.length, null);
    final pending = <String, _PendingDoc>{};
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      _addPendingDoc(
        pending,
        _registry.entryFor(ref.adapter),
        ref.path.path,
        i,
      );
    }
    await _fillFromTables<T>(tx, pending, refs, snapshots, cachePut: false);
    return snapshots;
  }

  @internal
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value) =>
      writeTx<void>((wtx) => wtx.put(ref, value));

  @internal
  Future<DocRef<T>> addDoc<T extends Object>(CollectionRef<T> ref, T value) =>
      writeTx<DocRef<T>>((wtx) => wtx.add(ref, value));

  @internal
  Future<void> deleteDoc(DocRef<Object> ref) =>
      writeTx<void>((wtx) => wtx.delete(ref));

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
  ) async {
    final where = [
      for (var i = 0; i < entry.paramSqlNames.length; i++)
        '${entry.paramSqlNames[i]} = ?',
      'id = ?',
    ].join(' AND ');
    final returning = [...entry.paramSqlNames, 'id'].join(', ');
    final rows = await tx.getAll(
      'DELETE FROM ${entry.table} WHERE $where RETURNING $returning',
      [...paramValues, id],
    );
    return [for (final row in rows) (entry.table, entry.pathOfKeyRow(row))];
  }

  /// Deletes every row of [entry]'s table whose leading param columns match
  /// [paramValues] — the whole subtree of the document whose ancestor scope
  /// those values are — returning one `(table, path)` pair per removed row,
  /// path derived from each row's key columns.
  @internal
  Future<List<(String, String)>> deleteScopePrefix(
    CocoonTx tx,
    RegistryEntry entry,
    List<String> paramValues,
  ) async {
    if (paramValues.isEmpty ||
        paramValues.length > entry.paramSqlNames.length) {
      throw ArgumentError.value(
        paramValues,
        'paramValues',
        'Not a subtree prefix of collection ${entry.adapter.pattern}',
      );
    }
    final where = [
      for (var i = 0; i < paramValues.length; i++)
        '${entry.paramSqlNames[i]} = ?',
    ].join(' AND ');
    final returning = [...entry.paramSqlNames, 'id'].join(', ');
    final rows = await tx.getAll(
      'DELETE FROM ${entry.table} WHERE $where RETURNING $returning',
      paramValues,
    );
    return [for (final row in rows) (entry.table, entry.pathOfKeyRow(row))];
  }

  /// Whether every commit appends its change rows to the on-disk log.
  @internal
  bool get keepsChanges => _keepChanges;

  /// The missing indexes that [MissingIndexMode.scanAndWarn] queries of this
  /// database have run over, first hit first: the model, the index parts to
  /// declare, the query shape, the ready fix command and when it was first
  /// seen. One report per distinct missing index. Filled only while asserts
  /// are enabled — a release build throws instead, so the list stays empty.
  ///
  /// The debug fallback never creates an index: run the report's
  /// `fixCommand` in the project, then `dart run cocoon_generator:migrate`
  /// and `dart run build_runner build -d`.
  List<MissingIndexReport> get missingIndexes =>
      List.unmodifiable(_missingIndexes.values);

  /// The scanAndWarn decision for a query no index serves: record the report
  /// on this database, print the message (with its `Fix:` line) once per
  /// distinct missing index per process, and run the query as a full scan.
  bool _acceptMissingIndexScan(
    MissingIndexException error, {
    required String model,
    required List<String> fields,
    required String queryShape,
  }) {
    if (_missingIndexMode != MissingIndexMode.scanAndWarn ||
        !missingIndexScanPossible) {
      return false;
    }
    final command = error.fixCommand!;
    _missingIndexes.putIfAbsent(
      command,
      () => MissingIndexReport(
        model: model,
        fields: fields,
        query: queryShape,
        fixCommand: command,
        firstSeen: DateTime.now(),
      ),
    );
    warnMissingIndexOnce(error);
    return true;
  }

  @internal
  Future<QueryPage<T>> runQuery<T extends Object>(CocoonQuery<T> query) async =>
      (await runQueryWithBytes<T>(query)).$1;

  /// Runs [query], also returning each document's stored wire bytes in page
  /// order — the signature query watches deduplicate pages by.
  ///
  /// A query whose plan needs an index a bulk writer currently has deferred
  /// waits until the writer rebuilds it, then runs.
  @internal
  Future<(QueryPage<T>, List<Uint8List>)> runQueryWithBytes<T extends Object>(
    CocoonQuery<T> query,
  ) async {
    final spec = query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planQuery(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: spec.limit,
      cursor: spec.startAfter,
      fullScan: spec.fullScan,
      onMissingIndex: _acceptMissingIndexScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await _executor.getAll(plan.sql, plan.args);
    final limit = spec.limit;
    var pageRows = rows;
    String? nextCursor;
    if (limit != null && rows.length > limit) {
      pageRows = rows.sublist(0, limit);
      // Cursor keys follow the effective order: the sort-key SQL values and
      // the document id last, as the tiebreaker.
      final last = pageRows.last;
      final keys = [
        for (final column in plan.cursorColumns) last[column]!,
        last['id']!,
      ];
      nextCursor = CursorCodec.encode(plan.fingerprint, keys);
    }
    final docs = <DocSnapshot<T>>[
      for (final row in pageRows) _snapshotFromRow<T>(entry, row),
    ];
    final bytes = <Uint8List>[
      for (final row in pageRows) row['data']! as Uint8List,
    ];
    return (QueryPage<T>(docs, nextCursor), bytes);
  }

  @internal
  Future<int> runCount<T extends Object>(CocoonQuery<T> query) async {
    // Sugar for `aggregate([count()])`: the same planner, the same index
    // rule, the same one-statement execution, identical results.
    final snapshot = await runAggregate<T>(
      AggregateQuery<T>(query, [count<T>()]),
    );
    return snapshot.count;
  }

  /// Runs an [AggregateQuery]: one statement over the mirrored columns, no
  /// documents decoded.
  ///
  /// A plan whose serving index a bulk writer currently has deferred waits
  /// until the writer rebuilds it, then runs — exactly like a query.
  @internal
  Future<AggregateQuerySnapshot<T>> runAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) async {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planAggregate(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: spec.limit,
      fullScan: spec.fullScan,
      specs: aggregate.specs,
      onMissingIndex: _acceptMissingIndexScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await _executor.getAll(plan.sql, plan.args);
    return aggregateSnapshotFromRow<T>(aggregate.specs, rows.single);
  }

  /// Runs a group-by query: one statement, one [AggregateGroup] per row.
  ///
  /// Waits for deferred bulk-writer indexes exactly like [runAggregate].
  @internal
  Future<List<AggregateGroup<T>>> runGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) async {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planGroupAggregate(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: aggregate.maxGroups,
      fullScan: spec.fullScan,
      keys: aggregate.keys,
      specs: aggregate.specs,
      onMissingIndex: _acceptMissingIndexScan,
    );
    await waitForBulkIndexes(plan.servingIndex);
    final rows = await _executor.getAll(plan.sql, plan.args);
    return aggregateGroupsFromRows<T>(aggregate.keys, aggregate.specs, rows);
  }

  /// The live stream behind [AggregateQuery.watch].
  @internal
  Stream<AggregateQuerySnapshot<T>> watchAggregate<T extends Object>(
    AggregateQuery<T> aggregate,
  ) {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    return ComputedWatch<AggregateQuerySnapshot<T>>(
      this,
      entry.table,
      spec.scopePath,
      () => runAggregate(aggregate),
      (previous, next) => previous == next,
    ).stream;
  }

  /// The live stream behind [AggregateGroupQuery.watch].
  @internal
  Stream<List<AggregateGroup<T>>> watchGroupAggregate<T extends Object>(
    AggregateGroupQuery<T> aggregate,
  ) {
    final spec = aggregate.query.spec;
    final entry = _registry.entryFor(spec.adapter);
    return ComputedWatch<List<AggregateGroup<T>>>(
      this,
      entry.table,
      spec.scopePath,
      () => runGroupAggregate(aggregate),
      (previous, next) => _sameGroups(previous, next),
    ).stream;
  }

  static bool _sameGroups<T extends Object>(
    List<AggregateGroup<T>> previous,
    List<AggregateGroup<T>> next,
  ) {
    if (previous.length != next.length) {
      return false;
    }
    for (var i = 0; i < previous.length; i++) {
      if (previous[i] != next[i]) {
        return false;
      }
    }
    return true;
  }

  // -- Bulk-writer deferred indexes ----------------------------------------

  /// Registers a live bulk writer (for the deferred-index accounting).
  @internal
  void noteBulkWriterActive() => _bulkWriters++;

  /// Unregisters a finished bulk writer.
  @internal
  void noteBulkWriterClosed() => _bulkWriters--;

  /// Marks [indexNames] as dropped by a bulk writer: queries whose plan
  /// needs one of them wait until they are rebuilt.
  @internal
  void noteIndexesDeferred(Iterable<String> indexNames) {
    for (final name in indexNames) {
      _deferredIndexCounts[name] = (_deferredIndexCounts[name] ?? 0) + 1;
    }
  }

  /// Marks [indexNames] as rebuilt by a bulk writer's close, releasing the
  /// queries that waited for them.
  @internal
  void noteIndexesRestored(Iterable<String> indexNames) {
    for (final name in indexNames) {
      final count = _deferredIndexCounts[name];
      if (count == null) {
        continue;
      }
      if (count <= 1) {
        _deferredIndexCounts.remove(name);
      } else {
        _deferredIndexCounts[name] = count - 1;
      }
    }
    _serveBulkWaiters();
  }

  /// Resolves when [servingIndex] is no longer deferred by a bulk writer
  /// (immediately when it never was). Queries call this between planning
  /// and execution.
  @internal
  Future<void> waitForBulkIndexes(String? servingIndex) {
    if (servingIndex == null ||
        !_deferredIndexCounts.containsKey(servingIndex)) {
      return Future.value();
    }
    final needed = {servingIndex};
    final completer = Completer<void>();
    _bulkWaiters.add((needed: needed, completer: completer));
    // The last writer may have restored between the check and the add.
    if (!_deferredIndexCounts.containsKey(servingIndex)) {
      _serveBulkWaiters();
    }
    return completer.future;
  }

  void _serveBulkWaiters() {
    if (_bulkWaiters.isEmpty) {
      return;
    }
    for (final waiter in List.of(_bulkWaiters)) {
      if (!waiter.needed.any(_deferredIndexCounts.containsKey)) {
        _bulkWaiters.remove(waiter);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete();
        }
      }
    }
  }

  // -- Change log -----------------------------------------------------------

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
  Future<List<Change>> changesSince(int seq, {int limit = 1000}) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be at least 1');
    }
    final earliest = await earliestChangeSeq();
    if (seq + 1 < earliest) {
      throw ChangesPrunedException(requestedSeq: seq, earliestSeq: earliest);
    }
    final rows = await _executor.getAll(
      'SELECT seq, tbl, path, op, at FROM $changesTableName '
      'WHERE seq > ? ORDER BY seq LIMIT ?',
      [seq, limit],
    );
    return [for (final row in rows) _changeFromRow(row)];
  }

  /// The oldest change seq still readable from the log: the lowest [seq]
  /// present, or `lastChangeSeq() + 1` when the log is empty (nothing was
  /// ever logged, or everything logged was pruned).
  Future<int> earliestChangeSeq() async {
    final row = await _executor.getOptional(
      'SELECT MIN(seq) AS seq FROM $changesTableName',
    );
    final min = row?['seq'] as int?;
    if (min != null) {
      return min;
    }
    return (await lastChangeSeq()) + 1;
  }

  /// The highest seq ever assigned to a change, or `0` when nothing was
  /// logged yet.
  ///
  /// It never goes backwards: pruning and retention remove rows but the
  /// AUTOINCREMENT head in `sqlite_sequence` (where this value lives, not
  /// in `MAX(seq)`) is never rewound, so a sync outbox can compare its own
  /// watermark against it at any time.
  Future<int> lastChangeSeq() async {
    final row = await _executor.getOptional(
      'SELECT seq FROM sqlite_sequence WHERE name = ?',
      [changesTableName],
    );
    return (row?['seq'] as int?) ?? 0;
  }

  /// Deletes every change row with `seq <= upToSeq`, returning how many
  /// rows were removed.
  ///
  /// Call it once changes are durably processed elsewhere (synced, audited);
  /// the log would otherwise grow forever. `lastChangeSeq()` does not move
  /// — a consumer that reads from a seq below the new floor
  /// ([earliestChangeSeq]) gets a [ChangesPrunedException] and knows to
  /// resync, never a silent gap.
  Future<int> pruneChanges({required int upToSeq}) async {
    if (upToSeq < 0) {
      throw ArgumentError.value(upToSeq, 'upToSeq', 'Must not be negative');
    }
    return _executor.writeTransaction((tx) async {
      await tx.execute('DELETE FROM $changesTableName WHERE seq <= ?', [
        upToSeq,
      ]);
      final row = await tx.getOptional('SELECT changes() AS c');
      return row!['c']! as int;
    });
  }

  /// Applies [CocoonOptions.changeRetention] after a commit: computes the
  /// seq floor the count and age bounds imply and deletes the log's old
  /// prefix in small batches, in its own write transaction — never inside a
  /// user transaction. One call deletes at most
  /// [CocoonOptions.defaultRetentionBatchStatements] batches
  /// ([CocoonOptions.defaultRetentionBatchRows] rows each) and walks at
  /// most that many batches to find the age floor, so a large backlog
  /// shrinks over the commits that follow instead of stalling one write.
  Future<void> _enforceChangeRetention() async {
    final retention = _changeRetention!;
    final last = await lastChangeSeq();
    if (last == 0) {
      return;
    }
    var floor = 0;
    if (retention.maxChanges != null) {
      // Keep at most the newest N rows: everything at or below
      // `last - N` goes (the AUTOINCREMENT seqs of committed rows are
      // contiguous, so this is exact).
      final countFloor = last - retention.maxChanges!;
      if (countFloor > floor) {
        floor = countFloor;
      }
    }
    if (retention.maxAge != null) {
      final cutoff =
          DateTime.now().toUtc().microsecondsSinceEpoch -
          retention.maxAge!.inMicroseconds;
      // The log is append-ordered, so rows older than the cutoff are (up
      // to clock skew) a prefix; walk it in small batches and keep only
      // the verified-older part.
      final batch = CocoonOptions.defaultRetentionBatchRows;
      var low = 0;
      for (
        var walked = 0;
        walked < CocoonOptions.defaultRetentionBatchStatements;
        walked++
      ) {
        final rows = await _executor.getAll(
          'SELECT seq, at FROM $changesTableName WHERE seq > ? '
          'ORDER BY seq LIMIT ?',
          [low, batch],
        );
        if (rows.isEmpty) {
          break;
        }
        var oldest = 0;
        for (final row in rows) {
          if ((row['at']! as int) >= cutoff) {
            break;
          }
          oldest = row['seq']! as int;
        }
        if (oldest > floor) {
          floor = oldest;
        }
        // `oldest == 0`: this batch already holds a row newer than the
        // cutoff. A short batch is the log's end. Either way the old
        // prefix is behind us; otherwise keep walking.
        if (oldest == 0 ||
            oldest != (rows.last['seq']! as int) ||
            rows.length < batch) {
          break;
        }
        low = oldest;
      }
    }
    if (floor <= 0) {
      return;
    }
    await _executor.writeTransaction((tx) async {
      var statements = 0;
      while (statements < CocoonOptions.defaultRetentionBatchStatements) {
        final result = await tx.getAll(
          'DELETE FROM $changesTableName WHERE seq IN '
          '(SELECT seq FROM $changesTableName WHERE seq <= ? LIMIT ?) '
          'RETURNING seq',
          [floor, CocoonOptions.defaultRetentionBatchRows],
        );
        statements++;
        if (result.length < CocoonOptions.defaultRetentionBatchRows) {
          break;
        }
      }
    });
  }

  Change _changeFromRow(Map<String, Object?> row) {
    final table = row['tbl']! as String;
    final op = row['op']! as String;
    return Change(
      seq: row['seq']! as int,
      collection: _modelOfTable(table),
      path: row['path']! as String,
      op: switch (op) {
        'set' => ChangeOp.set,
        'delete' => ChangeOp.delete,
        _ => throw StateError('Unknown change op "$op" in the change log'),
      },
      at: DateTime.fromMicrosecondsSinceEpoch(row['at']! as int, isUtc: true),
    );
  }

  /// The model name of a registered SQL [table], or the table name itself
  /// for a table without a registered adapter (defensive; the log only ever
  /// holds rows for registered collections).
  String _modelOfTable(String table) {
    for (final entry in _registry.entries) {
      if (entry.table == table) {
        return entry.adapter.model;
      }
    }
    return table;
  }

  DocSnapshot<T> _snapshotFromRow<T extends Object>(
    RegistryEntry entry,
    Map<String, Object?> row,
  ) {
    final params = <String, String>{
      for (var i = 0; i < entry.paramNames.length; i++)
        entry.paramNames[i]: row[entry.paramSqlNames[i]]! as String,
    };
    final collectionPath = entry.adapter.pattern.resolve(params);
    final docPath = collectionPath.doc(row['id']! as String);
    final value = entry.adapter.decode(row['data'] as Uint8List) as T;
    return DocSnapshot<T>(
      DocRef<T>(this, entry.adapter as CollectionAdapter<T>, docPath),
      value,
    );
  }

  Future<DocSnapshot<T>?> _readDoc<T extends Object>(
    CocoonRead reader,
    DocRef<T> ref, {
    required bool cachePut,
  }) async {
    final entry = _registry.entryFor(ref.adapter);
    final key = entry.scopeKeyOf(ref.path.path);
    if (key == null) {
      throw ArgumentError.value(
        ref.path.path,
        'ref',
        'Not a document path of collection ${entry.adapter.pattern}',
      );
    }
    final where = [
      for (var i = 0; i < entry.paramSqlNames.length; i++)
        '${entry.paramSqlNames[i]} = ?',
      'id = ?',
    ].join(' AND ');
    final row = await reader.getOptional(
      'SELECT data FROM ${entry.table} WHERE $where',
      [...key.paramValues, key.id],
    );
    if (row == null) {
      return null;
    }
    final value = entry.adapter.decode(row['data'] as Uint8List) as T;
    if (cachePut) {
      _cache.put(ref.path.path, value);
    }
    return DocSnapshot<T>(ref, value);
  }

  /// Records [path] (with result position [position]) as a document `getAll`
  /// still needs from SQLite: validates the path against [entry]'s pattern
  /// exactly like [_readDoc] does, and collapses duplicate references onto
  /// one fetch whose snapshot every position shares.
  void _addPendingDoc(
    Map<String, _PendingDoc> pending,
    RegistryEntry entry,
    String path,
    int position,
  ) {
    final existing = pending[path];
    if (existing != null) {
      existing.positions.add(position);
      return;
    }
    final key = entry.scopeKeyOf(path);
    if (key == null) {
      throw ArgumentError.value(
        path,
        'ref',
        'Not a document path of collection ${entry.adapter.pattern}',
      );
    }
    pending[path] = _PendingDoc(entry, path, key)..positions.add(position);
  }

  /// Fetches every [pending] document from [reader] and fills [snapshots]:
  /// documents grouped per table, one statement per chunk of
  /// [getAllChunkKeys] scope keys — a 1,000-id call costs one round trip per
  /// table per chunk instead of one per document. The caller runs all of a
  /// call's statements inside one read transaction, so the chunks answer
  /// from one snapshot. Rows decode per document and, with [cachePut],
  /// populate the hot-document cache exactly like [_readDoc].
  Future<void> _fillFromTables<T extends Object>(
    CocoonRead reader,
    Map<String, _PendingDoc> pending,
    List<DocRef<T>> refs,
    List<DocSnapshot<T>?> snapshots, {
    required bool cachePut,
  }) async {
    final byTable = <RegistryEntry, List<_PendingDoc>>{};
    for (final doc in pending.values) {
      (byTable[doc.entry] ??= []).add(doc);
    }
    for (final entry in byTable.keys) {
      final docs = byTable[entry]!;
      final keyColumns = entry.keyColumns;
      final keyCount = keyColumns.length;
      for (var start = 0; start < docs.length; start += getAllChunkKeys) {
        final chunk = docs.sublist(
          start,
          start + getAllChunkKeys > docs.length
              ? docs.length
              : start + getAllChunkKeys,
        );
        final args = <Object?>[];
        for (final doc in chunk) {
          args.addAll(doc.key.paramValues);
          args.add(doc.key.id);
        }
        // A root collection keys by id alone (`id IN (...)`); a
        // subcollection keys by the full scope key with row values — the
        // statement shape the batch update's existence check uses.
        final String sql;
        if (keyCount == 1) {
          sql =
              'SELECT id, data FROM ${entry.table} '
              'WHERE id IN (${List.filled(chunk.length, '?').join(', ')})';
        } else {
          final tuple = '(${List.filled(keyCount, '?').join(', ')})';
          sql =
              'SELECT ${keyColumns.join(', ')}, data FROM ${entry.table} '
              'WHERE (${keyColumns.join(', ')}) IN (VALUES '
              '${List.filled(chunk.length, tuple).join(', ')})';
        }
        final rows = await reader.getAll(sql, args);
        final rowOfPath = {
          for (final row in rows) entry.pathOfKeyRow(row): row,
        };
        for (final doc in chunk) {
          final row = rowOfPath[doc.path];
          if (row == null) {
            continue; // a missing document answers null at its position
          }
          final value = entry.adapter.decode(row['data']! as Uint8List) as T;
          if (cachePut) {
            _cache.put(doc.path, value);
          }
          // Duplicate references share one snapshot: their refs are equal
          // (a DocRef compares by path) and DocSnapshot is immutable.
          final snapshot = DocSnapshot<T>(refs[doc.positions.first], value);
          for (final position in doc.positions) {
            snapshots[position] = snapshot;
          }
        }
      }
    }
  }

  @internal
  List<String> paramValuesInOrder(RegistryEntry entry, CollectionPath path) {
    final values = entry.adapter.pattern.match(path.path);
    if (values == null) {
      throw ArgumentError.value(
        path.path,
        'path',
        'Not a collection path of ${entry.adapter.pattern}',
      );
    }
    return [for (final name in entry.paramNames) values[name]!];
  }

  // -- Schema reconciliation ----------------------------------------------

  /// Compares the file's storage format version with [storageFormatVersion]
  /// and rebuilds an older file table by table (see [FormatMigrator]).
  ///
  /// A file written by a NEWER storage format refuses to open with a
  /// [StorageFormatTooNewException]. A fresh database has no format row
  /// yet; the rebuild finds no tables carrying the old layout and just
  /// stamps the current version.
  ///
  /// Returns whether this open actually converted an older layout (as
  /// opposed to a fresh create or an already-current file): only that open
  /// considers the post-upgrade compaction.
  static Future<bool> _applyStorageFormat(
    CocoonTx tx, {
    required void Function(int done, int total)? onMigrationProgress,
    required String databasePath,
  }) async {
    final row = await tx.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      [formatVersionMetaKey],
    );
    final stored = row == null
        ? 0
        : switch (int.tryParse(row['value']! as String)) {
            final int version? => version,
            null => throw StateError(
              'The database\'s $metaTableName row '
              '"$formatVersionMetaKey" does not parse as an integer: '
              '${row['value']}',
            ),
          };
    if (stored > storageFormatVersion) {
      throw StorageFormatTooNewException(
        path: databasePath,
        formatVersion: stored,
        maxSupported: storageFormatVersion,
      );
    }
    if (stored == storageFormatVersion) {
      return false;
    }
    final rebuilt = await FormatMigrator.migrateInTx(
      tx,
      onProgress: onMigrationProgress,
    );
    // An older format row means a real upgrade; rebuilt tables also cover
    // files that predate the format row itself.
    return rebuilt > 0 || stored > 0;
  }

  /// The freelist share above which the post-upgrade compaction runs: the
  /// check is `freelist * compactFreelistDenominator > pages`, so the
  /// default (5) compacts when MORE than a fifth of the file is reclaimable.
  ///
  /// Below that the one-time `VACUUM` rewrite of the whole file is not worth
  /// the reclaimed bytes; the next `backupTo` compacts anyway.
  @visibleForTesting
  static const int compactFreelistDenominator = 5;

  /// Reclaims the freelist pages a storage-format upgrade left behind, once,
  /// after the open transaction committed.
  ///
  /// Runs `VACUUM` only when more than a fifth of the file sits on the
  /// freelist. Every failure is caught and reported through
  /// [onCompactionFailed] — a full disk (VACUUM needs about the file size in
  /// free space) must not fail the open; the file stays as the upgrade made
  /// it and the next `backupTo` compacts instead.
  static Future<void> _compactAfterFormatUpgrade(
    CocoonExecutor executor,
    void Function(Object error)? onCompactionFailed,
  ) async {
    try {
      final freeRow = await executor.getOptional('PRAGMA freelist_count');
      final pagesRow = await executor.getOptional('PRAGMA page_count');
      final free = freeRow?['freelist_count'] as int? ?? 0;
      final pages = pagesRow?['page_count'] as int? ?? 0;
      if (pages <= 0 || free * compactFreelistDenominator <= pages) {
        return;
      }
      await executor.execute('VACUUM');
    } on Object catch (error) {
      onCompactionFailed?.call(error);
    }
  }

  /// Compares the stored schema version with [schemaVersion] and applies
  /// every pending [CocoonMigration] (see [runSchemaMigrationsInTx]); then
  /// stores the current version. Returns the migrated tables, which the
  /// reconciler must rebuild even when their shape hash matches.
  ///
  /// A `null` [schemaVersion] (databases opened without version tracking)
  /// does nothing.
  static Future<Set<String>> _applySchemaVersion(
    CocoonTx tx,
    SchemaRegistry registry, {
    required int? schemaVersion,
    required List<CocoonMigration> migrations,
    required bool keepChanges,
    void Function(int done, int total)? onMigrationProgress,
  }) async {
    if (schemaVersion == null) {
      return const {};
    }
    final row = await tx.getOptional(
      'SELECT value FROM $metaTableName WHERE key = ?',
      [schemaVersionMetaKey],
    );
    final stored = row == null ? 0 : int.parse(row['value']! as String);
    if (stored > schemaVersion) {
      throw SchemaTooNewException(stored, schemaVersion);
    }
    if (stored == schemaVersion) {
      return const {};
    }
    final pending = [
      for (final migration in migrations)
        if (migration.version > stored) migration,
    ]..sort((a, b) => a.version.compareTo(b.version));
    final migratedTables = pending.isEmpty
        ? const <String>{}
        : await runSchemaMigrationsInTx(
            tx: tx,
            registry: registry,
            pending: pending,
            keepChanges: keepChanges,
            onProgress: onMigrationProgress,
          );
    await tx.execute(
      'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
      [schemaVersionMetaKey, '$schemaVersion'],
    );
    return migratedTables;
  }

  static Future<void> _reconcile(
    CocoonTx tx,
    SchemaRegistry registry, {
    Set<String> forceTables = const {},
  }) async {
    for (final entry in registry.entries) {
      final stored = await tx.getOptional(
        'SELECT value FROM $metaTableName WHERE key = ?',
        ['shape:${entry.table}'],
      );
      final tableExists =
          await tx.getOptional(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            'AND name = ?',
            [entry.table],
          ) !=
          null;
      if (!forceTables.contains(entry.table) &&
          tableExists &&
          stored != null &&
          stored['value'] == entry.shapeHash) {
        // Shape unchanged: no DDL beyond the two reads above.
        continue;
      }
      if (!tableExists) {
        await tx.execute(
          createTableSql(entry.table, entry.paramSqlNames, entry.columnDdls),
        );
        await tx.execute(createScopeIndexSql(entry.table, entry.paramSqlNames));
        for (final index in entry.indexes) {
          await tx.execute(createIndexSql(entry.table, index));
        }
      } else {
        await _reconcileTable(tx, entry);
      }
      await tx.execute(
        'INSERT OR REPLACE INTO $metaTableName (key, value) VALUES (?, ?)',
        ['shape:${entry.table}', entry.shapeHash],
      );
    }
  }

  static Future<void> _createMetaTableIfMissing(CocoonTx tx) async {
    final exists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [metaTableName],
    );
    if (exists == null) {
      await tx.execute(createMetaTableSql());
    }
  }

  static Future<void> _createChangesTableIfMissing(CocoonTx tx) async {
    final exists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [changesTableName],
    );
    if (exists == null) {
      await tx.execute(createChangesTableSql());
    }
  }

  /// Rebuilds the secondary indexes a crashed [BulkWriter] left deferred and
  /// clears the meta rows, in the open transaction.
  ///
  /// The writer records every dropped index in `_cocoon_bulk` (with the DDL
  /// that recreates it) in the same transaction that drops it, so rows left
  /// behind mean the load never finished: without this step the database
  /// would open with missing indexes — and, the shape hash being unchanged,
  /// the reconciler would not recreate them. A recorded index is only
  /// rebuilt when the current schema still declares it and its table still
  /// exists, so a schema change between the crash and the reopen is
  /// respected. Replay is idempotent (`CREATE ... IF NOT EXISTS`): when the
  /// reconciler already recreated the index, the replay is a no-op.
  static Future<void> _recoverBulkIndexes(
    CocoonTx tx,
    SchemaRegistry registry,
  ) async {
    final bulkTableExists = await tx.getOptional(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [bulkTableName],
    );
    if (bulkTableExists == null) {
      return;
    }
    final rows = await tx.getAll(
      'SELECT tbl, index_name, sql FROM $bulkTableName',
    );
    if (rows.isEmpty) {
      return;
    }
    final byTable = {for (final entry in registry.entries) entry.table: entry};
    for (final row in rows) {
      final table = row['tbl']! as String;
      final name = row['index_name']! as String;
      final entry = byTable[table];
      if (entry == null) {
        continue;
      }
      if (!entry.indexes.any((index) => index.name == name)) {
        continue;
      }
      final tableExists =
          await tx.getOptional(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            'AND name = ?',
            [table],
          ) !=
          null;
      if (!tableExists) {
        continue;
      }
      await tx.execute(row['sql']! as String);
    }
    await tx.execute('DELETE FROM $bulkTableName');
  }

  static Future<void> _reconcileTable(CocoonTx tx, RegistryEntry entry) async {
    final existingColumns = await _columnNames(tx, entry.table);
    final declaredColumns = {
      for (final column in entry.columnDdls) column.name,
    };
    final columnsToAdd = [
      for (final column in entry.columnDdls)
        if (!existingColumns.contains(column.name)) column,
    ];
    final columnsToDrop = [
      for (final name in existingColumns)
        if (name.startsWith('f_') && !declaredColumns.contains(name)) name,
    ];
    final existingIndexes = await _cocoonIndexNames(tx, entry.table);
    final expectedIndexNames = {
      entry.scopeIndex.name,
      for (final index in entry.indexes) index.name,
    };

    // Dropped columns must lose their indexes first, and any index that is
    // no longer declared goes away with the shape change.
    if (columnsToDrop.isNotEmpty) {
      for (final name in existingIndexes) {
        await tx.execute('DROP INDEX IF EXISTS "$name"');
      }
    } else {
      for (final name in existingIndexes) {
        if (!expectedIndexNames.contains(name)) {
          await tx.execute('DROP INDEX IF EXISTS "$name"');
        }
      }
    }

    // New field columns are added, then backfilled from the stored
    // documents, in batches, before the indexes that use them are created.
    for (final column in columnsToAdd) {
      await tx.execute(alterAddColumnSql(entry.table, column));
    }
    if (columnsToAdd.isNotEmpty) {
      await _backfillColumns(tx, entry, columnsToAdd);
    }

    for (final name in columnsToDrop) {
      await tx.execute('ALTER TABLE ${entry.table} DROP COLUMN "$name"');
    }

    await tx.execute(createScopeIndexSql(entry.table, entry.paramSqlNames));
    for (final index in entry.indexes) {
      await tx.execute(createIndexSql(entry.table, index));
    }
  }

  static Future<void> _backfillColumns(
    CocoonTx tx,
    RegistryEntry entry,
    List<ColumnDdl> columns,
  ) async {
    final addedFields = <FieldColumn<Object?, Object?>>[
      for (final column in columns)
        entry.fieldColumns[entry.columnDdls.indexOf(column)],
    ];
    final updateSql =
        'UPDATE ${entry.table} SET '
        '${addedFields.map((field) => '${fieldColumnName(field.name)} = ?').join(', ')} '
        'WHERE ${[...entry.paramSqlNames, 'id'].map((name) => '$name = ?').join(' AND ')}';
    var lastRowId = 0;
    while (true) {
      final rows = await tx.getAll(
        'SELECT rowid, ${[...entry.paramSqlNames, 'id', 'data'].join(', ')} '
        'FROM ${entry.table} WHERE rowid > ? ORDER BY rowid '
        'LIMIT $backfillBatchSize',
        [lastRowId],
      );
      if (rows.isEmpty) {
        break;
      }
      final updates = <List<Object?>>[];
      for (final row in rows) {
        final value = entry.adapter.decode(row['data'] as Uint8List);
        updates.add([
          for (final field in addedFields) field.sqlOf(value),
          for (final name in entry.paramSqlNames) row[name]! as String,
          row['id']! as String,
        ]);
        lastRowId = row['rowid']! as int;
      }
      await tx.executeBatch(updateSql, updates);
      if (rows.length < backfillBatchSize) {
        break;
      }
    }
  }

  /// Rows decoded per backfill batch.
  static const int backfillBatchSize = 500;

  static Future<Set<String>> _columnNames(CocoonTx tx, String table) async {
    final rows = await tx.getAll('PRAGMA table_info($table)');
    return {for (final row in rows) row['name']! as String};
  }

  static Future<List<String>> _cocoonIndexNames(
    CocoonTx tx,
    String table,
  ) async {
    final rows = await tx.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
      [table],
    );
    final prefix = 'cx_${table}_';
    return [
      for (final row in rows)
        if ((row['name']! as String).startsWith(prefix)) row['name']! as String,
    ];
  }

  static SqliteSynchronous _synchronousOf(Durability durability) =>
      switch (durability) {
        Durability.full => SqliteSynchronous.full,
        Durability.normal => SqliteSynchronous.normal,
      };
}

/// One distinct document path a `getAll` call still needs from SQLite: its
/// registry entry, its scope key, and every result position waiting for it.
final class _PendingDoc {
  _PendingDoc(this.entry, this.path, this.key);

  final RegistryEntry entry;
  final String path;
  final ({List<String> paramValues, String id}) key;

  /// Every [getAll] result position this path answers, duplicates included.
  final List<int> positions = [];
}
