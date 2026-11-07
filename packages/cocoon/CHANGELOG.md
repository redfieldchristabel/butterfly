## Unreleased

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
