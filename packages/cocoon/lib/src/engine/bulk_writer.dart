import 'dart:async';

import 'package:meta/meta.dart';

import 'batch.dart' show BatchOpKind;
import 'cocoon.dart';
import 'naming.dart';
import 'refs.dart';
import 'schema_sql.dart';

/// Options for the bulk writer behind `db.bulkWriter()`.
///
/// The defaults are measured on the 1M-transaction import
/// (`benchmarks/cocoon_rivals/IMPORT.md`, the step-13 table): [chunkSize]
/// picks the point on the commit-size curve where bigger chunks stop paying,
/// and `deferIndexes: true` builds the secondary indexes after the load
/// instead of during every chunk commit.
final class BulkWriterOptions {
  /// Builds options; the defaults suit a bulk load into a fresh or small
  /// database.
  const BulkWriterOptions({
    this.chunkSize = defaultChunkSize,
    this.deferIndexes = true,
  });

  /// The default number of rows one chunk commits ([chunkSize]).
  static const int defaultChunkSize = 10000;

  /// How many rows one chunk commits. Every chunk is one write transaction:
  /// bigger chunks mean fewer commits (the per-commit cost is what dominates
  /// a bulk load), a longer write lock per commit, and a coarser crash
  /// boundary — a crash keeps the chunks committed so far, never a half
  /// chunk. The database's `Durability` applies to every chunk.
  final int chunkSize;

  /// Whether the writer drops each touched table's secondary indexes during
  /// the load and rebuilds them at [BulkWriter.close] (default).
  ///
  /// Deferral only happens when it pays: when the table is empty (a bulk
  /// load into a fresh database) or the writer has buffered more rows for
  /// the table than the table already holds (a load that at least doubles
  /// it). The scope index and the unique `path` constraint are never
  /// dropped. While the indexes are deferred, a query whose plan needs one
  /// of them waits until the writer closes; `get()` by id is unaffected.
  final bool deferIndexes;
}

/// One queued [BulkWriter] operation.
final class _QueuedOp {
  const _QueuedOp(this.kind, this.entry, this.ref, this.value);

  /// The kind of write.
  final BatchOpKind kind;

  /// The collection the document belongs to (its table and write SQL).
  final RegistryEntry entry;

  /// The document the operation targets.
  final DocRef<Object> ref;

  /// The value to store, for [BatchOpKind.set] and [BatchOpKind.update].
  final Object? value;
}

/// A secondary index this writer deferred: the SQL table, the physical index
/// name, and the `CREATE INDEX` statement that rebuilds it.
final class _DeferredIndex {
  const _DeferredIndex(this.table, this.name, this.sql);

  /// The SQL table the index belongs to.
  final String table;

  /// The physical index name (`cx_<table>_<hex>`).
  final String name;

  /// The exact `CREATE ... INDEX IF NOT EXISTS` statement to rebuild it.
  final String sql;
}

/// A Firestore-style BulkWriter: many writes, buffered in memory, committed
/// in chunks — not atomic as a whole, atomic per chunk.
///
/// This is the path for import-shaped work far larger than a `WriteBatch`:
/// restoring a backup, a first sync, loading a dataset. Queue `set`,
/// `update` and `delete` synchronously (nothing touches disk); the writer
/// commits every [BulkWriterOptions.chunkSize] queued rows as one write
/// transaction and keeps buffering while it runs:
///
/// ```dart
/// final bulk = db.bulkWriter();
/// for (final txn in txns) {
///   bulk.set(txnsOf(txn.accountId).doc(txn.id), txn);
/// }
/// await bulk.close(); // flushes, rebuilds the deferred indexes, resolves
///                     // when everything is durable
/// ```
///
/// Semantics:
///
/// - **Not atomic as a whole, atomic per chunk** (the same rule Firestore's
///   BulkWriter documents loudly): a crash leaves a prefix of committed
///   chunks, never a half chunk. Each chunk honours the database's
///   `Durability`. If a chunk fails (a failed `update`, a SQL error), that
///   chunk rolls back entirely, the buffered operations after it are
///   discarded, and the error surfaces from `flush()` and `close()`.
/// - Per-operation validation and semantics are the standalone ones, as for
///   `WriteBatch`: `set` upserts, `update` replaces an existing document and
///   fails its chunk when the document is missing (a `set` queued earlier —
///   in the same chunk or an earlier, committed one — satisfies it), and
///   `delete` removes the document and its whole subtree.
/// - Operations commit in call order; for the same document the last write
///   wins inside its chunk. (Inserting in path order was measured for the
///   1M import and kept out: it cost ~1 s and won nothing — see
///   `benchmarks/cocoon_rivals/IMPORT.md`, step 13.)
/// - Every committed chunk updates the hot-document cache once and delivers
///   exactly one commit event to the watches.
/// - With deferred indexes (see [BulkWriterOptions.deferIndexes]), a query
///   whose plan needs a deferred index waits until the writer closes;
///   document watches (by id) keep firing per chunk.
///
/// A writer is single-use: [close] flushes everything, rebuilds the deferred
/// indexes and completes; calling it or queueing after that throws a
/// [StateError].
final class BulkWriter {
  /// Builds a writer over [db]; applications get one from `db.bulkWriter()`.
  @internal
  BulkWriter(this._db, [this._options = const BulkWriterOptions()]) {
    if (_options.chunkSize < 1) {
      throw ArgumentError.value(
        _options.chunkSize,
        'chunkSize',
        'Must be at least 1',
      );
    }
    _db.noteBulkWriterActive();
  }

  final Cocoon _db;
  final BulkWriterOptions _options;

  final List<_QueuedOp> _ops = [];

  /// Uncommitted operation count per SQL table — what the deferral rule
  /// compares against the table's row count.
  final Map<String, int> _bufferedPerTable = {};

  /// Tables whose deferral decision was already made (decided once, on the
  /// first chunk that touches the table).
  final Set<String> _deferralDecided = {};

  /// The indexes THIS writer dropped; `close()` rebuilds exactly these.
  final List<_DeferredIndex> _deferred = [];

  final List<(int target, Completer<void> completer)> _waiters = [];

  bool _closed = false;
  bool _pumping = false;
  var _committed = 0;

  /// How many operations pending flushes still wait for ([flush] targets;
  /// `close()` drains everything).
  var _goal = 0;
  var _drainEverything = false;

  Object? _failure;
  StackTrace? _failureTrace;

  /// Queues an upsert of [value] at [ref].
  ///
  /// Throws an [ArgumentError] when [ref]'s adapter was not registered when
  /// the database was opened (the same validation a standalone `set` runs,
  /// but at queue time), and a [StateError] after [close].
  void set<T extends Object>(DocRef<T> ref, T value) {
    _queue(ref, value, BatchOpKind.set);
  }

  /// Queues a replace of the existing document at [ref] with [value].
  ///
  /// The chunk fails when the document does not exist at commit time.
  /// Throws an [ArgumentError] at queue time for an unregistered adapter,
  /// and a [StateError] after [close].
  void update<T extends Object>(DocRef<T> ref, T value) {
    _queue(ref, value, BatchOpKind.update);
  }

  /// Queues a delete of [ref] and its whole subtree.
  ///
  /// Throws an [ArgumentError] at queue time for an unregistered adapter,
  /// and a [StateError] after [close].
  void delete(DocRef<Object> ref) {
    _checkUsable();
    final entry = _db.registry.entryFor(ref.adapter);
    _enqueue(_QueuedOp(BatchOpKind.delete, entry, ref, null));
  }

  /// Commits every operation queued so far and resolves when they are
  /// durable; later operations keep buffering for the next chunk. Resolves
  /// immediately when nothing is queued.
  ///
  /// Throws the chunk failure when a chunk already failed (its writes rolled
  /// back; the writer is then unusable).
  Future<void> flush() {
    _checkUsable();
    if (_failure != null) {
      return Future.error(_failure!, _failureTrace);
    }
    final target = _committed + _ops.length;
    if (target == _committed) {
      return Future.value();
    }
    if (_goal < target) {
      _goal = target;
    }
    _kick();
    return _waitFor(target);
  }

  /// Flushes every queued operation, rebuilds the indexes the writer
  /// deferred (one write transaction: `CREATE INDEX` per index, meta rows
  /// deleted), and resolves when everything is durable. Using the writer
  /// after [close] throws a [StateError], and so does closing it twice.
  ///
  /// If a chunk failed, [close] still rebuilds the deferred indexes (the
  /// database must not keep them dropped) and then rethrows that failure.
  Future<void> close() async {
    _checkUsable();
    _closed = true;
    _drainEverything = true;
    _goal = _committed + _ops.length;
    _kick();
    Object? error;
    StackTrace? stackTrace;
    if (_failure != null) {
      error = _failure;
      stackTrace = _failureTrace;
    } else {
      try {
        await _waitFor(_committed + _ops.length);
      } on Object catch (e, s) {
        error = e;
        stackTrace = s;
      }
    }
    // Whatever happened above, a deferred index must not stay dropped: the
    // meta rows are on disk and recovery-on-open would otherwise be the only
    // thing that rebuilds them.
    try {
      await _finishDeferredIndexes();
    } on Object catch (e, s) {
      error ??= e;
      stackTrace ??= s;
    }
    _db.noteBulkWriterClosed();
    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
  }

  void _queue<T extends Object>(DocRef<T> ref, T value, BatchOpKind kind) {
    _checkUsable();
    final entry = _db.registry.entryFor(ref.adapter);
    _enqueue(_QueuedOp(kind, entry, ref, value));
  }

  void _enqueue(_QueuedOp op) {
    _ops.add(op);
    final table = op.entry.table;
    _bufferedPerTable[table] = (_bufferedPerTable[table] ?? 0) + 1;
    _kick();
  }

  /// Starts the serialized chunk loop when there is chunk-sized work, an
  /// unmet flush goal, or a close draining everything.
  void _kick() {
    if (_pumping || _failure != null) {
      return;
    }
    _pumping = true;
    unawaited(
      Future<void>(() async {
        try {
          while (_failure == null && _ops.isNotEmpty) {
            final chunkReady = _ops.length >= _options.chunkSize;
            final goalPending = _committed < _goal;
            if (!chunkReady && !goalPending && !_drainEverything) {
              break;
            }
            await _commitChunk(chunkReady ? _options.chunkSize : _ops.length);
          }
        } on Object catch (error, stackTrace) {
          _fail(error, stackTrace);
        } finally {
          _pumping = false;
        }
      }),
    );
  }

  /// Commits the first [take] buffered operations as one chunk: one write
  /// transaction, one cache stage, one watch event, one batch of change-log
  /// rows.
  Future<void> _commitChunk(int take) async {
    final chunk = List<_QueuedOp>.of(_ops.take(take));
    _ops.removeRange(0, take);
    final chunkPerTable = <String, int>{};
    for (final op in chunk) {
      final table = op.entry.table;
      _bufferedPerTable[table] = _bufferedPerTable[table]! - 1;
      chunkPerTable[table] = (chunkPerTable[table] ?? 0) + 1;
    }
    // Tables this chunk touches for the first time get their deferral
    // decision now; the DDL lands in the same transaction as the chunk.
    final firstTouch = <RegistryEntry>[];
    for (final op in chunk) {
      final entry = op.entry;
      if (!_deferralDecided.add(entry.table)) {
        continue;
      }
      if (!_options.deferIndexes || entry.indexes.isEmpty) {
        continue;
      }
      firstTouch.add(entry);
    }
    final deferredInTx = <_DeferredIndex>[];

    await _db.writeTx<void>((wtx) async {
      for (final entry in firstTouch) {
        // The rule: defer only when it pays — an empty table, or a load
        // buffering more rows than the table already holds. Measured
        // cross-over: see benchmarks/cocoon_rivals/IMPORT.md, step 13.
        final row = await wtx.tx.getOptional(
          'SELECT count(*) AS c FROM ${entry.table}',
        );
        final rowCount = row == null ? 0 : row['c']! as int;
        final buffered =
            (_bufferedPerTable[entry.table] ?? 0) +
            (chunkPerTable[entry.table] ?? 0);
        if (rowCount != 0 && buffered <= rowCount) {
          continue;
        }
        await wtx.tx.execute(createBulkTableSql());
        for (final index in entry.indexes) {
          final sql = createIndexSql(entry.table, index);
          await wtx.tx.execute(
            'INSERT INTO $bulkTableName (tbl, index_name, sql) VALUES (?, ?, ?)',
            [entry.table, index.name, sql],
          );
          await wtx.tx.execute('DROP INDEX IF EXISTS "${index.name}"');
          deferredInTx.add(_DeferredIndex(entry.table, index.name, sql));
        }
      }
      for (final op in chunk) {
        switch (op.kind) {
          case BatchOpKind.set:
            await wtx.put(op.ref, op.value!);
          case BatchOpKind.update:
            await wtx.put(op.ref, op.value!, update: true);
          case BatchOpKind.delete:
            await wtx.delete(op.ref);
        }
      }
    });

    // The chunk committed: everything in it is durable, its cache updates
    // applied and its watch event delivered. Wake the flushes that waited
    // for it.
    _committed += take;
    _serveWaiters();

    if (deferredInTx.isEmpty) {
      return;
    }
    // The chunk (drop included) committed: record what this writer must
    // rebuild at close, and hold queries that need these indexes.
    _deferred.addAll(deferredInTx);
    _db.noteIndexesDeferred([for (final d in deferredInTx) d.name]);
  }

  /// A future that completes when [target] operations have been committed
  /// (or the writer failed, or the database closed under it).
  Future<void> _waitFor(int target) {
    final completer = Completer<void>();
    _waiters.add((target, completer));
    if (_committed >= target) {
      _serveWaiters();
    }
    return completer.future;
  }

  /// Completes every flush whose target the committed count reached.
  void _serveWaiters() {
    for (final (target, completer) in List.of(_waiters)) {
      if (_committed >= target) {
        _waiters.remove((target, completer));
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }
  }

  /// Records the first chunk failure: the writer stops committing, every
  /// waiter receives the error, and the buffered operations are discarded
  /// (they were never started; the failed chunk rolled back whole).
  void _fail(Object error, StackTrace stackTrace) {
    _failure ??= error;
    _failureTrace ??= stackTrace;
    _ops.clear();
    for (final (_, completer) in _waiters) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
    _waiters.clear();
  }

  /// Rebuilds the indexes this writer deferred and clears its meta rows, in
  /// one write transaction. A no-op when nothing was deferred.
  Future<void> _finishDeferredIndexes() async {
    if (_deferred.isEmpty) {
      return;
    }
    final names = [for (final d in _deferred) d.name];
    await _db.executor.writeTransaction((tx) async {
      for (final d in _deferred) {
        await tx.execute(d.sql);
      }
      for (final d in _deferred) {
        await tx.execute(
          'DELETE FROM $bulkTableName WHERE tbl = ? AND index_name = ?',
          [d.table, d.name],
        );
      }
    });
    _deferred.clear();
    _db.noteIndexesRestored(names);
  }

  void _checkUsable() {
    if (_closed) {
      throw StateError('This BulkWriter was already closed');
    }
  }
}
