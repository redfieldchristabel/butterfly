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
  and reopening the database reconciles tables, columns and indexes on its
  own.

> Status: the storage engine, the change log, realtime watches and the
> `cocoon_generator` build_runner codegen are in. The interactive
> `migrate` CLI (which writes `cocoon.lock.json` for you) and the DevTools
> inspector are next. See [doc/design.md](doc/design.md).

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
  `@Embedded()` classes. Any of them nullable.
- A field missing from an older document decodes to the constructor default,
  else `null` when nullable, else the zero value (`0`, `''`, `false`, empty
  list, epoch UTC, first enum value).
- **Subcollection indexes start with the path params** (`accountId` above):
  a scoped query always filters them, so an index without them can't serve
  it. An index without params serves collection-group queries.
- The build fails when the models and `cocoon.lock.json` disagree:
  `Cocoon schema changed for <Model>: run "dart run cocoon_generator:migrate"`.
  The builder never writes the lock. (The `migrate` CLI arrives in the next
  release; until then, write the lock by hand, as `cocoon_example` does.)

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
  ),
);
```

On open, Cocoon creates missing tables and indexes in one transaction, adds
new field columns (backfilling them by decoding existing rows in batches of
500), and drops columns and indexes the adapters no longer declare. When the
stored shape matches, opening does no DDL at all. Tables in the file without
a registered adapter are left alone.

One `Cocoon` instance must own its database file: do not open the same file
from two instances or two processes — SQLite's write lock and the hot-cache
both assume a single writer.

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
