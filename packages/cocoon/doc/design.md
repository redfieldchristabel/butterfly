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
  own transaction.
- **Realtime:** one commit event (the distinct (table, path, op) set) is
  delivered to the watch hub after the cache is updated — never for a
  rolled-back transaction. Doc watches re-read only their exact path; query
  watches only their table (and parent scope); bursts are coalesced;
  emissions identical in canonical bytes are suppressed; `watchFrom(cursor)`
  pins a fixed anchor. Change-log rows are on disk (`_cocoon_changes`) and
  prunable, ready for a sync outbox or audit trail.
- **Large binaries** (receipts, statements) stay as files; documents store
  paths.
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
| DevTools extension | planned |
