# Cocoon design

Cocoon is a typed, disk-backed, Firestore-style local database for Dart and
Flutter. It exists because nothing in Dart today gives all four at once:

| | Typed | On disk (bounded RAM) | Real queries | Firestore-style API |
|---|---|---|---|---|
| sembast | no (`Map`) | no (whole DB in RAM) | yes | yes |
| Hive CE | yes | normal boxes load everything | no | no |
| drift | yes | yes | yes | no (tables + SQL) |
| Isar | yes | yes | yes | close, but stalled |
| ObjectBox | yes | yes | yes | closed core, license limits |

## Storage

- **Engine: SQLite** through `sqlite_async` (one writer + reader isolates, WAL,
  transactions) on top of `package:sqlite3` (FFI). Everything goes through a
  small internal executor interface, so swapping to raw `package:sqlite3` (or
  adding a web executor later) touches one file. Not drift: a library pinning
  drift clashes with apps that already use it, and Cocoon replaces drift's
  codegen and change tracking anyway.
- **One table per collection model**, not one per parent instance and not one
  shared `docs` table. `accounts/a1/txns/t1` and `accounts/a2/txns/t5` both live
  in the `txns` table.

  ```
  txns: id TEXT, account_id TEXT, booked_on INTEGER, amount_minor INTEGER, data BLOB
  ```

  Wins: change notifications scoped per collection, no sparse columns, no
  `collection` column in every index, per-table planner statistics.
- **Path params are typed columns** (`account_id`). Querying one parent is an
  index range scan; skipping the parent filter is a collection-group query for
  free. The full path is also kept, so a subtree (cascade delete, export) is
  `path >= 'accounts/a1/' AND path < 'accounts/a10'` (see `DocPath.descendants`).
- **Document body is a protobuf blob** (`data`), encoded canonically by
  generated code (`WireWriter`): ascending field numbers, no unknown fields, the
  same document always yields the same bytes, so a journal chain can hash it.
- **Indexed fields are copied into real typed columns at write time.** SQLite
  can't look inside the blob; this is better than JSON generated columns anyway:
  real integers, no silent REAL-vs-INTEGER drift, real indexes.
- **Large binaries** (receipts, statements) stay as files; documents store paths.
- **No in-memory copy of the database.** A bounded LRU cache of recently read
  documents gives Hive-like hot reads while RAM stays capped.
- Document ids: time-ordered (UUIDv7/ULID) recommended; `validateDocId` enforces
  path-safe ids.

## Models are the schema

```dart
@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn { ... }
```

- Field identity is the **field number**, pinned per model in the committed
  `cocoon.lock.json`. Reordering fields never matters; names map to numbers.
- The document id is always appended to every index as the final tiebreaker.
- `@Ignore()` excludes a field from storage and from the lock.

### Change handling

| Change | What happens |
|---|---|
| Add a field | Fresh number. Old documents decode the default. |
| Remove a field | Number reserved forever. |
| Reorder fields | Nothing. |
| Rename (same type) | Developer confirms; same number, data untouched. |
| Type change | New number, old reserved, migration file with a typed upgrade stub. |
| Rename + type change | Same as a type change. Numbers are never silently reused. |
| Add/drop index | Applied by diffing on open; no migration file. |

### Who runs what

- **`cocoon migrate`** runs on the developer's machine, interactively. It diffs
  models against the lock (`SchemaDiff`), asks about every ambiguous
  removed/added pair with the best rename candidate preselected
  (`CollectionDiff.candidatesFor`), confirms drops, then writes the new lock
  and, only when data must change, a numbered migration file. Both are
  committed, so renames show up in review.
- **build_runner** (local and CI) only generates codecs, typed fields and
  queries. It never writes the lock or migrations; it **fails** when
  `SchemaDiff.isEmpty` is false, telling the developer to run `cocoon migrate`.
- **On device**, opening the database compares the stored schema version with
  the compiled one, runs pending migration steps in order inside one
  transaction (with a progress callback), and reconciles indexes.

## Queries and pagination

- Typed query builder generated per model; it only offers filter/order
  combinations backed by a declared index (Firestore's "needs an index" error,
  at compile time). Unindexed queries are an explicit opt-in.
- **Keyset pagination only**: `WHERE (k1, ..., id) > (?, ..., ?)` with row-value
  comparison. Sort keys are NOT NULL. Mixed sort directions within one index
  are expanded into the OR form.
- **Cursors are opaque** (`CursorCodec`): base64url of
  `{v, q: queryFingerprint, k: [keys..., id]}`. A cursor from another query is
  rejected (`CursorMismatchException`).

## Realtime

- A `changes` table (`seq` autoincrement, collection, path, op, hlc) is written
  in the same transaction as every write. The same log drives watch
  invalidation, a future sync outbox and auditing.
- Watches are **per query**, invalidated only by changes to their collection
  (and, for document watches, their id), coalesced per transaction, and
  deduplicated by value equality so unchanged results don't rebuild widgets.
- Live paginated lists watch an anchored range (`key >= anchor`), not "first N",
  so page boundaries don't shift under inserts.

## Money (guidance for apps)

Cocoon stores integers exactly: use `int` minor units plus an ISO 4217
currency code, written as zigzag `sint64` and indexed as SQLite `INTEGER`.
`SUM` over integer columns is exact and throws on overflow. Never `TOTAL()` or
`AVG()` for money; never sum across currencies.

## Inspector

A Dart DevTools extension shipped inside the package (`extension/devtools/`),
talking to debug-only service extensions (`ext.cocoon.*`, stripped from release
builds). Material 3, Firestore-console layout: collections -> docs -> fields
with path breadcrumbs. In priority order: browse decoded documents, typed
query runner showing the index used (`EXPLAIN QUERY PLAN`), live change feed,
schema/lock view, then editing behind an explicit unlock.

## Platforms

Native first (Android, iOS, macOS, Linux, Windows). The wire codec relies on
64-bit `int`; web needs a separate integer path and a SQLite WASM + OPFS
executor, so it is deferred.

## Status

| Piece | State |
|---|---|
| Annotations (`Collection`, `Index`, `Ignore`) | done |
| Paths (`CollectionPattern`, `CollectionPath`, `DocPath`) | done |
| Canonical wire codec (`WireWriter`, `WireReader`) | done |
| Cursors (`CursorCodec`, `queryFingerprint`) | done |
| Schema lock + diff + rename resolution | done |
| Storage engine (executor, tables, index columns, transactions) | next |
| Change log + watches | next |
| build_runner generator (`cocoon_generator`) | planned |
| `cocoon migrate` interactive CLI | planned |
| DevTools extension | planned |
