import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sqlite_async/sqlite_async.dart'
    show SqliteDatabase, SqliteOptions, SqliteSynchronous;

import '../cursor.dart';
import '../id.dart';
import '../path.dart';
import 'adapter.dart';
import 'cache.dart';
import 'changes.dart';
import 'executor.dart';
import 'naming.dart';
import 'query.dart';
import 'refs.dart';
import 'schema_sql.dart';
import 'sqlite_executor.dart';
import 'watch.dart';

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

/// Options for opening a [Cocoon] database.
final class CocoonOptions {
  /// Builds options; the defaults are safe for money-style data.
  const CocoonOptions({
    this.durability = Durability.full,
    this.cacheSize = defaultCacheSize,
    this.keepChanges = true,
  });

  /// The default hot-document cache size.
  static const int defaultCacheSize = 2000;

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
  Cocoon._(this._executor, this._registry, this._cache, this._keepChanges);

  final CocoonExecutor _executor;
  final SchemaRegistry _registry;
  final DocumentCache _cache;
  final bool _keepChanges;
  final WatchHub _watchHub = WatchHub();

  /// Opens (or creates) the database at [path] and reconciles the schema
  /// with [collections] inside one write transaction.
  ///
  /// The parent directory of [path] must exist. Throws an [ArgumentError]
  /// when the adapters are invalid (duplicate models, unknown index fields,
  /// a subcollection whose parent collection has no adapter, ...).
  static Future<Cocoon> open(
    String path, {
    required List<CollectionAdapter<Object?>> collections,
    CocoonOptions options = const CocoonOptions(),
  }) async {
    final executor = SqliteExecutor(
      SqliteDatabase(
        path: path,
        options: SqliteOptions(synchronous: _synchronousOf(options.durability)),
      ),
    );
    try {
      return await openWith(
        executor,
        collections: collections,
        options: options,
      );
    } on Object {
      await executor.close();
      rethrow;
    }
  }

  /// Opens over an existing [executor]; used by tests to spy on statements.
  @visibleForTesting
  static Future<Cocoon> openWith(
    CocoonExecutor executor, {
    required List<CollectionAdapter<Object?>> collections,
    CocoonOptions options = const CocoonOptions(),
  }) async {
    final registry = SchemaRegistry.build(collections);
    await _reconcile(executor, registry);
    return Cocoon._(
      executor,
      registry,
      DocumentCache(options.cacheSize),
      options.keepChanges,
    );
  }

  /// Closes the database. Every watch stream this instance created
  /// completes; using references of a closed database throws.
  Future<void> close() {
    _watchHub.close();
    return _executor.close();
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
  Future<R> runTransaction<R>(Future<R> Function(CocoonTransaction tx) body) =>
      writeTx<R>((tx, stage) => body(CocoonTransaction(this, tx, stage)));

  /// How many documents the hot-document cache currently holds.
  @visibleForTesting
  int get debugCacheLength => _cache.length;

  /// How many watch streams are currently registered (listening).
  @visibleForTesting
  int get debugWatcherCount => _watchHub.length;

  /// The hub every live watch registers with.
  @internal
  WatchHub get watchHub => _watchHub;

  // -- Engine internals ----------------------------------------------------

  /// Runs [body] in one write transaction, applying its staged cache updates
  /// only after the commit succeeds, then delivers one commit event with the
  /// touched paths to the watch hub. Rolled-back transactions report nothing.
  @internal
  Future<R> writeTx<R>(
    Future<R> Function(CocoonTx tx, CacheStage stage) body,
  ) async {
    final stage = CacheStage();
    final result = await _executor.writeTransaction((tx) => body(tx, stage));
    stage.applyTo(_cache);
    final touched = stage.takeTouched();
    if (touched.isNotEmpty) {
      _watchHub.emit(CommitEvent(touched));
    }
    return result;
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
    final cached = _cache.get(ref.path.path);
    if (cached != null) {
      return DocSnapshot<T>(ref, cached as T);
    }
    return _readDoc<T>(_executor, ref, cachePut: true);
  }

  @internal
  Future<DocSnapshot<T>?> readDocInTx<T extends Object>(
    CocoonTx tx,
    DocRef<T> ref,
  ) => _readDoc<T>(tx, ref, cachePut: false);

  @internal
  Future<void> putDoc<T extends Object>(DocRef<T> ref, T value) =>
      writeTx<void>((tx, stage) => putDocInTx(tx, stage, ref, value));

  @internal
  Future<void> putDocInTx<T extends Object>(
    CocoonTx tx,
    CacheStage stage,
    DocRef<T> ref,
    T value,
  ) async {
    final entry = _registry.entryFor(ref.adapter);
    final bytes = entry.adapter.encode(value);
    // Normalize through the wire codec so the cached value is exactly what a
    // later read decodes (for example, DateTime fields come back in UTC).
    final stored = entry.adapter.decode(bytes) as T;
    final paramValues = _paramValuesInOrder(entry, ref.path.collection);
    final columnNames = [for (final column in entry.columnDdls) column.name];
    final columnValues = [
      for (final column in entry.fieldColumns) column.sqlOf(value),
    ];
    final columns = [
      'path',
      'id',
      ...entry.paramSqlNames,
      'data',
      ...columnNames,
    ];
    final placeholders = List.filled(columns.length, '?').join(', ');
    final updates = [
      'id',
      ...entry.paramSqlNames,
      'data',
      ...columnNames,
    ].map((name) => '$name = excluded.$name').join(', ');
    await tx.execute(
      'INSERT INTO ${entry.table} (${columns.join(', ')}) '
      'VALUES ($placeholders) '
      'ON CONFLICT(path) DO UPDATE SET $updates',
      [ref.path.path, ref.path.id, ...paramValues, bytes, ...columnValues],
    );
    await _recordChanges(tx, stage, [
      (entry.table, ref.path.path, ChangeOp.set),
    ]);
    stage.put(ref.path.path, stored);
  }

  @internal
  Future<DocRef<T>> addDoc<T extends Object>(CollectionRef<T> ref, T value) =>
      writeTx<DocRef<T>>((tx, stage) => addDocInTx(tx, stage, ref, value));

  @internal
  Future<DocRef<T>> addDocInTx<T extends Object>(
    CocoonTx tx,
    CacheStage stage,
    CollectionRef<T> ref,
    T value,
  ) async {
    final docRef = ref.doc(newDocId());
    await putDocInTx(tx, stage, docRef, value);
    return docRef;
  }

  @internal
  Future<void> deleteDoc(DocRef<Object> ref) =>
      writeTx<void>((tx, stage) => deleteDocInTx(tx, stage, ref));

  @internal
  Future<void> deleteDocInTx(
    CocoonTx tx,
    CacheStage stage,
    DocRef<Object> ref,
  ) async {
    final entry = _registry.entryFor(ref.adapter);
    // One change row per deleted document, including every cascaded one:
    // DELETE ... RETURNING keeps reading the paths and deleting atomic.
    final deleted = <(String table, String path)>[
      ...await _deleteReturning(tx, entry.table, ref.path.path),
    ];
    final (:from, :to) = ref.path.descendants;
    for (final candidate in _registry.entries) {
      if (SchemaRegistry.descendsFrom(
        candidate.adapter.pattern,
        ref.adapter.pattern,
      )) {
        deleted.addAll(await _deleteSubtree(tx, candidate.table, from, to));
      }
    }
    await _recordChanges(tx, stage, [
      for (final (table, path) in deleted) (table, path, ChangeOp.delete),
    ]);
    stage.evictSubtree(ref.path.path);
  }

  /// Deletes the document at [path] from [table], returning its `(table,
  /// path)` pair only when a row was actually removed.
  Future<List<(String, String)>> _deleteReturning(
    CocoonTx tx,
    String table,
    String path,
  ) async {
    final rows = await tx.getAll(
      'DELETE FROM $table WHERE path = ? RETURNING path',
      [path],
    );
    return [for (final row in rows) (table, row['path']! as String)];
  }

  /// Deletes the half-open subtree range from [table], returning one
  /// `(table, path)` pair per removed document.
  Future<List<(String, String)>> _deleteSubtree(
    CocoonTx tx,
    String table,
    String from,
    String to,
  ) async {
    final rows = await tx.getAll(
      'DELETE FROM $table WHERE path >= ? AND path < ? RETURNING path',
      [from, to],
    );
    return [for (final row in rows) (table, row['path']! as String)];
  }

  /// Appends one change-log row per touched document (when the log is on)
  /// and records the touched set for the post-commit notification.
  Future<void> _recordChanges(
    CocoonTx tx,
    CacheStage stage,
    List<(String table, String path, ChangeOp op)> changes,
  ) async {
    if (changes.isEmpty) {
      return;
    }
    for (final (table, path, op) in changes) {
      stage.touched(table, path, op);
    }
    if (!_keepChanges) {
      return;
    }
    final at = DateTime.now().toUtc().microsecondsSinceEpoch;
    await tx.executeBatch(
      'INSERT INTO $changesTableName (tbl, path, op, at) VALUES (?, ?, ?, ?)',
      [
        for (final (table, path, op) in changes) [table, path, op.name, at],
      ],
    );
  }

  @internal
  Future<QueryPage<T>> runQuery<T extends Object>(CocoonQuery<T> query) async =>
      (await runQueryWithBytes<T>(query)).$1;

  /// Runs [query], also returning each document's stored wire bytes in page
  /// order — the signature query watches deduplicate pages by.
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
    );
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
    final spec = query.spec;
    final entry = _registry.entryFor(spec.adapter);
    final plan = planQuery(
      entry: entry,
      scopePath: spec.scopePath,
      filters: spec.filters,
      orders: spec.orders,
      limit: null,
      cursor: null,
      fullScan: spec.fullScan,
    );
    final rows = await _executor.getAll(plan.countSql, plan.countArgs);
    return rows.first['c']! as int;
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
  Future<List<Change>> changesSince(int seq, {int limit = 1000}) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be at least 1');
    }
    final rows = await _executor.getAll(
      'SELECT seq, tbl, path, op, at FROM $changesTableName '
      'WHERE seq > ? ORDER BY seq LIMIT ?',
      [seq, limit],
    );
    return [for (final row in rows) _changeFromRow(row)];
  }

  /// The highest seq ever assigned to a change, or `0` when nothing was
  /// logged yet.
  ///
  /// It never goes backwards: pruning removes rows but keeps the head, so a
  /// sync outbox can compare its own watermark against it at any time.
  Future<int> lastChangeSeq() async {
    final row = await _executor.getOptional(
      'SELECT seq FROM sqlite_sequence WHERE name = ?',
      [changesTableName],
    );
    return (row?['seq'] as int?) ?? 0;
  }

  /// Deletes every change row with `seq <= upToSeq`.
  ///
  /// Call it once changes are durably processed elsewhere (synced, audited);
  /// the log would otherwise grow forever.
  Future<void> pruneChanges({required int upToSeq}) {
    return _executor.writeTransaction((tx) async {
      await tx.execute('DELETE FROM $changesTableName WHERE seq <= ?', [
        upToSeq,
      ]);
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
    final row = await reader.getOptional(
      'SELECT data FROM ${entry.table} WHERE path = ?',
      [ref.path.path],
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

  List<String> _paramValuesInOrder(RegistryEntry entry, CollectionPath path) {
    final patternSegments = entry.adapter.pattern.pattern.split('/');
    final pathSegments = path.path.split('/');
    return [
      for (var i = 1; i < patternSegments.length; i += 2) pathSegments[i],
    ];
  }

  // -- Schema reconciliation ----------------------------------------------

  static Future<void> _reconcile(
    CocoonExecutor executor,
    SchemaRegistry registry,
  ) {
    return executor.writeTransaction((tx) async {
      await _createMetaTableIfMissing(tx);
      await _createChangesTableIfMissing(tx);
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
        if (tableExists &&
            stored != null &&
            stored['value'] == entry.shapeHash) {
          // Shape unchanged: no DDL beyond the two reads above.
          continue;
        }
        if (!tableExists) {
          await tx.execute(
            createTableSql(entry.table, entry.paramSqlNames, entry.columnDdls),
          );
          await tx.execute(
            createScopeIndexSql(entry.table, entry.paramSqlNames),
          );
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
    });
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
        'WHERE path = ?';
    var lastPath = '';
    while (true) {
      final rows = await tx.getAll(
        'SELECT path, data FROM ${entry.table} '
        'WHERE path > ? ORDER BY path LIMIT $backfillBatchSize',
        [lastPath],
      );
      if (rows.isEmpty) {
        break;
      }
      final updates = <List<Object?>>[];
      for (final row in rows) {
        final path = row['path']! as String;
        final value = entry.adapter.decode(row['data'] as Uint8List);
        updates.add([
          for (final field in addedFields) field.sqlOf(value),
          path,
        ]);
        lastPath = path;
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
