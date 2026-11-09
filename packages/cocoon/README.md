# Cocoon

A typed, disk-backed, Firestore-style local database for Dart and Flutter,
built on SQLite.

- **Firestore-style API**: collections, documents and subcollections
  (`accounts/{accountId}/txns`).
- **Typed**: your model class is the schema. No `Map<String, Object?>`.
- **On disk**: data never loads into RAM wholesale; only a bounded cache of
  hot documents stays in memory.
- **Real queries**: indexed filters and sorts with keyset pagination, like
  Firestore: a query runs only when an index serves it.
- **No hand-written migrations**: field numbers are pinned by name in a
  committed `cocoon.lock.json`, so reordering or adding fields needs nothing,
  reopening the database reconciles tables, columns and indexes on its own,
  and a type change needs exactly one conversion line that the on-device
  runner applies for you.

> Status: the storage engine, the change log, realtime watches, the
> `cocoon_generator` codegen (with the interactive `migrate` command that
> maintains `cocoon.lock.json`), the on-device migration runner and the
> DevTools inspector are in. See [doc/design.md](doc/design.md).

## The 30-second version

```dart
final db = await Cocoon.open(file, collections: [accounts, txns, splits]);

final a1 = db.collection(accounts).doc('a1'); // root: CollectionRef<Account>
await a1.set(const Account(name: 'Acme', active: true)); // upsert

final txRef = await a1.collection(txns).add(txn); // id = UUIDv7
final snap = await txRef.get(); // DocSnapshot<Txn>? (null when missing)

await a1.delete(); // deletes a1 AND its whole subtree
```

## Models and code generation

Annotate plain Dart classes and let `cocoon_generator` write the adapter,
the typed query handles and the canonical codec. Field numbers come from the
committed `cocoon.lock.json`, never from field order.

```yaml
# pubspec.yaml
dependencies:
  cocoon: ^0.0.1
dev_dependencies:
  build_runner: ^2.4.13
  cocoon_generator: ^0.0.1
```

```yaml
# build.yaml: the generator reads the lock from the package root
targets:
  $default:
    sources:
      - lib/**
      - cocoon.lock.json
      - $package$
```

```dart
import 'package:cocoon/cocoon.dart';

part 'models.cocoon.dart';

@Embedded()
class Address {
  const Address({required this.city, this.line2});
  final String city;
  final String? line2;
}

@Collection('accounts', indexes: [Index(['name'])])
class Account {
  const Account({required this.name, this.tags = const [], this.address});
  final String name;
  final List<String> tags;
  final Address? address;
}

@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn {
  const Txn({required this.bookedOn, required this.amountMinor, this.memo});
  final int bookedOn; // yyyymmdd
  final int amountMinor; // minor units
  final String? memo;
}
```

`dart run build_runner build -d` then generates, per model:

- an adapter instance named after the last collection id: `accounts`,
  `txns` (classes `AccountCollection`, `TxnCollection`);
- typed handles on a `$` holder for every indexed field and path param:
  `Txn$.bookedOn`, `Txn$.accountId`;
- `const cocoonSchemaVersion` in `lib/cocoon_schema.g.dart`.

```dart
final db = await Cocoon.open(file, collections: [accounts, txns]);
final recent = await db.collection(accounts).doc('a1').collection(txns)
    .orderBy(Txn$.bookedOn, descending: true)
    .limit(50)
    .get();
```

Rules the generator enforces (build errors say exactly what to fix):

- One generative constructor whose parameters are named like the stored
  fields (named or positional). Stored fields are final instance fields not
  marked `@Ignore()`; getters are not stored. No generic models.
- Supported types: `int`, `double`, `bool`, `String`, `DateTime` (UTC
  microseconds), `Uint8List`, enums (stored by name), `List<T>` of those, and
  `@Embedded()` classes. Any of them nullable. Also `Map<K, V>` where `K` is
  `String` or `int` and `V` is any supported non-Map type — values may not be
  nullable or Maps; encode the absence of a value by omitting its entry. A
  map is stored like protobuf's map type: one nested message per entry with
  the key at field 1 and the value at field 2, entries written sorted by
  key, so equal maps always encode to equal bytes.
- A field missing from an older document decodes to the constructor default,
  else `null` when nullable, else the zero value (`0`, `''`, `false`, empty
  list, empty map, epoch UTC, first enum value).
- Maps cannot be indexed: an `Index([...])` naming a map field is a build
  error ("lists, maps and embedded classes live inside the document blob").
- **Subcollection indexes start with the path params** (`accountId` above):
  a scoped query always filters them, so an index without them can't serve
  it. An index without params serves collection-group queries.
- The build fails when the models and `cocoon.lock.json` disagree:
  `Cocoon schema changed for <Model>: run "dart run cocoon_generator:migrate"`.
  The builder never writes the lock; the migrate command does — see the next
  section.

## Schema migrations

Two tools compare the models against the committed `cocoon.lock.json`. The
build only *fails* when they disagree; `migrate` *fixes* the disagreement:

```sh
dart run cocoon_generator:migrate
```

It asks only what a human must answer. For every removed field with new
fields alongside it, a numbered menu offers the rename candidates — best
first, Enter accepts the preselected one — and a final drop option; fields
without candidates and removed collections ask a plain `y/N`. Everything
else is decided without asking: added fields get fresh numbers, reorders
and index changes change nothing, and a type change always moves the field
to a fresh number with a conversion stub. The command writes the updated
lock and, only when stored data must change, a numbered migration file:

```dart
// lib/cocoon_migrations/m0003_txn_currency_to_currency_code.dart
// Txn.currency: String (#3) -> currencyCode: int (#10)
int upgradeTxnCurrency(String old) => switch (old) {
  'MYR' => 458,
  'SGD' => 702,
  _ => 0,
};
```

Implement the stubs — the build fails while any `UnimplementedError`
remains — and commit the lock and the migration file together, so renames
and conversions show up in review. Pass both artifacts to the engine:

```dart
final db = await Cocoon.open(
  file,
  collections: [accounts, txns],
  schemaVersion: cocoonSchemaVersion, // from lib/cocoon_schema.g.dart
  migrations: cocoonMigrations, // from lib/cocoon_migrations/migrations.dart
  onMigrationProgress: (done, total) => print('$done/$total'),
);
```

On the device, opening compares the schema version stored in `_cocoon_meta`
with `cocoonSchemaVersion`. A fresh database just stores the version. An
older database runs every pending migration once, in order, inside ONE
transaction: documents are rewritten at the wire level in batches of 500,
one change-log row per rewritten document is appended, the migrated tables'
columns and indexes are rebuilt from the rewritten bytes, and only then is
the new version stored. A database written by a NEWER app version refuses
to open (`SchemaTooNewException`); any failure — a throwing conversion
included — rolls the whole open back.

Scripts and pre-commit hooks drive the command without a terminal:
`--rename Model.old=new`, `--drop Model.field`, `--drop-collection Model`
(drops are never implied by `--yes`), `--check` (exit 1 when the lock would
change, no writes), and a missing decision on non-interactive stdin exits 2
listing the flags that would resolve it. See the cocoon_generator README.

## Writing an adapter by hand

One adapter per collection model. It declares the table shape, the indexed
fields copied into typed columns, and the canonical wire codec. This is the
class the code generator emits from `@Collection` models; you only need this
when you can't use codegen. The examples below use hand-written handles
(`txnBookedOn`); generated code exposes the same handles as `Txn$.bookedOn`.

```dart
enum TxnStatus { pending, posted, failed }

class Txn {
  const Txn({
    required this.bookedOn,
    required this.amountMinor,
    required this.currency,
    required this.status,
    required this.createdAt,
    this.memo,
  });

  final int bookedOn; // yyyymmdd
  final int amountMinor; // minor units; may be negative
  final String currency;
  final TxnStatus status;
  final DateTime createdAt;
  final String? memo;
}

// Typed handles, one per indexed field. Used for queries and for the
// columns the engine mirrors into SQLite.
final txnBookedOn = FieldColumn.integer<Txn, int>(
  'bookedOn',
  read: (t) => t.bookedOn,
);
final txnAmountMinor = FieldColumn.integer<Txn, int>(
  'amountMinor',
  read: (t) => t.amountMinor,
);
final txnCurrency = FieldColumn.text<Txn, String>(
  'currency',
  read: (t) => t.currency,
);
final txnStatus = FieldColumn.enumerated<Txn, TxnStatus>(
  'status',
  read: (t) => t.status,
  values: TxnStatus.values,
);
final txnCreatedAt = FieldColumn.dateTime<Txn, DateTime>(
  'createdAt',
  read: (t) => t.createdAt,
);
final txnMemo = FieldColumn.text<Txn, String?>(
  'memo',
  read: (t) => t.memo,
  nullable: true,
);
final txnAccountId = ParamColumn(txns.pattern, 'accountId');

final class TxnAdapter extends CollectionAdapter<Txn> {
  @override
  String get model => 'Txn';

  @override
  final pattern = CollectionPattern.parse('accounts/{accountId}/txns');

  @override
  List<FieldColumn<Txn, Object?>> get columns => [
    txnBookedOn,
    txnAmountMinor,
    txnCurrency,
    txnStatus,
    txnCreatedAt,
    txnMemo,
  ];

  @override
  List<IndexDef> get indexes => [
    // '-' prefixes a descending part, like @Index(['accountId', '-bookedOn']).
    IndexDef.fromFields(['accountId', '-bookedOn']),
    IndexDef.fromFields(['status', 'bookedOn']),
  ];

  @override
  Uint8List encode(Txn value) {
    final writer = WireWriter();
    writer.writeInt64(1, value.bookedOn);
    writer.writeSint64(2, value.amountMinor); // zigzag: safe for negatives
    writer.writeString(3, value.currency);
    writer.writeString(4, value.status.name);
    writer.writeInt64(5, value.createdAt.toUtc().microsecondsSinceEpoch);
    final memo = value.memo;
    if (memo != null) writer.writeString(6, memo); // skip nulls
    return writer.toBytes();
  }

  @override
  Txn decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var bookedOn = 0;
    var amountMinor = 0;
    var currency = '';
    var status = TxnStatus.pending;
    var createdAt = DateTime.utc(1970);
    String? memo;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1: bookedOn = reader.readInt64();
        case 2: amountMinor = reader.readSint64();
        case 3: currency = reader.readString();
        case 4: status = TxnStatus.values.byName(reader.readString());
        case 5:
          createdAt = DateTime.fromMicrosecondsSinceEpoch(
            reader.readInt64(),
            isUtc: true,
          );
        case 6: memo = reader.readString();
        default: reader.skip(tag.type); // unknown fields from the future
      }
    }
    return Txn(
      bookedOn: bookedOn,
      amountMinor: amountMinor,
      currency: currency,
      status: status,
      createdAt: createdAt,
      memo: memo,
    );
  }
}

final txns = TxnAdapter();
```

Field numbers are the identity of a field on disk (they will be pinned in
`cocoon.lock.json`); write them in ascending order. Ready-made column
factories: `FieldColumn.integer`, `real`, `boolean` (stored 0/1), `text`,
`dateTime` (UTC microseconds), `enumerated` (name as text) and `blob`.

## Documents

```dart
final a1 = db.collection(accounts).doc('a1');
await a1.set(account); // upsert by id
final snap = await a1.get(); // DocSnapshot<Account>? — .ref, .id, .data
await a1.delete(); // removes a1 and every document below it

final txRef = await a1.collection(txns).add(txn); // DocRef<Txn>, fresh id
await txRef.set(txn.copyWith(status: TxnStatus.posted));
```

Subcollections are checked at the type level of the pattern:
`docRef.collection(adapter)` throws unless `adapter.pattern.parent` is the
document's collection, so `a1.collection(splits)` cannot be built under the
wrong parent. Deleting a document cascades to its whole subtree — and
prefix-siblings are safe: deleting `accounts/a1` never touches
`accounts/a10`.

## Queries

Filters and sorts are built from the typed handles. Every query needs an
index that serves it (the implicit `(params..., id)` index counts) —
otherwise `get()` throws a `MissingIndexException` whose message spells the
`Index([...])` to declare. `.allowFullScan()` opts out explicitly.

```dart
final q = a1.collection(txns)
    .where(txnBookedOn.isGreaterThanOrEqualTo(20260101))
    .orderBy(txnBookedOn, descending: true)
    .limit(50);
final page = await q.get(); // QueryPage<Txn>: docs, nextCursor (null on last page)
final next = page.nextCursor == null
    ? null
    : await q.startAfter(page.nextCursor!).get();

final count = await q.count(); // SELECT count(*), same index rule
```

Filter ops: `isEqualTo`, `isNotEqualTo`, `isLessThan`, `isLessThanOrEqualTo`,
`isGreaterThan`, `isGreaterThanOrEqualTo`, `whereIn` (at most 30 values) and
`isNull`/`isNotNull` on nullable columns. Sort keys are never null: ordering
by a nullable column throws. The document id is always appended as the final
tiebreaker.

A subcollection ref scopes by its parent automatically; `a1`'s txns never
include `a2`'s. Dropping the parent filter gives a collection-group query,
which can filter parent params explicitly:

```dart
final postedAcrossAccounts = await db
    .collectionGroup(txns)
    .where(txnStatus.isEqualTo(TxnStatus.posted))
    .orderBy(txnBookedOn, descending: true)
    .get();

final a2Txns = await db
    .collectionGroup(txns)
    .where(txnAccountId.isEqualTo('a2'))
    .get();
```

Cursors are opaque and query-bound: a cursor from another query (or another
parent) is rejected with a `CursorMismatchException`. The page size is not
part of a cursor's identity, so you may fetch a wide page after a narrow
one.

## Transactions

```dart
await db.runTransaction((tx) async {
  final snap = await tx.get(txRef);
  await tx.set(txRef, snap!.data.copyWith(status: TxnStatus.posted));
  await tx.add(a1.collection(txns), otherTxn);
});
```

Reads inside the transaction see its own writes; an exception rolls back
everything. `set`/`add`/`delete` outside a transaction each run in their own
transaction.

## Bulk writes: WriteBatch

For import-shaped work — hundreds to thousands of documents in one go —
queue the writes synchronously and commit them as one transaction. This is
Cocoon's bulk-write path, the counterpart of drift's `db.batch`:

```dart
final batch = db.batch();
batch.set(a1.collection(txns).doc('t1'), txn); // upsert
batch.update(a1.collection(txns).doc('t2'), edited); // must already exist
batch.delete(staleRef); // removes the document and its subtree
await batch.commit();
```

`set`, `update` and `delete` only validate and queue — they are synchronous
and touch nothing on disk. `commit()` runs every queued operation, in call
order, inside ONE write transaction: consecutive same-SQL operations group
into one batched statement (one round trip per ~2,000 documents instead of
one per document), every touched document's change-log row lands in one
batch, the hot-document cache is updated once after the commit, and the
watches receive exactly one commit event. Semantics per operation are the
standalone ones: `update` fails the whole batch when the document is
missing — a `set` earlier in the same batch satisfies a later `update` of
the same document, and a `delete` in between fails it. Any failure rolls
everything back: no rows, no cache updates, no watch event. A batch is
single-use (`commit` twice throws); committing an empty batch is a no-op.

Document writes inside `runTransaction` buffer the same way: they flush as
batched statements before the commit (and before any read or delete in the
same transaction, and every 2,000 queued rows), so large transactions cost
batched round trips too, with no change in semantics.

## Bulk loads: BulkWriter

For bulk-shaped work too big for one transaction — restoring a backup, a
first sync, loading a dataset — `db.bulkWriter()` queues
`set`/`update`/`delete` synchronously and commits them in chunks, the way
Firestore's server SDKs do it:

```dart
final bulk = db.bulkWriter(); // 10,000 rows per chunk; indexes deferred
for (final t in txns) {
  bulk.set(txnsOf(t.accountId).doc(t.id), t); // synchronous, buffered
}
await bulk.close(); // flushes, finishes the indexes, resolves when durable
```

- **Not atomic as a whole, atomic per chunk** — the same rule Firestore
  documents loudly: every 10,000 rows (tune with `BulkWriterOptions
  (chunkSize:)`) commit as one write transaction, so a crash leaves a prefix
  of committed chunks, never a half chunk, and each chunk honours the
  database's `Durability`. Use `db.batch()` instead when the whole queue
  must commit or roll back as one.
- `flush()` commits the operations queued so far and resolves (later
  operations keep buffering); `close()` flushes the rest, finishes the
  indexes and resolves. Using the writer after `close` — or closing it
  twice — throws. A failed chunk (a failed `update`, a SQL error) rolls
  back whole, the buffered operations after it are discarded, and the error
  surfaces from `flush()`/`close()`.
- Per-operation semantics are the standalone ones, as for `WriteBatch`:
  `set` upserts, `update` replaces an existing document and fails its chunk
  when the document is missing — a `set` queued earlier, in the same chunk
  or an earlier committed one, satisfies it — and `delete` removes the
  document and its whole subtree. Operations commit in call order; the
  last write of a document wins inside its chunk.
- **Deferred secondary indexes** (the default): when the load defers a
  table's indexes — the table is empty, or the writer has buffered more
  rows than the table already holds — the writer drops the table's
  secondary indexes during the load and rebuilds them in `close()`'s one
  write transaction. The scope index and the unique `path` constraint are
  never dropped. A query whose plan needs a deferred index waits until the
  writer closes, then runs; `get()` by id is unaffected. Watches fire once
  per chunk commit; a query watch whose plan needs a deferred index re-runs
  only after the writer closes.
- **Crash recovery**: while the indexes are deferred they are recorded in
  the internal `_cocoon_bulk` table, in the same transaction that drops
  them. A database opened with rows left there (a crash mid-load) rebuilds
  those indexes before the app sees it.
- The buffer holds every queued operation until its chunk commits. For a
  load that streams faster than it commits, call `flush()` every few
  thousand operations to bound the memory.

Measured on the rivals dataset at 1M transactions, `Durability.full`: the
default `bulkWriter()` imports in ~13 s where `db.batch()` per 1,000 rows
takes 103 s on the same dataset and indexes — within ~1.4x of raw SQLite's own 9.5 s deferred-index
ceiling (`benchmarks/cocoon_rivals/CEILING.md`). The chunk-size curve and
each lever's measurement: `benchmarks/cocoon_rivals/IMPORT.md`.

## Realtime: watches and the change log

Every committed write appends one row per touched document to an internal
change log, in the same transaction as the write. The log feeds the watches
below, and the same rows can later drive sync and audits.

```dart
// Watch one document. Emits the current value on listen (null when the
// document does not exist), then re-reads only when a commit touched this
// exact path. An emission whose canonical bytes equal the previous one is
// skipped, so an identical rewrite never fires and models need no ==.
final docSub = txRef.watch().listen((snap) {
  // snap is DocSnapshot<Txn>? — null after a delete.
});

// Watch a query. Emits the current page on listen, then re-runs only when a
// commit touched the query's collection (and, for subcollection queries, a
// path inside the parent scope). Commits landing while a re-run is in
// flight are coalesced into at most one more re-run, and a page whose
// paths + bytes equal the previous page is not emitted.
final pageSub = a1.collection(txns)
    .orderBy(txnBookedOn, descending: true)
    .limit(20)
    .watch()
    .listen((page) { ... });

// Anchored live range: the rows after `cursor`, up to the limit, with the
// anchor fixed — rows inserted before it never shift the window. This is
// how live paginated lists avoid shifting pages.
final windowSub = a1.collection(txns)
    .orderBy(txnBookedOn, descending: true)
    .limit(20)
    .watchFrom(firstPage.nextCursor)
    .listen((page) { ... });

await docSub.cancel(); // stops the stream and unregisters the watcher
await db.close(); // completes every watch stream
```

Reading the log directly — for a sync outbox or an audit trail:

```dart
var watermark = savedWatermark; // the last seq you processed, 0 at first
final changes = await db.changesSince(watermark);
// Change: seq, collection (model name), path, op (set/delete), at (UTC)
for (final change in changes) {
  // ... push to your server / audit trail ...
  watermark = change.seq;
}
// Durably save `watermark`, then trim what you've processed:
await db.pruneChanges(upToSeq: watermark);

// db.lastChangeSeq() is the highest seq ever assigned; it never goes
// backwards, even after a full prune.
```

`CocoonOptions(keepChanges: false)` stops writing log rows for apps that
only need the in-process watches; notifications are unaffected, and
`changesSince` simply returns nothing.

## Opening and options

```dart
final db = await Cocoon.open(
  file,
  collections: [accounts, txns, splits], // register every collection once
  options: const CocoonOptions(
    durability: Durability.full, // PRAGMA synchronous; `normal` for speed
    cacheSize: 2000, // bounded LRU of decoded hot documents; 0 disables
    keepChanges: true, // write the change log the watches and sync read
    pageCacheMiB: 64, // PRAGMA cache_size on the writer; readers keep the default; <= 0 = default
    tempStoreInMemory: true, // PRAGMA temp_store = MEMORY
    walAutoCheckpointPages: 8000, // PRAGMA wal_autocheckpoint; <= 0 = default
  ),
);
```

On open, Cocoon creates missing tables and indexes in one transaction, adds
new field columns (backfilling them by decoding existing rows in batches of
500), and drops columns and indexes the adapters no longer declare. When
the stored shape matches, opening does no DDL at all. Tables in the file
without a registered adapter are left alone. Pass `schemaVersion:` and
`migrations:` (see "Schema migrations") and the same transaction first
applies every pending schema migration.

One `Cocoon` instance must own its database file: do not open the same file
from two instances or two processes — SQLite's write lock and the hot-cache
both assume a single writer.

## Benchmarks

Measured against sembast on finance-shaped data (20 accounts sharing
10k/100k/300k txns over five years, same indexes Finance Sync would
declare), every run a fresh process, every memory number minus a measured
harness baseline. Full tables and raw runs:
[packages/cocoon_bench/RESULTS.md](../cocoon_bench/RESULTS.md).

- Indexed reads: one account's latest-50 stays at ~0.7 ms p50 from 10k to
  300k txns (keyset scan over the composite index); sembast, which has no
  index, climbs 3.7 → 64 → 215 ms. Monthly totals: 2-3x faster at every
  size.
- Cold open: ~80 ms at every size; sembast parses its whole log into RAM:
  0.19 → 0.86 → 2.36 s.
- Memory: the engine's own share is flat — indistinguishable from the bare
  harness after open, +39 MB after reading across accounts, paging a year
  and 1,000 random gets, at every size. sembast holds every decoded record:
  +598 MB over the same floor at 300k.
- Where it loses: bulk import 1.6-2x slower and files 1.3-3.1x bigger (one
  row per document plus index and change-log rows, fsynced commits); point
  gets by id 2-24x slower than sembast's hash lookups at defaults; single
  writes 5-7x slower at `Durability.full`.

## Against other engines

`benchmarks/cocoon_rivals` extends the comparison to the engines a big
on-device app would actually pick — drift (plain SQLite, the speed limit),
Isar, ObjectBox, Hive CE and sembast, plus Cocoon itself at
`Durability.normal` — on the same finance-shaped data, four sizes up to
1,000,000 transactions, 13 operations, every run a fresh process, every
memory number minus a measured harness baseline, every rival's results
diffed against Cocoon's before any timing counts. Full tables and
per-workload verdicts:
[benchmarks/cocoon_rivals/RESULTS.md](../../benchmarks/cocoon_rivals/RESULTS.md).

What holds at 1,000,000 transactions:

- Indexed reads stay flat while the in-RAM engines linearly scan: one
  account's latest-50 is 0.74 ms p50 (from 0.69 ms at 10k) — Hive needs
  641 ms and sembast 769 ms (871x / 1,044x slower), Isar 55 ms, ObjectBox
  59 ms. The `(status, bookedOn)` status search is 1.42 ms vs 608 ms
  (Hive) and 1,171 ms (sembast).
- All-accounts scans: the paged June-2024 month range runs in 320 ms —
  7.7x faster than drift's idiomatic LIMIT/OFFSET paging (2,476 ms; keyset
  cursors, not offsets) and 309x faster than sembast (98,982 ms).
- Memory: after the read workloads Cocoon's own share is at or below the
  bare-harness floor at every size; at 1M sembast is +2,242 MB over the
  same floor, Hive +2,214 MB, Isar +262 MB, ObjectBox +539 MB.
- Under concurrent writes (one committed txn every 10 ms) Cocoon's
  latest-50 p95 is 3.0 ms; drift, which serializes every statement
  through one background isolate, pays 4.96 ms.
- Bulk writes (since the `db.batch()` / buffered-transaction write path):
  importing 1M txns takes 64.7 s vs drift's 95.5 s (1.5x faster; it was
  123.6 s), single writes at `Durability.full` are 1,787 µs p50 vs drift's
  2,918 µs, and restoring 300k txns from NDJSON takes 11.2 s vs drift's
  13.9 s. See `benchmarks/cocoon_rivals/IMPORT.md` for where the time
  went and what each change bought. The dedicated bulk-load path
  (`db.bulkWriter()`, the "Bulk loads" section) brings the 1M import to
  ~13 s.
- Where it loses, and by how much: bulk import is still 1.4x behind
  sembast (44.8 s), 2.6x behind Isar (24.9 s) and 8x behind Hive (8.0 s);
  files 388 MB vs drift's 224 MB (1.7x, measured with up to ~32 MiB of
  un-checkpointed WAL); the year report is 3.6x behind drift's SQL GROUP BY (a
  document API has no aggregate pushdown) at 1,377 ms vs 383 ms; gets by
  id are 6x behind ObjectBox and 20x behind Hive's in-RAM lookups;
  the NDJSON restore is 3.7x behind Hive's 3.0 s; single writes trail
  Hive's fsync-less appends (112 µs) — `Durability.normal` (377 µs) is
  7.7x faster than drift's default while staying crash-safe.

## Tuning

The knobs of `CocoonOptions`, with their measured trade-offs:

- `durability: Durability.normal` — skips the per-commit fsync. Single
  writes at 100k: p50 2,032 → 483 us (4.2x). Still durable against
  application crashes (WAL); on power loss the last commits may be lost.
  Keep `full` for money data that must survive a power cut.
- `keepChanges: false` — stops writing the on-disk change log. ~11% faster
  single writes. Only for databases where nothing needs `changesSince`
  (in-process `watch()` streams keep working).
- `cacheSize` — the LRU of decoded documents. It is a cap, not a
  pre-allocation: RAM follows the working set. A warm 1,000-document
  working set reads 50x faster than cold SQLite round-trips (113 → 2 ms),
  and raising `cacheSize` beyond the working set (2000 → 20000) measured no
  speed gain and no RSS gain. Raise it only to keep a larger hot set cached;
  lower it (or `0`) to shrink the ceiling.
- `pageCacheMiB` (default 64) — the SQLite page-cache budget on every
  connection (`PRAGMA cache_size = -<MiB KiB>`). SQLite's own 2 MB default
  cannot hold the hot upper levels of a six-B-tree table once the file
  outgrows it, and bulk imports pay for the re-reads: the raw-SQLite probe
  put the 1M per-1000-row commit cost at 63.2 s with the default and
  43.5 s with 64 MB. `<= 0` keeps SQLite's default.
- `tempStoreInMemory` (default on) — temp B-trees (sorts, spilling index
  maintenance) stay in RAM (`PRAGMA temp_store = MEMORY`): 43.5 → 35.6 s on
  top of the 64 MB page cache at 1M. Together these two knobs are what keep
  a 1M import near SQLite's own speed; measured in
  `benchmarks/cocoon_rivals/IMPORT.md` (which also records the rejected
  `wal_autocheckpoint = 0` — fast, but the WAL grows to 4.2 GB).
- `walAutoCheckpointPages` (default 8000 = 32 MiB) — how much WAL
  accumulates before SQLite checkpoints it into the database file
  (`PRAGMA wal_autocheckpoint`). SQLite's own 1000 pages (~4 MiB)
  checkpoints after nearly every commit of a bulk import, and the
  checkpoint cost grows with the database: at 1M txns the raw probe halved
  the import (45.6 s → ~19-24 s) by raising the interval, with the WAL
  bounded at ~36 MB. Disabling checkpoints outright was measured and
  rejected (unbounded 4.2 GB WAL). `<= 0` keeps SQLite's default.

## Inspecting a running app (DevTools)

A debug or profile app with a `Cocoon` database open gets a **Cocoon tab** in
Dart DevTools — no extra dependency, no setup. It browses collections,
documents and fields with a path breadcrumb, runs read-only typed queries and
shows whether an index served each one ("Used index cx_txn_ab12cd34" /
"Full scan: add Index([...])"), streams committed changes live, and shows the
schema (live tables plus the lock's field numbers and reserved numbers when
the app passed `schemaLock:` to `Cocoon.open`). Product builds never register
the inspector. See the [DevTools Inspector](https://docs.page/butterfly/libraries/cocoon/inspector)
guide for the panels and the `ext.cocoon.*` service extensions behind them.

To hand the schema view the lock, pass the parsed `cocoon.lock.json` on open:

```dart
final db = await Cocoon.open(
  file,
  collections: [accounts, txns, splits],
  schemaLock: SchemaLock.parse(File('cocoon.lock.json').readAsStringSync()),
);
```

## The native SQLite library

Cocoon talks to SQLite through `sqlite_async` and `package:sqlite3`.

- **Flutter**: add [`sqlite3_flutter_libs`](https://pub.dev/packages/sqlite3_flutter_libs)
  to the app; it bundles the right native SQLite for Android, iOS, macOS,
  Linux and Windows.
- **Dart CLI / server**: nothing to install with current `package:sqlite3`
  releases — its build hook compiles the bundled SQLite amalgamation (a C
  toolchain must be available at build time) or fetches a precompiled
  binary. On older SDKs without native-assets support, install the system
  SQLite development package instead (`apt install libsqlite3-dev` or your
  platform's equivalent). Native platforms only; there is no web build.

## Development

From the Butterfly workspace root:

```sh
dart pub get
cd packages/cocoon
dart analyze
dart test
```
