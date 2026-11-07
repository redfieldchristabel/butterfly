## Unreleased

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
