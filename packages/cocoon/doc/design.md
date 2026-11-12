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
  model in the committed `cocoon.lock`; reordering fields never
  matters. Adds, drops, reorders and index changes need no migration; renames
  are confirmed in the interactive `migrate` command; type changes move the
  field to a fresh number (the old reserved forever) and write a typed
  conversion stub. An added field that is non-nullable without a
  constructor default would silently read its proto3 zero value in every
  pre-existing document, so `migrate` asks for a one-off decision (the
  Django `makemigrations` idea): write a generated backfill stub that the
  engine runs over the existing documents at the next open, or record a
  deliberate keep-the-zero in the lock — never a silent zero.
- **Who runs what:** `dart run cocoon_generator:migrate` on the developer's
  machine writes the lock and migration files (both committed, so renames
  show up in review); build_runner only generates and **fails** on any
  models/lock disagreement or unimplemented stub — it never writes the lock;
  on device, `Cocoon.open` applies pending migrations once, in order, inside
  one transaction (wire-level rewrites in batches of 500, then document
  backfills — each stub receives the decoded document as the rewrites left
  it and its value is written at the new field's number — one change-log row
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
- **Inside a transaction, every database access goes through the
  transaction object — enforced, not advised.** A call on the database
  itself inside a `runTransaction` body is wrong two ways: a write
  (`DocRef.set`/`delete`, `CollectionRef.add`, `batch().commit()`, a
  `BulkWriter`, a nested `runTransaction`) waits forever for the write lock
  the body already holds — no error, the app just stops — and a read
  (`DocRef.get`, a query's `get`/`count`, aggregates, `groupBy`,
  `collectionGroup`, `db.getAll`, `backupTo`) runs on a read connection and
  silently sees committed data only, never the transaction's own writes
  (Firestore's rule is the same: inside a transaction, every read and
  write goes through the transaction). The engine runs the body in a Zone
  carrying a private `{db, active}` scope; the public entry points cost one
  zone lookup and throw a `TransactionMisuseError extends StateError`
  immediately — it names the operation (e.g. `DocRef.set`) and ends with a
  one-line `Fix:` hint, like the missing-index message. The scope
  deactivates the moment the SQL transaction ends (commit OR rollback),
  before the cache apply, watch emit and retention, so futures and timers
  the body created that run later never trip the guard. The check is
  always on, debug and release: it prevents a hang, not a development-only
  bug. Only the SAME `Cocoon` instance is guarded — reads and writes on a
  different open `Cocoon` (another file) inside the body are allowed and
  work — and starting a `watch()` is allowed (its first value inside the
  body reflects committed data; the transaction's writes arrive with its
  commit event). Internal engine paths (WriteTx, batch and bulk-writer
  internals, watches, migrations, format migration, retention, the
  inspector) deliberately bypass the guard: they either run inside the
  transaction already or must keep reading committed data (watch pumps,
  the inspector's DevTools views). Known upstream trap on the pinned
  sqlite_async (0.14.8): a continuation registered inside the body still
  carries the library's own internal lock-guard Zone, so a write it makes
  through the SAME database after the transaction ended fails with a
  `LockError` even though Cocoon's guard is inactive — reproduced with a
  raw sqlite_async probe (no Cocoon involved); register such follow-up
  work outside the body, or hop zones (`Zone.root.run`) around it.
  Related later idea: a `tx.query(...)` that reads through the write
  connection and sees the transaction's own writes (Status: planned).
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
- **Aggregates push the math into SQLite; grouping is a Cocoon extension.**
  `query.aggregate([count(), sum(f), average(f)])` (plus Cocoon's `minOf`/
  `maxOf`) runs ONE statement over the mirrored `f_` columns — the planner,
  index rule, full-scan opt-out and bulk-writer wait are exactly the
  query's, `count()` is sugar for it, and `orderBy` + `limit` aggregate the
  first N rows as a subquery (no limit: the `ORDER BY` drops). Semantics
  follow Firestore: integer sums are exact and an overflow past ±2^63
  surfaces as a typed error (SQLite aborts the statement; the standard
  executor maps it to `AggregateOverflowException`), empty sums are `0`,
  averages are always `double?`, nulls are skipped by sum/average/min/max
  and counted by count, and getters for unrequested functions throw.
  Aggregatable fields are the mirrored ones — anything else throws
  `UnmirroredFieldException` naming the declaration that would mirror it
  (see the `@Mirrored()` decision below).
  `query.groupBy([...])` (NOT in Firestore) buckets by `key` (a field or a
  path param — one aggregate per parent for collection groups), `bucket`
  (fixed-width numeric bands, `floor(v/w)*w` in exact integer arithmetic —
  no floats, correct below epoch) and `year`/`month`/`day` calendar buckets
  on `DateTime` fields, which REQUIRE a fixed `utcOffset` (no IANA/DST: the
  dartdoc tells DST zones to run one range-filtered aggregate per period
  instead). Up to 4 keys, groups ordered by the keys ascending with null
  keys first, optional `.limit(n)`. Aggregate and group queries watch like
  queries: first emission on listen, table-(and scope-)scoped re-runs,
  coalesced, equal consecutive values suppressed.
- **`@Mirrored()`: a column without an index, so totals don't buy an index.**
  Step 17 made "aggregatable" mean "indexed", which forced an `Index([...])`
  a pure-total app never uses. `@Mirrored()` on a field stores it in its own
  `f_` column — same type mapping, nullability and CHECK as an index field,
  same add-and-backfill (one pass, in the open transaction) and drop path as
  an index column — but creates no index. Aggregates and `groupBy` accept
  it; a `where`/`orderBy` on it still follows the index rule
  (`MissingIndexException` suggesting the `Index`, or `allowFullScan()`),
  and the "field has no column" error names both fixes. A field that is both
  mirrored and indexed is just indexed (one column, one index); the
  annotation is refused on the types index fields refuse (lists, maps,
  embedded classes) and inside `@Embedded` classes (no column exists).
  `bulkWriter()` writes mirrored columns like any other; index deferral has
  nothing to defer for them. The lock records mirrored fields additively
  (omitted when empty, so pre-step-18 locks round-trip byte-for-byte).
- **The stored identity is the scope key, not the path (storage format 2).**
  Collection tables have no `path` column and no path autoindex: a document
  is its `p_` param columns plus `id`, unique through the scope index, and
  every path the API shows (refs, snapshots, cache keys, watch keys, change
  log rows) is derived from it by one shared helper, tested round-trip in
  both directions. Measured at 1M in
  `benchmarks/cocoon_rivals/STORAGE.md`: 69.8 MB of the file (the column
  inside every row plus its autoindex) with every read as fast as before —
  get +3 µs (noise), latest-50 equal, delete faster (23 vs 28 µs
  statement-time), and a 1M `bulkWriter()` import 1 s faster (11.9 s).
  Subtree deletes key each child table by its leading param columns
  (deleting `accounts/a1` deletes the txns with `p_account_id = 'a1'`) in
  the same transaction — measured: one account plus its 50,000 txns in
  1.16 s. Files are versioned in `_cocoon_meta` (`format_version`): an
  older file is rebuilt table by table (new table, `INSERT ... SELECT`,
  drop, rename, indexes recreated) inside the open that first touches it,
  crash-safe — a failure leaves the old layout and the next open finishes —
  and reports progress through `onMigrationProgress`; a file written by a
  NEWER format refuses to open with `StorageFormatTooNewException`, and
  `restoreBackup` applies the same rule to backups while accepting
  older-format ones (they migrate at the next open). Measured on a copy of
  the real pre-step-20 1M file: 5.1-8.7 s, data and change log intact,
  `VACUUM`/`backupTo` afterwards compacts to exactly the shipped layout's
  size (304.9 MiB). Since step 23 the upgrade open compacts by itself when
  it is done (`CocoonOptions.compactAfterUpgrade`, default on): the dropped
  tables leave 41.3% of the upgraded 1M file's pages on the freelist, past
  the 20% threshold, so the open runs one `VACUUM` after its transaction
  commits — 390.1 → 304.9 MiB, freelist 0, ~1.1 s at 1M and ~34 ms on a
  0.5 MiB file, measured in
  `benchmarks/cocoon_rivals/STORAGE.md`. A compaction that cannot run (a
  full disk) is reported through `CocoonOptions.onCompactionFailed` and
  never fails the open; normal opens never compact.
- **`@Indexed()` on the field: the one-field index lives where the field is.**
  Single-field indexes were class-level `Index([...])` lines physically far
  from the field they index. `@Indexed()` (with `descending:`/`unique:`)
  declares exactly `Index(['field'])` on the field itself; the generator
  merges field-level and class-level declarations into one list, an index
  declared both ways is one index, and the physical index name comes from
  the canonical form — so moving a one-field index between the two places
  is a source cosmetic: the canonical form is identical, the schema diff
  compares index SETS (declaration order ignored) and the table shape hash
  sorts index canonicals, so no schema version bump, no rebuild, no lock
  change. Composites (two or more parts) and path params stay class-level:
  path params are not fields. The same types and embedded-class rules as
  `@Mirrored()` apply (generator errors in the same style).
- **Stacked `@Index([...])`: composites sit right above the class they
  index.** Composites used to live only inside
  `@Collection(indexes: [...])`, far from the class they describe and
  verbose to grow. `Index` gained `@Target({TargetKind.classType})` and the
  generator reads every `@Index` on the class in source order, merging them
  with `indexes:` entries and field-level `@Indexed()` declarations into one
  list — the same canonical index declared in any mix of the three forms is
  ONE index (keep-first), and the physical index name comes from the
  canonical form, so moving an index between the forms changes nothing in
  `cocoon.lock` (byte-identical), causes no schema bump and no rebuild.
  `indexes:` stays the alternative for a shared `const` list. `@Index` on
  anything that is not a `@Collection` class — including on a field, where
  the analyzer's target check is only a warning — is a build error naming
  the class.
- **The missing-index error carries its fix, and a debug-only fallback.**
  The `MissingIndexException` message ends with exactly one `Fix:` line:
  `dart run cocoon_generator:index add <Model> <fields>` (the ready command)
  plus the declaration it would write — `@Indexed()` on the field for a
  single model field, a stacked `@Index([...])` line above the class
  otherwise. Decided with
  the maintainer: indexes live in the model, never in YAML and never in
  `cocoon.lock`, so the fix is a source edit the command performs (analyzer
  model discovery, did-you-mean validation, narrow literal edits only, dart
  format, idempotent re-runs), and `--missing <file|->` applies a whole
  saved debug log's `Fix:` lines in one pass (any line prefix, deduped,
  one result line per index; `--dry-run` previews without writing) — on a
  phone the model files are on the device, but the log is text the developer
  already has. For schema exploration,
  `CocoonOptions.onMissingIndex = MissingIndexMode.scanAndWarn` runs a
  suggestable missing-index query as a full scan, prints the message once
  per distinct missing index per process (`dart:developer` log + stderr)
  and records a typed report in `db.missingIndexes` (model, index parts,
  query shape, fix command, first seen). It is honoured ONLY while asserts
  are enabled: a release build throws like the default, so a forgotten
  `allowFullScan()` can never silently degrade a shipped query — the reason
  this is an option and not a global default. It never creates an index at
  runtime; multi-range and no-anchor queries still throw (nothing to
  suggest, nothing to debug-scan).
- **The change log is the app's to bound.** `pruneChanges` returns the rows
  deleted; `earliestChangeSeq` reports the oldest readable seq; reading
  from a pruned watermark throws `ChangesPrunedException` (the Firestore
  "resume token expired" idea) so a sync consumer resyncs fully instead of
  silently skipping. `CocoonOptions.changeRetention`
  (`ChangeRetention(maxChanges:, maxAge:)`) bounds the log automatically,
  enforced in small batches after commits — never inside a user transaction
  — and `BulkWriterOptions(logChanges: false)` skips the load's log rows
  entirely (sync consumers then resync). `lastChangeSeq` keeps its
  monotonicity guarantee: it reads the AUTOINCREMENT head, not `MAX(seq)`.
- **Many documents by id are one trip, not one trip per document.**
  `db.getAll(refs)` (plus `tx.getAll` and `collection.getAll(ids)`) answers
  in refs order with `null` for missing documents and duplicates allowed.
  The bounded cache answers what it holds without SQL; only the misses go
  to SQLite, grouped per table and fetched with one statement per chunk of
  500 scope keys (`(p_params, id) IN (VALUES ...)` for subcollections,
  `id IN (...)` for root collections), every chunk of one call inside ONE
  read transaction — the whole answer is one consistent snapshot. Measured
  on the 1M rivals dataset (`benchmarks/cocoon_rivals/GETALL.md`): 1,000
  ids in 8.7 ms cold vs 75 ms one-by-one (the rivals `gets` workload's
  shape), 0.2 ms warm, at parity with drift's single `isIn`; the chunk-size
  sweep puts 500 at the knee (within ~10% of the statement-size floor, a
  few thousand placeholders per statement, far under SQLite's variable
  limit). Coherence is exactly `get()`'s: fetched documents populate the
  cache like `get()` does, reads never wait for deferred bulk indexes, and
  a transaction's `getAll` sees its own writes and caches nothing until the
  commit succeeds.
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
| Annotations (`Collection`, `Index`, `Indexed`, `Mirrored`, `Embedded`, `Ignore`) | done |
| Field-level `@Indexed()` (one-field index on the field; merged with class-level composites, same canonical form either way — moving one bumps nothing) | done |
| Stacked `@Index([...])` above the class (composites lead with it; `indexes:` stays for shared const lists; the same canonical index in any mix of the three forms is one index — moving one bumps nothing); `@Index` anywhere but a `@Collection` class is a build error naming the class | done |
| Missing-index ready fix: `MissingIndexException.fixCommand` + the message's `Fix:` line; `dart run cocoon_generator:index add <Model> <fields>` (analyzer discovery, did-you-mean, dart format, idempotent across all three forms; one-field → `@Indexed()` on the field, composites and path params → one stacked `@Index` line above the class, `indexes:` never touched; `--unique`; `--dry-run`); `butterfly cocoon index add` passthrough + MCP tool | done |
| `index add --missing <file|->`: scans a saved debug log (any line prefix) for every `Fix:` line, dedupes, applies each through the single-index code path with one result line per index and a summary; `-` reads stdin; `--dry-run` on both forms | done |
| Debug-only missing-index fallback: `CocoonOptions.onMissingIndex = MissingIndexMode.scanAndWarn` (asserts-enabled builds only), warn-once per process, `db.missingIndexes` reports, never creates an index | done |
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
| Many-by-id reads: `db.getAll(refs)`, `tx.getAll(refs)`, `collection.getAll(ids)` — cache-first, misses grouped per table in one statement per 500 scope keys inside one read transaction; measured in `benchmarks/cocoon_rivals/GETALL.md` | done |
| Bulk-load path: `BulkWriter` (`db.bulkWriter()`), chunked commits, deferred secondary indexes + crash recovery via `_cocoon_bulk` | done |
| Import-performance knobs: `pageCacheMiB` (64 MiB page cache), `tempStoreInMemory`, sqlite_async `profileQueries` off; measurements in `benchmarks/cocoon_rivals/IMPORT.md` | done |
| Whole-database backups: `db.backupTo()` (`VACUUM INTO` snapshot, stamped `_cocoon_meta`), `Cocoon.inspectBackup()`, `Cocoon.restoreBackup()` (closed-target rule, compatibility before the swap, `.restoring`/`.before-restore` protocol) + database instance id (`db.instanceId`) | done |
| Aggregates: `aggregate([count(), sum, average])` (+ `minOf`/`maxOf`), one-statement SQLite pushdown with the query index rule, typed overflow error; `groupBy` extension (`key`, `paramKey`, `bucket`, `year`/`month`/`day` at a fixed `utcOffset`, group `.limit`), watches and bulk-writer wait included | done |
| `@Mirrored()` fields: an `f_` column (aggregates, groupBy) with no index; add-and-backfill / drop at open, lock round-trip, DevTools "mirrored (no index)" label; measured storage cost and backfill time at 1M in the README | done |
| Storage format 2: scope-key identity (no stored `path` column), path derived from table + params + id, `_cocoon_meta` format version with crash-safe table-by-table upgrade on open and newer-format refusal (`StorageFormatTooNewException`); measured at 1M in `benchmarks/cocoon_rivals/STORAGE.md` | done |
| Change-log bounding: `pruneChanges` count, `earliestChangeSeq`, `ChangesPrunedException`, `CocoonOptions.changeRetention` (small-batch post-commit enforcement), `BulkWriterOptions(logChanges: false)` | done |
| Added-required-field decisions: `migrate` asks when a new non-nullable field without a constructor default joins an existing collection (backfill stub vs recorded keep-zero vs abort; `--backfill`/`--keep-zero`/`--yes` for scripts), generated `BackfillMigration` runs over existing documents in the open transaction like any migration | done |
| Post-upgrade compaction: `CocoonOptions.compactAfterUpgrade` (default on) runs one `VACUUM` after a storage-format upgrade that left > 20% of the file on the freelist, `onCompactionFailed` reports a failure without failing the open; measured at 1M and on a small file in `benchmarks/cocoon_rivals/STORAGE.md` | done |
| Butterfly CLI shortcuts (`butterfly generate model --cocoon`, `butterfly cocoon migrate`/`build`): scaffold + delegate only, the CLI never imports `cocoon_generator` or reimplements generation/diff | done |
| YAML `cocoon.lock` (replaces `cocoon.lock.json`): written deterministically by `migrate` like `pubspec.lock`, byte-stable, same in-memory shape and lock fingerprint; the builder and `migrate` fall back to the legacy JSON, both present is an error, `--check` flags a pending conversion; `SchemaLock.parse` reads both shapes | done |
| `migrate` documented as a development tool, not a CI step (CI only builds; `--check` is the only migrate form the Butterfly CLI's MCP server exposes, and why) | done |
| pub.dev packaging (both packages at 0.1.0: repository/issue_tracker/topics metadata, install + quick-start README with a runnable generator-free `example/`, CHANGELOG released, `dart pub publish --dry-run` verified) | done |
| Transactions guard: database calls inside a `runTransaction` body (`DocRef`/`CollectionRef`/query/aggregate/getAll/batch commit/BulkWriter/nested `runTransaction`/`backupTo`) throw `TransactionMisuseError` immediately with the operation and a `Fix:` hint — write lock, stale reads, always on; a second `Cocoon` and `watch()` stay allowed inside a body | done |
| `tx.query(...)` (read through the write connection, seeing the transaction's own writes — the fix for the stale-read rule's workaround) | planned |
| Publishing to pub.dev (maintainer: push, then `dart pub publish` in cocoon, then cocoon_generator) | planned |
| Export/import streams (documents through the public API, NDJSON-shaped) | planned |
| Incremental backups (change-log-tailed deltas on top of `backupTo`) | planned |
