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
  committed `cocoon.lock`, so reordering or adding fields needs nothing,
  reopening the database reconciles tables, columns and indexes on its own,
  and a type change needs exactly one conversion line that the on-device
  runner applies for you.
- **Native**: Android, iOS, macOS, Linux and Windows — the data is one SQLite
  file on the device. No web build (the wire codec needs a 64-bit `int`).

> Status: the storage engine, the change log, realtime watches, the
> `cocoon_generator` codegen (with the interactive `migrate` command that
> maintains `cocoon.lock`), the on-device migration runner and the
> DevTools inspector are in. See [doc/design.md](doc/design.md).

## Install

```sh
dart pub add cocoon
dart pub add --dev cocoon_generator build_runner
```

That's all, in Flutter apps too: SQLite itself is bundled automatically (see
["The native SQLite library"](#the-native-sqlite-library) below). A runnable
tour of the core API lives in [example/main.dart](example/main.dart).

## Quick start

```dart
// lib/models.dart
import 'package:cocoon/cocoon.dart';

part 'models.cocoon.dart';

@Collection('accounts/{accountId}/txns', indexes: [Index(['accountId', '-bookedOn'])])
class Txn {
  const Txn({required this.bookedOn, required this.amountMinor});
  final int bookedOn; // yyyymmdd
  final int amountMinor; // minor units
}
```

```sh
dart run build_runner build -d
```

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
committed `cocoon.lock`, never from field order.

```yaml
# pubspec.yaml
dependencies:
  cocoon: ^0.1.0
dev_dependencies:
  build_runner: ^2.4.13
  cocoon_generator: ^0.1.0
```

```yaml
# build.yaml: the generator reads the lock from the package root
targets:
  $default:
    sources:
      - lib/**
      - cocoon.lock
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

@Collection('accounts')
class Account {
  const Account({required this.name, this.tags = const [], this.address});
  @Indexed() // same as Index(['name']) on the class
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
- `@Indexed()` on a field declares the one-field index `Index(['field'])`
  (or `Index(['-field'])` with `descending: true`, `unique: true` for a
  `UNIQUE` index) exactly as if it were written on the class. The generator
  merges field-level and class-level indexes into one list — an index
  declared both ways is one index — and the physical index name comes from
  the canonical form, so moving a one-field index from the class to the
  field changes nothing: no schema version bump, no rebuild, no lock
  change. Allowed on the types an index field allows (`int`, `double`,
  `bool`, `String`, `DateTime`, `Uint8List`, enums); a list, map, embedded
  class or an `@Embedded`-class field is a build error naming the field and
  the supported types. Path params cannot carry it; they stay in
  class-level composites.
- `@Mirrored()` on a field copies it into its own `f_` column — aggregates
  and `groupBy` read it — without creating an index. Allowed on the types an
  index field allows (`int`, `double`, `bool`, `String`, `DateTime`,
  `Uint8List`, enums); a list, map, embedded class or an `@Embedded`-class
  field is a build error naming the field and the supported types. A field
  that is both mirrored and indexed is just indexed. See the Aggregates
  section's `@Mirrored()` subsection for the storage and backfill costs.
- **Subcollection indexes start with the path params** (`accountId` above):
  a scoped query always filters them, so an index without them can't serve
  it. An index without params serves collection-group queries.
- The build fails when the models and `cocoon.lock` disagree:
  `Cocoon schema changed for <Model>: run "dart run cocoon_generator:migrate"`.
  The builder never writes the lock; the migrate command does — see the next
  section.

## Schema migrations

Two tools compare the models against the committed `cocoon.lock`. The
build only *fails* when they disagree; `migrate` *fixes* the disagreement:

```sh
dart run cocoon_generator:migrate
```

**`migrate` is a development tool, not a CI step.** Run it on your machine
after changing a model, answer its questions, then review and commit
`cocoon.lock` and `lib/cocoon_migrations/` together. CI only builds:
`dart run build_runner build` fails when the models and the committed lock
disagree, so a model change that skipped `migrate` cannot pass CI — and the
fix is always "run migrate locally and commit", never "run migrate in CI".
Never generate migrations in a pipeline: it would skip the human decisions
(rename vs drop, backfill vs zero) that keep stored data correct. The
non-interactive flags exist for scripted runs on a developer machine (an AI
agent working in a checkout, say); `--check` is read-only but redundant in
CI, because the build already fails.

It asks only what a human must answer. For every removed field with new
fields alongside it, a numbered menu offers the rename candidates — best
first, Enter accepts the preselected one — and a final drop option; fields
without candidates and removed collections ask a plain `y/N`. Everything
else is decided without asking: added fields get fresh numbers, reorders
and index changes change nothing, and a type change always moves the field
to a fresh number with a conversion stub.

One more question, for an added field of an **existing** collection that is
non-nullable and has no constructor default: such a field would silently
read its proto3 zero value (`''`, `0`, `false`, the epoch for `DateTime`,
the first enum value) in every document written before it existed — for
money and dates, a quiet data bug. The command shows the exact value the
old documents would read and asks:

```text
Txn: `currency` (String) is new and required. Existing documents would read ''.
  1) Write a backfill stub (a migration sets the value for existing documents) [default]
  2) Keep the zero value ('')
  3) Abort (add a default or make it nullable first)
```

The default writes a backfill stub into the new migration file — a function
that receives each decoded old document and returns the value to store, so
it can depend on the document's other fields:

```dart
// lib/cocoon_migrations/m0004_txn_currency_backfill.dart
String backfillTxnCurrency(Txn doc) => doc.memo == null ? 'MYR' : 'USD';
```

Implement the stubs — the build fails while any `UnimplementedError`
remains — and on the device the engine runs the backfill over every
existing document inside the open's one transaction: batched, one
change-log row per document, crash-safe, progress through
`onMigrationProgress`, a throwing stub rolls the whole open back. Choice 2
records the decision in the lock so the question is never asked again. A
brand-new collection asks nothing — it has no existing documents.

The command writes the updated
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
(drops are never implied by `--yes`), `--backfill Model.field` and
`--keep-zero Model.field` (decide an added required field without the
menu; `--yes` picks the default — a backfill stub, never a silent
keep-zero), `--check` (exit 1 when the lock would change, no writes; it
reports pending required-field decisions and a pending `cocoon.lock.json`
conversion), and a missing decision on
non-interactive stdin exits 2 listing the flags that would resolve it. See
the cocoon_generator README.

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
`cocoon.lock`); write them in ascending order. Ready-made column
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

### Many documents by id: `getAll`

When the app already knows the ids — a split's participants, linked
accounts, a sync batch — fetch them in one call instead of one `get()` per
document:

```dart
final snaps = await a1.collection(txns)
    .getAll(['t1', 't2', 't3']); // List<DocSnapshot<Txn>?>

// or across parents of the same collection, from the database directly:
final snaps = await db.getAll([
  for (final id in participantIds) a1.collection(txns).doc(id),
  for (final id in linkedTxnIds) a2.collection(txns).doc(id),
]);
```

Results come back in the same order as the ids/refs, `null` at every
position whose document does not exist; duplicate ids are allowed and every
position is answered. Documents the hot cache holds come back without SQL;
only the misses go to SQLite, grouped per collection table and fetched with
one statement per 500 scope keys, all inside one read transaction — one
consistent snapshot for the whole call, and every fetched document lands in
the cache exactly like `get()`. One call answers one model type (refs of
different parents and subcollections of it mix freely); a
`<DocRef<Object>>[...]` list mixes models at the cost of an untyped
`.data`. An empty list answers immediately, without SQL.

Reach for `getAll` instead of a query when the id set is known and the
order is yours — a query would need an index that serves it and would
re-sort what you already know. Reads by id never wait for a running
`bulkWriter()` (the scope index is never deferred). Inside a transaction,
`tx.getAll(refs)` sees the transaction's own writes exactly like
`tx.get(ref)`.

## Queries

Filters and sorts are built from the typed handles. Every query needs an
index that serves it (the implicit `(params..., id)` index counts) —
otherwise `get()` throws a `MissingIndexException` whose message ends with a
`Fix:` line: the ready `dart run cocoon_generator:index add <Model> <fields>`
command that edits the model for you (plus the declaration it writes), and
the two follow-up commands (`migrate`, then `build_runner build -d`).
`.allowFullScan()` opts out explicitly. A `@Mirrored()` field (see the
Aggregates section below) has a column but no index: filtering or sorting on
one throws the same `MissingIndexException` — the annotation mirrors it for
totals, it does not serve queries.

While you are still shaping the schema,
`CocoonOptions(onMissingIndex: MissingIndexMode.scanAndWarn)` gives a
debug-only fallback: such queries run as a full scan, the missing index is
printed once per distinct missing index per process (with its `Fix:` line)
and listed in `db.missingIndexes`. It is honoured only while asserts are
enabled — a release build throws like the default, so a forgotten
`.allowFullScan()` can never silently degrade a shipped query. The fallback
never creates an index at runtime.

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

## Aggregates

Totals run in SQLite, not in Dart. `query.aggregate([...])` — Firestore's
aggregate API — computes `count`, `sum` and `average` (plus Cocoon's `minOf`
and `maxOf`) in one statement over the mirrored columns, with no documents
decoded:

```dart
final snapshot = await a1.collection(txns)
    .where(txnBookedOn.isGreaterThanOrEqualTo(20260101))
    .aggregate([count(), sum(txnAmountMinor), average(txnRate)])
    .get();
print(snapshot.count); // documents matched (nulls count too)
print(snapshot.getSum(txnAmountMinor)); // int, nulls skipped, empty = 0
print(snapshot.getAverage(txnRate)); // double?, null when nothing to average
```

The rules are the query rules: the same index requirement with the same
`MissingIndexException` (and `.allowFullScan()`), the same wait behind a
running `bulkWriter()`, and up to 5 functions per call. `orderBy` + `limit`
aggregate the first N documents in that order; without a `limit` the order
is irrelevant. `sum` of an `int` field is an `int` — exact, and summing
past ±2^63 throws an `AggregateOverflowException` instead of wrapping.
`average` is always a `double?`. Getters for functions you did not request
throw. Only mirrored fields can be aggregated — an `Index([...])` member or
a `@Mirrored()` field; either copies the field into an `f_` column. Anything
else throws an `UnmirroredFieldException` naming both fixes: `@Mirrored()`
for totals and groups, an `Index([...])` when a query also filters or sorts
on the field.

`query.count()` is sugar for `aggregate([count()])` and behaves exactly the
same as before.

### Totals over fields you don't filter on: `@Mirrored()`

A field only gets a column when some `Index([...])` lists it — but a field
you only total or group by doesn't need an index. Annotate it `@Mirrored()`
and it gets the same `f_` column (same type mapping, nullability and CHECK
as an index field) with no index over it:

```dart
@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn {
  @Mirrored()
  final int amountMinor; // sum(...) works; where(amountMinor > x) needs an Index
  final int bookedOn; // yyyymmdd
  ...
}
```

Aggregates and `groupBy` read a mirrored column exactly like an indexed one.
A `where`/`orderBy` on it still follows the index rule —
`MissingIndexException` suggests the `Index([...])`, `.allowFullScan()`
opts out — and the "field has no column" error names both fixes:
`@Mirrored()` for totals and groups, an `Index([...])` when a query also
filters or sorts on the field. A field that is both mirrored and indexed is
just indexed: one column, one index, no duplicate. `bulkWriter()` fills
mirrored columns like any other; there is no index to defer, so
`deferIndexes` doesn't affect them.

Adding `@Mirrored()` to an existing collection adds and backfills the
column on the next open — one pass over the stored documents, in the open
transaction, crash-safe like the index backfill; removing the annotation
drops the column the same way.

Measured on the rivals dataset at 1,000,000 transactions (Cocoon only; a
scratch copy of the schema with the amount index dropped, measured 2026-11-10
while an Android-emulator job was running on the same host — byte counts are
exact, the timings are +/-):

| Schema variant | File size | Bytes per row |
|---|---|---|
| `Index(['amountMinor'])` (indexed) | 394,452,992 B | 394.5 |
| `@Mirrored()` only (column, no index) | 371,388,416 B | 371.4 |
| neither (no amount column) | 367,202,304 B | 367.2 |

So the amount column costs ~4.2 B/row and the index over it another
~23.1 B/row at 1M — mirroring instead of indexing a field you only total
saves ~6% of this table's bytes per row. Adding `@Mirrored()` to an existing
1M database backfills the column at the next open in ~12 s (one pass over
1M documents, in the open transaction; the second open skips it — 3 ms).
The in-place backfill leaves the file ~11% above its compacted form (403.1
vs 364.5 B/row — page fragmentation from the column add and the row
updates); `db.backupTo()` writes the compacted form (0.98 s at 1M), so a
backup or any `VACUUM` reclaims it.

When to pick `Index` instead: the moment any query filters or sorts on the
field, it needs the index anyway — and an index field is already mirrored
(one column, one index), so `@Mirrored()` on top of an `Index([...])` adds
nothing.

### groupBy: a Cocoon extension (not in Firestore)

`query.groupBy([...]).aggregate([...])` buckets the results and aggregates
per group, in one statement:

```dart
final currencyKey = key(txnCurrency);
final monthKey = bucket(txnBookedOn, width: 100); // yyyymmdd -> yyyymm00
final groups = await a1.collection(txns)
    .where(txnBookedOn.isGreaterThanOrEqualTo(20260101))
    .groupBy([currencyKey, monthKey])
    .aggregate([sum(txnAmountMinor), count()])
    .get();
for (final group in groups) {
  final month = group.key(monthKey) ~/ 100; // yyyymm
  print('${group.key(currencyKey)} $month: ${group.getSum(txnAmountMinor)}');
}
```

Four key kinds:

- `key(field)` — the field's own value, converted back to its type
  (`DateTime`, enum, ...). Nullable fields group their nulls into one
  group, sorted first.
- `paramKey(param)` — a path param, so a collection-group query can
  aggregate one group per parent:
  `db.collectionGroup(txns).query().allowFullScan().groupBy([paramKey(txnAccountId)])`
  (a collection group has no single index; with no filter or order to
  anchor one, the group query needs `.allowFullScan()`).
- `bucket(field, width: w)` — fixed-width bands `floor(v / w) * w`:
  `yyyymmdd` days into months (`width: 100`), prices into bands. Integer
  fields with integer widths give `int` keys (exact floor division, no
  floats); double fields give `double` keys.
- `year(field, utcOffset:)`, `month(...)`, `day(...)` — calendar buckets on
  `DateTime` fields, **at a fixed `utcOffset`**. There are no IANA zones
  and no DST: for a DST zone a fixed offset silently buckets the wrong
  wall-clock times around transitions, so run one aggregate per period
  with range filters on the instant instead (or store the local date as a
  `yyyymmdd` int and `bucket` it). Fixed-offset zones like UTC or `+08:00`
  are exact — a 23:30 UTC txn lands in the next local day/month.

Up to 4 keys, ordered by the keys ascending; `limit(n)` caps the groups;
each group carries the same aggregates as a whole-result snapshot plus
`getMin`/`getMax`. The filters follow the same index rule as `get()`.
`minOf`/`maxOf` are also Cocoon extensions (named so they don't clash
with `dart:math`) (Firestore has no min/max
aggregates); they compare in SQL order and convert back to the field's
type, and are null when no value exists.

Both kinds have `watch()`: the first result on listen, re-computed when a
commit touches the collection (a subcollection scope only re-runs for its
own paths), coalesced like query watches, and an equal consecutive result
is never re-emitted.

## Transactions

```dart
await db.runTransaction((tx) async {
  final snap = await tx.get(txRef);
  await tx.set(txRef, snap!.data.copyWith(status: TxnStatus.posted));
  await tx.add(a1.collection(txns), otherTxn);
});
```

Reads inside the transaction see its own writes; an exception rolls back
everything. `tx.getAll(refs)` fetches many documents under the same
read-your-writes rules, with the same one-trip chunking as `db.getAll` —
and caches nothing until the commit succeeds. `set`/`add`/`delete` outside
a transaction each run in their own transaction.

Inside the body every database access goes through `tx`. A call on the
database itself — `doc.set`/`get`/`delete`, `collection.add`, a query's
`get`/`count`, `db.getAll`, `batch().commit()`, a `BulkWriter`, a nested
`runTransaction` — throws `TransactionMisuseError` immediately instead of
waiting forever for the transaction's own write lock or silently reading
committed data without its writes. A different open `Cocoon` (another file)
is fine, and starting a `watch()` is allowed: its first value reflects
committed data, and the transaction's writes arrive with its commit event.

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
  write transaction. The scope index is never dropped. A query whose plan
  needs a deferred index waits until the writer closes, then runs; `get()`
  by id is unaffected. Watches fire once per chunk commit; a query watch
  whose plan needs a deferred index re-runs only after the writer closes.
- **Skip the change log for pure imports** (`BulkWriterOptions(logChanges:
  false)`): a 1M-document import writes no log rows (~52 MB of the file at
  1M). In-process watches still fire per chunk, but the log has a hole
  where the load ran — a sync consumer resuming from a saved
  `lastChangeSeq` would silently skip the loaded documents, so give it a
  full resync (a fresh snapshot plus the changes after the load).
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
final pruned = await db.pruneChanges(upToSeq: watermark); // rows deleted

// db.lastChangeSeq() is the highest seq ever assigned; it never goes
// backwards, even after a full prune. db.earliestChangeSeq() is the oldest
// seq still readable (lastChangeSeq + 1 once the log is empty).
```

A consumer resuming from a pruned watermark must resync fully, not resume:
the pruned rows are gone, and reading from a seq below the floor throws

```dart
try {
  final changes = await db.changesSince(watermark);
  // ...
} on ChangesPrunedException catch (e) {
  // e.requestedSeq < e.earliestSeq: take a fresh snapshot, then resume
  // from the new lastChangeSeq().
}
```

Or let the engine bound the log for you:

```dart
final db = await Cocoon.open(file, collections: [...],
  options: const CocoonOptions(
    changeRetention: ChangeRetention(maxChanges: 50000, maxAge: Duration(days: 30)),
  ),
);
```

The engine deletes the old prefix in small batches after commits that wrote
change rows — never inside a user transaction, and never more than a few
thousand rows per commit, so a large backlog shrinks over subsequent writes
instead of stalling one. The default keeps everything.

`CocoonOptions(keepChanges: false)` stops writing log rows for apps that
only need the in-process watches; notifications are unaffected, and
`changesSince` simply returns nothing. The same idea applies at load time:
`db.bulkWriter(const BulkWriterOptions(logChanges: false))` writes no log
rows for a big import — give sync consumers a full resync afterwards.

Save `db.instanceId` durably next to the watermark, and compare the two
after every open (see "Backup and restore"): the guarantee that
`lastChangeSeq` never goes backwards holds within one database instance —
restoring a backup rewinds the change log to the backup's, and the re-rolled
instance id is how you detect it.

## Opening and options

```dart
final db = await Cocoon.open(
  file,
  collections: [accounts, txns, splits], // register every collection once
  options: const CocoonOptions(
    durability: Durability.full, // PRAGMA synchronous; `normal` for speed
    cacheSize: 2000, // bounded LRU of decoded hot documents; 0 disables
    keepChanges: true, // write the change log the watches and sync read
    changeRetention: null, // or ChangeRetention(...) to bound the log
    pageCacheMiB: 64, // PRAGMA cache_size on the writer; readers keep the default; <= 0 = default
    tempStoreInMemory: true, // PRAGMA temp_store = MEMORY
    walAutoCheckpointPages: 8000, // PRAGMA wal_autocheckpoint; <= 0 = default
    compactAfterUpgrade: true, // VACUUM once after a storage-format upgrade that left > 1/5 of the file free
    onMissingIndex: MissingIndexMode.throwError, // or .scanAndWarn: debug-only full-scan fallback (asserts on) that logs once per index and fills db.missingIndexes
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

Files also carry a storage-format version in `_cocoon_meta`. A file written
by an older Cocoon is upgraded on open — its collection tables are rebuilt
to the current layout (no stored `path` column; identity is the path params
plus id) table by table, inside the open, crash-safe, with progress
reported through `onMigrationProgress` — and a file written by a newer
version refuses to open with a `StorageFormatTooNewException`. Measured on
a 1M file: the one-time upgrade takes ~5-9 s, keeps every document and
change-log row, and the file transiently grows to ~519 MiB — the dropped
tables' pages sit on the freelist. After the upgrade's transaction commits,
the open compacts the file once (`VACUUM`) when more than a fifth of it is
reclaimable: 390 → 305 MiB with the freelist back to zero, ~1 s of
`VACUUM` at 1M, ~34 ms on a 0.5 MiB file. `compactAfterUpgrade: false`
keeps the old behavior (the next `backupTo`, which always compacts,
reclaims the space instead), and a compaction that cannot run — most often
a full disk, since `VACUUM` needs about the file size in free space — is
reported through `onCompactionFailed` and never fails the open. Normal
opens never compact.

One `Cocoon` instance must own its database file: do not open the same file
from two instances or two processes — SQLite's write lock and the hot-cache
both assume a single writer.

## Backup and restore

Cocoon owns two engine primitives — a consistent whole-file copy and a safe
swap of a database file for one of those copies. Everything else is the app's
policy: when to back up and where the file lives, which collections matter,
compression, encryption, files stored outside the database (they are not part
of any backup — copy them alongside and restore them yourself), extra
validation, UI. There is deliberately no app-level backup file format and no
bundled cryptography.

```dart
// A consistent, compacted copy of the whole database while the app keeps
// reading and writing: one read snapshot (SQLite's VACUUM INTO). Refuses an
// existing path unless overwrite: true.
final info = await db.backupTo('/backups/cocoon-2026-11-10.db');

// Read a backup back: is it a Cocoon backup, does it pass integrity_check,
// and what does it carry. Never modifies the file.
final known = await Cocoon.inspectBackup('/backups/cocoon-2026-11-10.db');
print('${known.bytes} bytes, schema v${known.schemaVersion}, '
    'seq #${known.lastChangeSeq}, Cocoon ${known.cocoonVersion}');

// Swap the (closed!) database file for a verified backup. The database at
// `path` must not be open in this isolate — close it first.
await db.close();
await Cocoon.restoreBackup(
  backup: '/backups/cocoon-2026-11-10.db',
  path: file,
  collections: [accounts, txns],
  schemaVersion: 1, // the same value you pass to Cocoon.open
  keepPrevious: true, // keep the replaced database as <path>.before-restore
);
final db = await Cocoon.open(file, collections: [accounts, txns]);
```

What the engine guarantees:

- **Consistent under writes.** The copy is one read snapshot: a write that
  commits while the backup runs is either fully in the copy or not at all,
  and the copy's change log, `lastChangeSeq`, schema version and
  bulk-writer state (deferred indexes included — opening a restored copy
  rebuilds them, like any crash mid-load) are exactly the snapshot's.
- **Atomic on failure.** `backupTo` writes `<path>.partial`, fsyncs it and
  renames it onto `path`; a failure leaves no file at `path` and removes the
  partial. `restoreBackup` verifies and compatibility-checks the backup
  before touching the target, then copies to `<path>.restoring` and swaps;
  a failure at any point puts the previous database back where it was.
- **Compatibility checked like `open`.** A backup written by a NEWER schema
  version or a NEWER storage format is refused before the target is
  touched; an older one is fine — the normal migrations run at the next
  `open`, and an older storage format's tables are rebuilt at that open
  (measured at 1M: ~5-9 s, then a `backupTo` compacts 390 → 305 MiB).
- **Typed errors.** `inspectBackup` throws `NotCocoonBackupException` (the
  file is not a Cocoon backup — a live database file isn't one either),
  `BackupDamagedException` (unreadable bytes or a failed
  `PRAGMA integrity_check`), `BackupFormatTooNewException` (a newer app's
  format version wrote it); `restoreBackup` throws
  `StorageFormatTooNewException` for a backup written by a newer storage
  format than this engine reads.
- **`keepChanges: false` databases back up too** — the copy's change log is
  simply empty, like the source's.

Restore safety: with `keepPrevious` (the default) the replaced database
moves to `<path>.before-restore` — a same-folder safety copy you keep until
you have validated the restore, deleted automatically when `keepPrevious` is
false. Stale `-wal`/`-shm`/`-journal` sidecars of the target are removed:
they belong to the replaced bytes and must never pair with the restored one.
The app then calls `Cocoon.open` as usual.

**Sync consumers: the instance id.** Every database gets a random instance
id when it is created (`db.instanceId`). A restore replaces the change log
with the backup's, so a watermark you saved can now be AHEAD of the
database — the guarantee that `lastChangeSeq` never goes backwards holds
within one instance, not across a restore. Save the instance id next to the
watermark and compare after the next open: a different id means the
watermark must be discarded (or reconciled). `restoreBackup` re-rolls the
id, so a restored database is always detected.

Wrap the file yourself: a backup is a plain SQLite file, so the app
compresses (gzip the bytes before uploading) or encrypts (before the file
leaves the device) as it likes; decompress/decrypt into a file and hand it
to `inspectBackup`/`restoreBackup`. A backup is a single self-contained file
in rollback-journal mode — it never has WAL/SHM sidecars — so moving it is
copying one file.

Measured on the rivals dataset at 1,000,000 transactions (a 388 MB file,
`Durability.full`; single runs on the shared build box, where the rivals
methodology holds ±30%): `backupTo` takes 0.8-1.0 s and the backup is
388 MB — 1.7% smaller than the source database file and 5% smaller than the
source with its WAL; single writes running during the backup
stay at 2.3-2.8 ms p50 and 4.9-5.2 ms p95 (the no-backup baseline p50 is
1.8 ms), so the app stays usable; `restoreBackup` takes 6.9-7.5 s, which
includes the whole-file `integrity_check` of the backup, the copy and the
swap. Runs via `dart run tool/backup_measure.dart --size 1000000` in
`benchmarks/cocoon_rivals`.

## Storage layout and file size

One table per collection; a row's stored identity is its **scope key** (the
path params as `p_` columns plus the document `id`, unique through the
table's scope index). The full `path` you see in refs, snapshots and the
change log is derived from it — there is no stored path column and no path
autoindex, which is 69.8 MB of a 1M-transaction file gone with no read
regression. `benchmarks/cocoon_rivals/STORAGE.md` has the full anatomy;
the shipped layout at 1M transactions:

| file | size |
|---|---|
| shipped layout (this Cocoon), fresh 1M import via `bulkWriter()` | 307.6 MiB |
| same load, change log pruned (`pruneChanges`/`changeRetention`) | 252.7 MiB |
| pre-2026-11 layout (with the path column), same data | 374.7 MiB |
| drift, same data (reference) | 230.9 MiB |

Per row: the document blob (canonical protobuf) averages 125.1 B in the
table, the change log adds ~52 B per written document (48 B payload, 1M
rows = 52.2 MB) until pruned, and the secondary + scope indexes together
126.4 MB. The internal `path` column is gone; documents written by older
Cocoon versions are upgraded on open (see "Opening and options").

## Benchmarks

Measured against sembast on finance-shaped data (20 accounts sharing
10k/100k/300k txns over five years, same indexes Finance Sync would
declare), every run a fresh process, every memory number minus a measured
harness baseline. Full tables and raw runs:
[packages/cocoon_bench/RESULTS.md](https://github.com/redfieldchristabel/butterfly/tree/master/packages/cocoon_bench/RESULTS.md).

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
1,000,000 transactions, every workload in RESULTS.md, every run a fresh process, every
memory number minus a measured harness baseline, every rival's results
diffed against Cocoon's before any timing counts. Full tables and
per-workload verdicts:
[benchmarks/cocoon_rivals/RESULTS.md](https://github.com/redfieldchristabel/butterfly/tree/master/benchmarks/cocoon_rivals/RESULTS.md).

What holds at 1,000,000 transactions (matrix v2, 9-10 Nov 2026; the
file size is the shipped layout):

- Indexed reads stay flat while the in-RAM engines scan: one account's
  latest 50 is 0.7 ms p50 against Isar 55 ms, ObjectBox 44 ms, Hive 711 ms
  and sembast 796 ms. The `(status, bookedOn)` status search is 1.4 ms vs
  Hive's 645 ms and sembast's 1,242 ms; the 50 biggest debits 1.3 ms (drift
  0.8, Isar 25.5, Hive 639).
- All-accounts scans: the paged June-2024 month range runs in 308 ms, 8.4x
  faster than drift's idiomatic LIMIT/OFFSET paging (2,588 ms; keyset
  cursors, not offsets) and 333x faster than sembast.
- Aggregates run in SQL (`aggregate()` / `groupBy()`): the year report is
  376 ms vs drift's 358 ms `GROUP BY`, and one account's monthly totals are
  35 ms for 12 group rows. See `benchmarks/cocoon_rivals/AGGREGATES.md`.
- Memory: after the read workloads Cocoon is +2 MB over the bare-harness
  floor; Isar +305 MB, ObjectBox +546 MB, Hive +2.1 GB, sembast +2.3 GB.
- Under concurrent writes (one committed txn every 10 ms) Cocoon's
  latest-50 p95 is 3.2 ms; drift, which serializes every statement through
  one background isolate, pays 4.3 ms.
- Writes: one write at `Durability.full` is 1,885 µs p50 vs drift's
  2,975 µs; `Durability.normal` (still crash-safe) is 450 µs.
- Bulk loads through each engine's best API: Isar 5.7 s, Hive 7.9 s,
  ObjectBox 8.8 s, **Cocoon `bulkWriter()` 12.6 s**, drift 18.7 s, sembast
  46.5 s.
- Where it loses, and by how much: the bulk load trails Isar 2.2x, Hive
  1.6x and ObjectBox 1.4x; gets by id are 9x behind ObjectBox and 19x
  behind Hive's in-RAM lookups (94 ms per 1,000 vs 10 and 5); the 300k
  NDJSON restore is 13.0 s vs Hive's 3.1 s; indexed reads cost 1.4-2x
  drift's (decoding documents into typed objects); the file is 305 MB vs
  drift's 231 MB for the same data (`benchmarks/cocoon_rivals/STORAGE.md`).

## Tuning

The knobs of `CocoonOptions`, with their measured trade-offs:

- `durability: Durability.normal` — skips the per-commit fsync. Single
  writes at 100k: p50 2,032 → 483 us (4.2x). Still durable against
  application crashes (WAL); on power loss the last commits may be lost.
  Keep `full` for money data that must survive a power cut.
- `keepChanges: false` — stops writing the on-disk change log. ~11% faster
  single writes. Only for databases where nothing needs `changesSince`
  (in-process `watch()` streams keep working). For databases where
  something does, `changeRetention` bounds the log instead (small batched
  deletes after commits) — at 1M the log is 52.2 MB, so keeping it bounded
  is the difference between a 305 MB and a 253 MB file.
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
shows whether an index served each one ("Used index `cx_txn_ab12cd34`" /
"Full scan: add `Index([...])`"), streams committed changes live, and shows the
schema (live tables plus the lock's field numbers and reserved numbers when
the app passed `schemaLock:` to `Cocoon.open`). Product builds never register
the inspector. See the [DevTools Inspector](https://docs.page/butterfly/libraries/cocoon/inspector)
guide for the panels and the `ext.cocoon.*` service extensions behind them.

To hand the schema view the lock, pass the parsed `cocoon.lock` on open:

```dart
final db = await Cocoon.open(
  file,
  collections: [accounts, txns, splits],
  schemaLock: SchemaLock.parse(File('cocoon.lock').readAsStringSync()),
);
```

## The native SQLite library

Cocoon talks to SQLite through `sqlite_async` and `package:sqlite3`.

There is nothing to add, for Flutter apps and Dart CLIs/servers alike.
Cocoon depends on `package:sqlite3` 3.x, whose build hook bundles a
precompiled SQLite into the app on Android, iOS, macOS, Linux and Windows
(downloaded from that package's GitHub releases at build time; see its docs
to compile SQLite yourself or to use SQLCipher instead).

- **Don't add `sqlite3_flutter_libs`.** With sqlite3 3.x it is no longer
  needed; sqlite3's own upgrade guide says to drop it. If another package in your app still pulls in `sqlite3_flutter_libs` 0.5.x (the old, 2.x-era version with its own build scripts), upgrade it to `^0.6.0`, which is an empty placeholder, so only one SQLite ships.
- Native platforms only; there is no web build.

## Using the Butterfly CLI (optional)

Cocoon works entirely without the Butterfly CLI — everything above is plain
`build_runner` and `cocoon_generator`, pinned in your pubspec. If the CLI
(`butterfly_cli`, installed once per machine) happens to be installed, it can
save you some typing. It never generates or diffs anything itself: it only
scaffolds a starter model from a template and delegates every codegen step to
your project's own pinned tools, so a CLI one version behind your Cocoon
cannot write mismatched code.

```sh
# Starter file for a @Collection model (lib/models/txn.dart, path txns)
butterfly generate model Txn --cocoon

# Same, with an explicit collection path ({param} segments kept as-is)
butterfly generate model Txn --cocoon --collection accounts/{accountId}/txns

# Then the two commands it prints, run from your project root:
dart run build_runner build -d
butterfly cocoon migrate
```

`butterfly cocoon migrate [args...]` forwards every argument verbatim to your
project's `dart run cocoon_generator:migrate` with inherited stdio (the
interactive rename/drop menus work exactly as when run directly) and exits
with the same code; `butterfly cocoon build` runs `dart run build_runner
build -d` the same way. `butterfly cocoon index add <Model> <fields>` forwards
to `dart run cocoon_generator:index add` — the one-line fix a
`MissingIndexException` names: run it, then the migrate and build commands it
prints. All three check your pubspec for `cocoon_generator` and
`build_runner` first and print the exact `dart pub add` lines when something
is missing — the CLI never edits your pubspec. In a project without a
`cocoon.lock` yet, the first migrate just writes the initial lock and
exits 0.

## Development

From the Butterfly workspace root:

```sh
dart pub get
cd packages/cocoon
dart analyze
dart test
```
