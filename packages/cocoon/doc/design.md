# Cocoon design

Cocoon is a typed, disk-backed, Firestore-style local database for Dart and
Flutter. This file is the short decision record; the full documentation lives
on the docs site under **Cocoon**:

- [Overview & Why Cocoon](/libraries/cocoon) — the comparison table and
  installation.
- [Models & Code Generation](/libraries/cocoon/models) — annotations, the
  generator's rules and outputs.
- [Collections & Documents](/libraries/cocoon/collections) — refs, cascade
  deletes, transactions, the hot-document cache.
- [Queries & Indexes](/libraries/cocoon/queries) — the index rule, collection
  groups, keyset pagination.
- [Realtime](/libraries/cocoon/realtime) — watches, dedup, coalescing, the
  change log.
- [Schema Migrations](/libraries/cocoon/migrations) — the lock, the migrate
  command, the on-device runner.
- [DevTools Inspector](/libraries/cocoon/inspector) — the Cocoon tab for
  running debug apps.
- [Internals](/libraries/cocoon/internals) — storage layout, wire format,
  money guidance.

## Decisions

- **Why:** nothing in Dart gives typed + on-disk (bounded RAM) + real
  queries + a Firestore-style API at once (sembast: `Map` and whole-DB-in-RAM;
  Hive CE: no queries, boxes load everything; drift: tables + SQL, not a
  document tree; Isar: stalled; ObjectBox: closed core).
- **Engine: SQLite** through `sqlite_async` (one writer + reader isolates,
  WAL, transactions) on top of `package:sqlite3` (FFI). Not drift: a library
  pinning drift clashes with apps that already use it, and Cocoon replaces
  drift's codegen and change tracking anyway. Everything goes through the
  internal `CocoonExecutor` interface; only `sqlite_executor.dart` imports
  the SQLite packages.
- **One table per collection model**, not per parent instance and not one
  shared `docs` table: change notifications scoped per collection, no sparse
  columns, no `collection` column in every index, per-table planner
  statistics.
- **Path params are typed columns** (`p_account_id`): querying one parent is
  an index range scan; skipping the parent filter is a collection-group
  query for free. The full path is kept, so a subtree is
  `path >= 'accounts/a1/' AND path < 'accounts/a10'`.
- **Document body is a canonical protobuf blob** (`data`), encoded by
  generated code (`WireWriter`): ascending field numbers, no unknown fields,
  the same document always yields the same bytes — so watches can
  deduplicate by byte equality and a journal chain can hash it.
- **Indexed fields are copied into real typed columns at write time**
  (`f_`-prefixed, with `typeof` CHECKs): SQLite can't look inside the blob,
  and real columns beat JSON generated columns (real integers, no silent
  REAL-vs-INTEGER drift, real indexes).
- **No in-memory copy of the database**: a bounded LRU cache of recently
  read documents gives Hive-like hot reads while RAM stays capped. This
  requires one `Cocoon` instance to own the database file.
- **Models are the schema**: field identity is the field number, pinned per
  model in the committed `cocoon.lock.json`; reordering fields never
  matters. Adds, drops, reorders and index changes need no migration; renames
  are confirmed in the interactive `migrate` command; type changes move the
  field to a fresh number (the old reserved forever) and write a typed
  conversion stub.
- **Who runs what:** `dart run cocoon_generator:migrate` on the developer's
  machine writes the lock and migration files (both committed, so renames
  show up in review); build_runner only generates and **fails** on any
  models/lock disagreement or unimplemented stub — it never writes the lock;
  on device, `Cocoon.open` applies pending migrations once, in order, inside
  one transaction (wire-level rewrites in batches of 500, one change-log row
  per rewritten document, migrated columns and indexes rebuilt from the
  rewritten bytes). A file newer than the app refuses to open.
- **Queries:** Firestore-strict index rule (equality names, then sort keys,
  at most one range key) or `MissingIndexException` naming the `Index([...])`
  to declare; `.allowFullScan()` opts out. Keyset pagination only, with
  opaque fingerprinted cursors that are query-bound but page-size agnostic.
  Sort keys are NOT NULL; the document id is the final tiebreaker.
- **Transactions** wrap sqlite_async's write transaction; reads see the
  transaction's own writes (never the cache); cache updates are staged and
  applied only after the commit succeeds. Standalone writes each open their
  own transaction. Document writes buffer inside the transaction and flush
  as batched statements before the commit (and before any read or delete in
  the same transaction, and every 2,000 queued rows), so a large
  transaction costs two isolate round trips per ~1,000 documents instead of
  two per document.
- **Bulk writes** go through `db.batch()` (`WriteBatch`): queue
  `set`/`update`/`delete` synchronously, commit as one write transaction
  with the same batched flush, one cache stage and one commit event.
  Per-operation validation and semantics match the standalone calls;
  `update` (replace-if-exists) is checked against the transaction's own
  state so a `set` earlier in the batch satisfies it.
- **Bulk loads** go through `db.bulkWriter()` (`BulkWriter`), Firestore's
  BulkWriter shape: queue writes synchronously, commit every
  `chunkSize` rows (default 10,000, the measured knee of the commit-size
  curve) as one write transaction — atomic per chunk, never as a whole —
  with one cache stage and one watch event per chunk. On the first chunk
  per table, when deferral pays (the table is empty or the writer has
  buffered more rows than the table holds), the same transaction records
  the table's secondary-index DDL in `_cocoon_bulk` and drops the indexes;
  `close()` rebuilds them and deletes the rows in one transaction, and an
  open that finds rows left behind (a crash mid-load) rebuilds the indexes
  before handing the database to the app. The scope index and the unique
  `path` constraint are never dropped. A query whose plan needs a deferred
  index waits until the writer closes (`PlannedQuery.servingIndex`); `get()`
  by id is unaffected. Measured on the 1M rivals dataset
  (`benchmarks/cocoon_rivals/IMPORT.md`, step 13): 103 s through
  `db.batch()` per 1000 rows, ~13 s through the default `bulkWriter()`
  (raw SQLite's deferred-index ceiling: 9.5 s). Inserting in path order was
  measured and kept out — it cost ~1 s and won nothing at the engine's
  chunk granularity.
- **The write hot path builds no SQL strings per document**: each
  collection's upsert and update statements are built once at registry
  time, and a write caches the document's encoded bytes (`EncodedDoc`) —
  the first cache read decodes them once, which is exactly what the stored
  bytes decode to (for example `DateTime` fields come back normalized to
  UTC) without paying a decode per write.
- **Connection setup is the engine's**: `Cocoon.open` builds every
  connection through `CocoonSqliteOpenFactory` (a `NativeSqliteOpenFactory`),
  applying `PRAGMA cache_size` (default 64 MiB, `pageCacheMiB`), `PRAGMA
  temp_store = MEMORY` (`tempStoreInMemory`), `PRAGMA wal_autocheckpoint`
  (default 8000 pages, `walAutoCheckpointPages` — SQLite's 1000-page default
  checkpoints after nearly every bulk-import commit and dominated the 1M
  import) on writer and readers alike, and opening with sqlite_async's
  `profileQueries` off — its per-statement timeline tracing cost ~5 s of a
  100k import in dev builds and nothing in Cocoon reads those events.
  Measured in `benchmarks/cocoon_rivals/IMPORT.md`; `WITHOUT ROWID` was
  considered and rejected there (the long `path` key would bloat every
  secondary index), as was `wal_autocheckpoint = 0` (unbounded WAL).
- **Realtime:** one commit event (the distinct (table, path, op) set) is
  delivered to the watch hub after the cache is updated — never for a
  rolled-back transaction. Doc watches re-read only their exact path; query
  watches only their table (and parent scope); bursts are coalesced;
  emissions identical in canonical bytes are suppressed; `watchFrom(cursor)`
  pins a fixed anchor. Change-log rows are on disk (`_cocoon_changes`) and
  prunable, ready for a sync outbox or audit trail.
- **Backups and restores are two engine file primitives; the app owns the
  policy** (when and where, which collections, compression, encryption,
  files outside the database, validation, UI — no app-level backup file
  format, no cryptography, no export/import stream). `db.backupTo()` copies
  the whole file with SQLite's `VACUUM INTO`: one read snapshot while the
  app keeps writing, and the copy is compacted in the same step (the online
  backup API is not exposed by package:sqlite3's public surface, so it is
  not reachable through the package's one sqlite-import rule). The copy is
  written to `<path>.partial`, fsynced and renamed atomically; an existing
  target refuses unless `overwrite`, and the copy is stamped in its own
  `_cocoon_meta` with the backup format version, created-at, the snapshot's
  change-log head and the Cocoon version (schema version and lock hash ride
  along in the copied rows). `Cocoon.inspectBackup()` verifies the marker
  and runs `PRAGMA integrity_check`, with typed errors for not-a-backup,
  damaged and format-too-new. `Cocoon.restoreBackup()` refuses a target this
  isolate holds open, applies open's schema rule (a newer backup refuses; an
  older one migrates at the next open) before any file changes, then swaps:
  copy to `<path>.restoring`, re-roll the copy's instance id, move the
  current database with its WAL/journal sidecars to
  `<path>.before-restore` (or delete after the swap when `keepPrevious` is
  false), drop the target's stale sidecars, rename, fsync. Every step is
  failure-injectable in tests; a failure at any of them undoes the steps
  before it. Measured on the 1M rivals dataset (step 16): `backupTo` 0.8-1.0
  s for a 388 MB file, single writes during the backup p95 ~5 ms,
  `restoreBackup` 6.9-7.5 s.
- **Every database has an instance id** (`_cocoon_meta`, exposed as
  `db.instanceId`): a random id created with the database and re-rolled by
  `restoreBackup`. A restore rewinds the change log and `lastChangeSeq` to
  the backup's, so a sync consumer's saved watermark may be AHEAD of the
  database — consumers save the instance id next to the watermark and
  distrust the watermark when it differs. Within one instance the old
  guarantee stands unchanged: `lastChangeSeq` never goes backwards.
- **Large binaries** (receipts, statements) stay as files; documents store
  paths.
- **Inspector**: read-only `dart:developer` service extensions
  (`ext.cocoon.*`) register once per process when a database opens, in
  debug and profile builds only (product never registers). Handlers answer
  plain JSON and committed changes stream as `cocoon:changes` events from
  the commit notifier. The DevTools tab (`packages/cocoon_devtools`, a
  Flutter web app compiled into `extension/devtools/`) is a pure client
  over the service protocol — it never imports the engine, and documents
  decode through the generated adapter's `toInspectorJson`.
- **Map fields** follow protobuf map semantics: one nested entry message per
  entry, key at field 1, value at field 2; keys are `String` or `int`, values
  any supported non-Map type. Entries are written sorted by key, so equal
  maps always give equal canonical bytes — the journal-chain hash depends on
  it. Maps stay inside the document blob (never columns), so they cannot be
  indexed; a map type change migrates like any other (fresh field number,
  `fromMap`/`toMap: MapWireType(key:, value:)` on the `FieldMigration`).
- **Document ids**: time-ordered UUIDv7 (`newDocId()`); `validateDocId`
  enforces path-safe ids.

## Money

Cocoon stores integers exactly: use `int` minor units plus an ISO 4217
currency code, written as zigzag `sint64` and indexed as SQLite `INTEGER`.
`SUM` over integer columns is exact and throws on overflow. Never `TOTAL()`
or `AVG()` for money; never sum across currencies.

## Platforms

Native first (Android, iOS, macOS, Linux, Windows). The wire codec relies on
64-bit `int`; web needs a separate integer path and a SQLite WASM + OPFS
executor, so it is deferred.

## Status

| Piece | State |
|---|---|
| Annotations (`Collection`, `Index`, `Embedded`, `Ignore`) | done |
| Paths (`CollectionPattern`, `CollectionPath`, `DocPath`) | done |
| Canonical wire codec (`WireWriter`, `WireReader`) | done |
| Cursors (`CursorCodec`, `queryFingerprint`) | done |
| Schema lock + diff + rename resolution | done |
| Storage engine (executor, tables, index columns, transactions) | done |
| Hand-written adapter contract (`CollectionAdapter`, columns, indexes) | done |
| Indexed queries, keyset pagination, count, index rule | done |
| Open + reconcile (backfill, column/index diff, shape hash) | done |
| Document ids (`newDocId`, UUIDv7) | done |
| Bounded LRU document cache | done |
| Change log + watches | done |
| build_runner generator (`cocoon_generator`), `@Embedded`, lock check | done |
| Example package (`cocoon_example`) | done |
| `dart run cocoon_generator:migrate` interactive CLI | done |
| On-device migration runner (`Cocoon.open` schema versions) | done |
| Documentation site section (`docs/libraries/cocoon/`) | done |
| DevTools extension (`packages/cocoon_devtools`, `ext.cocoon.*` service extensions) | done |
| `Map<String, V>` / `Map<int, V>` fields (canonical protobuf map encoding, sorted keys; generator, migrations, inspector) | done |
| Benchmark vs sembast (`packages/cocoon_bench`, finance-shaped data, `RESULTS.md`; memory measured against a harness-only baseline, write-durability and cache-size knobs measured) | done |
| Rivals benchmark (`benchmarks/cocoon_rivals`, 7 engines incl. cocoon at `Durability.normal`, drift, Isar, ObjectBox, Hive CE, sembast; 10k-1M txns, 13 ops, `RESULTS.md` with per-workload verdicts) | done |
| Bulk-write path: `WriteBatch` (`db.batch()`), buffered transaction writes, per-collection prebuilt write SQL, byte-caching hot entries | done |
| Bulk-load path: `BulkWriter` (`db.bulkWriter()`), chunked commits, deferred secondary indexes + crash recovery via `_cocoon_bulk` | done |
| Import-performance knobs: `pageCacheMiB` (64 MiB page cache), `tempStoreInMemory`, sqlite_async `profileQueries` off; measurements in `benchmarks/cocoon_rivals/IMPORT.md` | done |
| Whole-database backups: `db.backupTo()` (`VACUUM INTO` snapshot, stamped `_cocoon_meta`), `Cocoon.inspectBackup()`, `Cocoon.restoreBackup()` (closed-target rule, compatibility before the swap, `.restoring`/`.before-restore` protocol) + database instance id (`db.instanceId`) | done |
| Export/import streams (documents through the public API, NDJSON-shaped) | planned |
| Incremental backups (change-log-tailed deltas on top of `backupTo`) | planned |
