## 0.1.0

Cocoon is a typed, disk-backed, Firestore-style local database for Dart and
Flutter, built on SQLite. Your model classes are the schema; documents live
in collections and subcollections inside one SQLite file on disk; queries run
only when an index serves them, exactly like Firestore; and the bounded
hot-document cache keeps RAM flat no matter how large the file grows. This is
the first published release. Everything below is in it.

- **Existing databases upgrade themselves on open** — and every file got
  ~18% smaller at 1M transactions. The internal `path` column (and its
  unique index) is gone from collection tables: a document is identified by
  its path params + id, and the full path you see in refs, snapshots and
  the change log is derived from it. The public API is unchanged. Files
  written by older Cocoon versions are rebuilt table by table inside the
  first open that touches them (crash-safe — a failure leaves the old file
  and the next open finishes; progress reports through the existing
  `onMigrationProgress`), a file written by a NEWER version refuses to open
  with a typed `StorageFormatTooNewException`, and `restoreBackup` accepts
  older-format backups (they migrate at the next open). Measured on a 1M
  file: 409 MB → 320 MB compacted (390 → 305 MiB), the one-time migration
  takes ~5-9 s and keeps every document and change-log row.
- **Bound the change log** (it exists for sync consumers; watches don't
  read it). `db.pruneChanges(upToSeq:)` now returns how many rows it
  deleted; new `db.earliestChangeSeq()` is the oldest seq still readable;
  and a consumer that reads from a pruned watermark gets a typed
  `ChangesPrunedException` instead of a silent gap — resync fully, like
  Firestore's "resume token expired". Or let the engine do it:
  `CocoonOptions(changeRetention: ChangeRetention(maxChanges: 50000,
  maxAge: Duration(days: 30)))` keeps the newest N rows and/or everything
  newer than the duration, deleted in small batches after commits (never
  inside a user transaction, never stalling a write). The default keeps
  everything, as before. `lastChangeSeq()` still never goes backwards.
- **`bulkWriter(logChanges: false)`**: importing a million documents no
  longer writes a million change-log rows (~52 MB of the file at 1M).
  In-process watches still fire per chunk; sync consumers must resync fully
  afterwards, because the log has a hole where the load ran.
- Batch `update` now actually persists: an `update` of a document that
  already existed on disk was written with a shifted bind order and
  silently matched nothing — the new value only ever lived in the
  hot-document cache. Caught and fixed by the scope-key rewrite; reads from
  a fresh instance now see the update.
- Butterfly CLI shortcuts (optional): `butterfly generate model <Name>
  --cocoon [--collection <path>]` scaffolds a starter `@Collection` model,
  and `butterfly cocoon migrate [args...]` / `butterfly cocoon build` run
  your project's own `dart run cocoon_generator:migrate` and `dart run
  build_runner build -d` for you (args and exit codes pass through
  untouched, so the interactive rename/drop menus work). The CLI never
  generates, diffs or installs anything — your pinned `cocoon_generator`
  stays the only authority — and Cocoon works exactly as before without it.
- `@Mirrored()`: totals over fields you don't filter on. Annotating a field
  `@Mirrored()` copies it into its own typed column — exactly like an index
  field's column — without creating an index, so `sum`/`average`/`minOf`/
  `maxOf` and `groupBy` read it while `where`/`orderBy` on it still follow
  the index rule (`MissingIndexException` suggests the `Index([...])`, or
  `.allowFullScan()`). The annotation is for fields you aggregate but never
  filter or sort on (an amount, a category): it no longer costs an index you
  don't use — measured ~4.2 bytes per row for the column vs ~27 for column +
  index at 1M transactions. A field that is both mirrored and indexed is
  just indexed. Adding the annotation to an existing collection adds and
  backfills the column on the next open (one pass, in the open transaction,
  crash-safe; ~12 s at 1M) and removing it drops the column; `bulkWriter()`
  fills mirrored columns too; the DevTools schema view labels them
  "mirrored (no index)".

- Aggregates: your totals no longer decode documents. `query.aggregate([count(),
  sum(Txn$.amountMinor), average(Txn$.rate)])` computes in one SQLite
  statement over the mirrored columns — Firestore's aggregate API with
  Firestore's semantics (empty sum = 0, average always a `double?`, nulls
  skipped; integer sums exact, overflowing past ±2^63 throws a typed
  `AggregateOverflowException` instead of wrapping), plus Cocoon's `minOf`/
  `maxOf`. The filters follow the same index rule as `get()` (the same
  `MissingIndexException` with the same suggested `Index([...])`, the same
  `.allowFullScan()`, the same wait behind a running `bulkWriter()`), an
  `orderBy` + `limit` aggregates the first N documents in that order, and
  `query.count()` is now exactly `aggregate([count()])`. Aggregate fields
  must be mirrored into a column (an `Index([...])` member or a
  `@Mirrored()` field) — anything else throws an `UnmirroredFieldException`
  naming the declaration that would mirror it. A Cocoon extension on top:
  `query.groupBy([key(Txn$.currency),
  bucket(Txn$.bookedOn, width: 100), month(Txn$.bookedAt, utcOffset:
  Duration(hours: 8))]).aggregate([...]).get()` returns one
  `AggregateGroup` per key combination, ordered by the keys ascending, each
  carrying its typed keys plus the same aggregates and `getMin`/`getMax`;
  keys can be a field, a path param (one group per parent on a collection
  group), a fixed-width numeric band, or a calendar year/month/day —
  calendar buckets need a fixed `utcOffset` (no IANA zones, no DST; the
  dartdoc explains what DST zones should do instead). Both kinds support
  `watch()` with the query watch's invalidation and dedup. At 1M
  transactions the groupBy path cut the rivals year report from 1,430 ms to
  376 ms — drift's own SQL `GROUP BY` runs 358 ms, so the 3.6x gap is
  closed — and one account's monthly totals from 185 ms (9,874 documents
  read) to 35 ms (12 group rows)
  (`benchmarks/cocoon_rivals/AGGREGATES.md`).

- Backups and restores: `db.backupTo(path)` writes a consistent, compacted
  copy of the whole database while the app keeps reading and writing — one
  read snapshot (SQLite's `VACUUM INTO`), landed atomically as one file
  (0.8-1.0 s for a 388 MB, 1M-transaction database); an existing file
  refuses unless `overwrite: true`. `Cocoon.inspectBackup(path)` verifies a
  backup (Cocoon marker + `PRAGMA integrity_check`) and reads its metadata,
  with typed errors for "not a Cocoon backup", "damaged" and "written by a
  newer app". `Cocoon.restoreBackup(backup:, path:, collections:)` swaps a
  CLOSED database file for a verified backup: schema compatibility is
  checked before the current file is touched, the replaced database is kept
  as `<path>.before-restore`, and a failure at any point leaves the original
  database usable — then open as usual. The engine owns these two
  primitives and the file protocol; the app owns the policy (when, where,
  compression, encryption, files outside the database). Restores re-roll the
  database's new `instanceId`, so sync consumers must compare it against the
  one saved next to their change-log watermark before trusting it (a
  restored database's change log is the backup's — a saved watermark can be
  ahead of the data). See the README's "Backup and restore".
- Bulk loads: `db.bulkWriter()` — a Firestore-style BulkWriter for
  import-shaped work too big for one transaction. Queue
  `set`/`update`/`delete` synchronously; the writer commits every 10,000
  rows (tunable `chunkSize`) as one write transaction — atomic per chunk,
  never as a whole — and `await bulk.close()` flushes the rest, rebuilds
  the deferred indexes and resolves when everything is durable. While a
  load runs it drops the touched tables' secondary indexes (when the table
  is empty or the load outgrows it) and rebuilds them at close; a query
  needing one of them waits until then, `get()` by id never waits, and a
  crash mid-load is recovered on the next open. Importing 1,000,000
  transactions takes ~13 s at `Durability.full` (was 103 s through
  `db.batch()` per 1,000 rows on the same dataset — ~8x faster, within ~1.4x of raw SQLite's
  own deferred-index ceiling). Not atomic as a whole, atomic per chunk;
  `db.batch()` stays the tool when everything must commit or roll back as
  one. See the README's "Bulk loads" section.
- Bulk writes: `db.batch()` queues `set`/`update`/`delete` synchronously and
  `await batch.commit()` runs them in call order inside one write
  transaction — consecutive same-SQL operations batch into one round trip
  per ~2,000 documents, every change-log row lands in one batch, the cache
  is updated once and watches receive exactly one commit event. Semantics
  per operation are the standalone ones (`update` fails the whole batch
  when the document is missing; any failure rolls everything back), and a
  failed batch leaves no cache or watch effects. This is the path for
  import-shaped work; it mirrors drift's `db.batch`.
- Writes are much faster at scale. Document writes inside
  `runTransaction` now buffer and flush as batched statements (before the
  commit, before any read or delete in the same transaction, every 2,000
  rows), each collection's write SQL is built once instead of per document,
  and a write caches the document's bytes so the first read decodes them
  once. Measured on the rivals benchmark: the 100k import dropped from
  7.9 s to ~2.9 s (was 2.9x drift's time, now on par), and the 1M import
  from ~119 s to ~37 s. New `CocoonOptions` knobs back this:
  `pageCacheMiB` (a 64 MiB SQLite page cache by default, was 2 MB) and
  `tempStoreInMemory` (temp B-trees in RAM), plus sqlite_async's dev-mode
  query timeline tracing is now off (it cost ~5 s of a 100k import and
  nothing in Cocoon reads it).
- A rivals benchmark, `benchmarks/cocoon_rivals`, now measures Cocoon
  against drift, Isar, ObjectBox, Hive CE and sembast — plus Cocoon itself
  at `Durability.normal` — on the same finance-shaped data at up to
  1,000,000 transactions, every rival's read results diffed against
  Cocoon's before any timing counts. At 1M txns Cocoon's indexed reads
  stay flat where the store-everything engines scan (latest-50 0.74 ms p50
  vs 641 ms Hive and 769 ms sembast; the paged all-accounts month range
  320 ms vs 2,476 ms for drift's offset paging and 99 s for sembast) and
  its memory share stays at the bare-harness floor where Hive and sembast
  hold ~2.2 GB; the losses stay in view: bulk import 1.3-15x slower than
  the six rivals, the year report 3.6x behind drift's SQL aggregation,
  restore 11x behind Hive, gets by id 6-20x behind the in-RAM engines,
  single writes at `Durability.full` equal to drift's fsynced default
  (`Durability.normal`: 402 µs p50, 7.3x faster than drift's default).
  Tables and per-workload verdicts: `benchmarks/cocoon_rivals/RESULTS.md`.
- The Cocoon benchmark now measures memory without the harness's dataset in
  RAM: only `import` builds the typed dataset, other operations take their
  ids and values from the database itself, and a `baseline` run reports the
  bare-harness floor. Re-measured numbers (`packages/cocoon_bench/RESULTS.md`)
  show Cocoon's own footprint is flat — indistinguishable from the bare
  harness after open, +39 MB after reads at every size from 10k to 300k
  txns, cold open ~80 ms flat — while sembast grows to +598 MB over the
  floor at open and +704 MB after reads at 300k. New tuning measurements
  next to the defaults: single writes with `Durability.normal` (p50 2,032 →
  483 us at 100k) and with `keepChanges: false` (~11%), and gets by id with
  `cacheSize` 2000 vs 20000, cold then warm in one process (warm
  1,000-doc working set: 113 → 2 ms; RSS unchanged — the cache charges RAM
  only for documents actually read). The README and the docs site's
  Internals page carry short Benchmarks and Tuning sections from these
  numbers.
- `Map<String, V>` and `Map<int, V>` fields, for every supported non-Map
  value type (primitives, `DateTime`, `Uint8List`, enums, `List<...>`,
  `@Embedded` classes; the map itself nullable or not). Stored like
  protobuf's map type — one nested message per entry, key at field 1, value
  at field 2 — with entries written sorted by key, so equal maps always
  encode to equal bytes. Missing on decode: constructor default, else `null`
  when nullable, else an empty map. Maps cannot be indexed; naming one in
  `Index([...])` is a build error.
- `packages/cocoon_bench`, an honest benchmark of Cocoon against sembast on
  finance-shaped data (20 accounts sharing 10k/100k/300k txns over five
  years, with indexes, embedded splits and string maps): bulk import, cold
  open, RSS and
  peak memory, latest-50 reads, monthly totals, gets by id and single-write
  latency, each in a fresh process. Numbers and the plain-words verdict —
  including where Cocoon loses — live in `packages/cocoon_bench/RESULTS.md`.

- A Cocoon tab in Dart DevTools for running debug apps: browse collections
  and documents with a path breadcrumb, drill into subcollections, and read
  decoded documents (dates as UTC ISO-8601 strings, enums by name, binary
  fields as `<N bytes>` placeholders, embedded classes and lists as nested
  JSON).
- A query runner that runs typed queries read-only and explains the plan in
  plain words: which index served the query ("Used index cx_txn_ab12cd34"),
  when it read every row ("Full scan: add `Index([...])`"), and the exact
  `Index([...])` to declare when the index rule refused the query.
- A live change feed of every committed write, one row per touched document,
  filterable by collection and pausable, streamed from the app as
  `cocoon:changes` DevTools events.
- A schema view with the live tables, columns, indexes and row counts, plus
  the lock's pinned field numbers and reserved numbers when the app passes
  `schemaLock:` to `Cocoon.open`.
- Zero setup: the inspector registers its `ext.cocoon.*` service extensions
  in debug and profile builds only; product builds are untouched. The
  extension UI is a separate package (`cocoon_devtools`, not an app
  dependency) whose prebuilt output ships inside the cocoon package under
  `extension/devtools/`.
- Docs: new "DevTools Inspector" page on the docs site and a README section.

- Documentation: Cocoon now has its own tab on the Butterfly docs site
  ([docs/libraries/cocoon/](../../../docs/libraries/cocoon/)) — overview and
  why, models and code generation, collections and documents, queries and
  indexes, realtime, schema migrations and internals — plus installation
  steps in the site's Installation page. `doc/design.md` is now the short
  decision record + Status table linking to those pages.

- Schema migrations, end to end. `dart run cocoon_generator:migrate` asks
  only what a human must answer (renames, drops), updates the committed
  `cocoon.lock.json` and, when stored data must change, writes a numbered
  migration file with one conversion stub per type change. Implement the
  stubs, commit both, and pass `schemaVersion: cocoonSchemaVersion` and
  `migrations: cocoonMigrations` to `Cocoon.open`: pending migrations run
  once, in order, inside the open transaction — documents rewritten in
  batches of 500 with a progress callback, one change-log row per rewritten
  document, migrated columns and indexes rebuilt from the rewritten bytes.
  A database written by a newer app refuses to open
  (`SchemaTooNewException`); a failing conversion rolls the whole open back.
- The migration building blocks are public: `CocoonMigration` (one version
  step), `FieldMigration` (+ the type-checked `FieldMigration.typed<S, T>`
  wrapper the generated code uses) and `MigrationWireType`, the exact wire
  encoding of both sides of a rewrite. `rewriteField` is the pure wire-level
  rewrite they run on: absent old fields are skipped without calling the
  conversion, `null` conversions drop the value, and everything else is
  re-serialized byte-for-byte in canonical order.
- Code generation: annotate plain classes with `@Collection` (and nested
  value classes with `@Embedded`) and `cocoon_generator` writes the adapter,
  typed query handles (`Txn$.bookedOn`) and the canonical codec. Field numbers
  come from the committed `cocoon.lock.json`, so reordering fields never
  matters, and the build stops with a clear message when the models and the
  lock disagree instead of silently writing data under the wrong numbers.
- Documents written before a field existed still load: the field takes the
  constructor default, `null`, or its zero value.
- `CollectionAdapter` has a const constructor, so adapters can be `const`.

- Realtime watches. `docRef.watch()` emits the current value on listen and
  again only when a commit changes that exact document — a rewrite that
  encodes to the same canonical bytes never emits, and a delete emits
  `null`. `query.watch()` emits pages, re-runs only for commits in the
  query's collection (and parent scope, for subcollections), coalesces
  bursts of commits into at most one more re-run, and skips pages identical
  to the previous one — so UIs rebuild only when something they show
  changed. Cancelling a subscription unregisters the watcher; closing the
  database completes every watch stream.
- `query.watchFrom(cursor)`: a live window anchored at a fixed cursor. Rows
  inserted before the anchor never shift it — how live paginated lists keep
  their pages stable while new data arrives.
- A durable change log. Every commit appends one row per touched document
  (`Change`: seq, collection, path, op, at) in the same transaction as the
  write, including one row per cascaded delete. Read it with
  `db.changesSince(seq)`, track the head with `db.lastChangeSeq()`, and trim
  consumed rows with `db.pruneChanges(upToSeq: ...)` — ready for a future
  sync outbox or audit trail. Opt out with `CocoonOptions(keepChanges:
  false)` when only in-process watches are needed; notifications are
  unaffected.
- The storage engine is here: open a Cocoon database on disk, write and read
  typed documents in collections and subcollections, delete a document with
  its whole subtree, and run transactions — all on SQLite with bounded RAM
  (`Cocoon.open`, `CocoonOptions`, `DocRef`, `CollectionRef`,
  `CollectionGroupRef`, `CocoonTransaction`).
- Collections are wired to SQLite with a `CollectionAdapter<T>` (what the
  code generator will emit later): typed `FieldColumn` handles copied into
  real columns at write time, `ParamColumn` handles for path params, and
  `IndexDef` index declarations. Column types cover `int`, `double`, `bool`,
  `String`, `DateTime` (UTC microseconds) and enums.
- Queries are Firestore-strict: filters and sorts only run when an index
  serves them, and the failure names the `Index([...])` to declare
  (`MissingIndexException`). `.allowFullScan()` opts out. Filter ops:
  equality, inequality, comparisons, `whereIn` (≤ 30), `isNull`/`isNotNull`.
- Keyset pagination over `QueryPage`: opaque cursors (`startAfter`) that are
  rejected when reused on another query, page-size changes allowed,
  `nextCursor` null on the last page. `count()` on any query, under the same
  index rule.
- Reopening the database reconciles the schema by itself: creates missing
  tables and indexes, adds new field columns and backfills them from stored
  documents in batches of 500, drops removed columns and indexes, and does
  no DDL at all when the stored shape already matches.
- Transactions read their own writes and roll back fully on error — the
  hot-document cache only updates after a successful commit.
- Document ids are time-ordered UUIDv7 (`newDocId()`): monotonic within a
  millisecond, lowercase and hyphenated.
- A bounded LRU cache (default 2000 documents, `cacheSize: 0` disables)
  keeps hot reads out of SQLite; every write and delete keeps it consistent.
  One `Cocoon` instance must own its database file.

## 0.0.1

- Initial scaffold: collection annotations, typed collection/document paths,
  a canonical protobuf wire codec, opaque keyset cursors, and the schema lock
  diff that drives interactive migrations. No storage engine yet.
