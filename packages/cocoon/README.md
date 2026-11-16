<p align="center"><img src="https://raw.githubusercontent.com/redfieldchristabel/butterfly/master/packages/cocoon/doc/kepo.png" width="160" alt="Kepo, the Cocoon mascot"></p>

<h1 align="center">Cocoon</h1>

<p align="center"><b>A document database for Dart &amp; Flutter that lives on disk, not in your RAM.</b></p>

<p align="center">Firestore-style collections · typed models · protobuf-packed docs · real indexes</p>

<p align="center"><i>Kepo keeps your data wrapped up tight on disk until you need it.</i></p>

> **"Wait, SQLite? So it's SQL?"** Nope. You never write a query string, a
> table or a join. Cocoon is a NoSQL document store, the Firestore way:
> collections, documents, subcollections. SQLite is only the engine room (a
> crash-safe single file). Firestore runs on Spanner and nobody writes Spanner
> SQL; same deal.

**Documentation: [docs.page/redfieldchristabel/butterfly/libraries/cocoon](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon)**
([Getting Started](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/getting-started) ·
[Performance & benchmarks](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/performance) ·
[Migrations](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/migrations))

## Why Cocoon

- **Documents, not rows.** Paths like `accounts/{accountId}/txns`, and
  `set` / `get` / `add` / `watch` on them. Your Dart class is the schema, no
  `Map<String, Object?>` anywhere.
- **Tiny on disk.** Documents are stored as canonical protobuf, about 125 B
  for a typical transaction doc.
- **Indexes that actually index.** Indexed fields are mirrored into typed
  columns, pages are keyset cursors (no `OFFSET`), and a query only runs when
  an index serves it.
- **RAM stays flat.** Data is never loaded wholesale; only a bounded cache of
  hot documents lives in memory.
- **Prefs & single models.** `db.prefs` for primitives, `db.single` for one
  typed model (the current user, say), `preload()` for synchronous reads.
- **Migrations you don't write.** Field numbers are pinned by name in a
  committed `cocoon.lock`; reorder or add fields freely, and a type change
  needs one conversion line.
- **Native platforms only, no web.** Android, iOS, macOS, Linux and Windows
  (the wire codec needs a 64-bit `int`).

## Install

```sh
dart pub add cocoon
dart pub add --dev cocoon_generator build_runner
```

That's all, in Flutter apps too: SQLite is bundled automatically through
`package:sqlite3`'s build hook, so don't add `sqlite3_flutter_libs`. A
runnable tour of the core API lives in [example/main.dart](example/main.dart).

## Quick start

```dart
// lib/models.dart
import 'package:cocoon/cocoon.dart';

part 'models.cocoon.dart';

@Collection('accounts')
class Account {
  const Account({required this.name});
  @Indexed()
  final String name;
}

@Collection('accounts/{accountId}/txns')
@Index(['accountId', '-bookedOn'])
class Txn {
  const Txn({required this.bookedOn, required this.amountMinor});
  final int bookedOn; // yyyymmdd
  final int amountMinor; // minor units
}
```

```sh
dart run cocoon_generator:migrate  # writes the initial cocoon.lock
dart run build_runner build -d     # writes the adapters and typed handles
```

(The one-time `build.yaml` that points build_runner at the lock is in
[Getting Started](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/getting-started).)

```dart
// bin/main.dart
import 'package:cocoon/cocoon.dart';
import 'package:my_app/models.dart';

Future<void> main() async {
  final db = await Cocoon.open('app.cocoon', collections: [accounts, txns]);

  final a1 = db.collection(accounts).doc('a1');
  await a1.set(const Account(name: 'Acme')); // upsert
  final snap = await a1.get(); // DocSnapshot<Account>? (null when missing)
  print(snap?.data.name);

  await a1.collection(txns).add(
    const Txn(bookedOn: 20261111, amountMinor: -1250),
  ); // fresh UUIDv7 id

  final recent = a1.collection(txns)
      .orderBy(Txn$.bookedOn, descending: true)
      .limit(50);
  final page = await recent.get(); // QueryPage<Txn>: .docs, .nextCursor
  print(page.docs.length);

  final live = recent.watch().listen((page) => print(page.docs.length));
  await live.cancel();
  await db.close();
}
```

## 1,000,000 transactions later

<p align="center"><img src="https://raw.githubusercontent.com/redfieldchristabel/butterfly/master/packages/cocoon/doc/gifs/cocoon_latest50_race.gif" alt="Latest 50 transactions for one account at 1M: drift 0.5 ms, Cocoon 0.7 ms, ObjectBox 44.4 ms, Isar 55.5 ms, Hive CE 710.5 ms, sembast 796.3 ms" width="720"></p>

Only hand-written SQL (drift) beats it, and drift gives you rows, not typed
documents. Memory stays flat too: +2 MB after the read workloads, where Hive
holds 2.1 GB and sembast 2.3 GB.

Where it loses, honestly: bulk import trails Isar 2.2x, and gets by id trail
Hive's in-RAM lookups. Every workload, with the losses spelled out, is on the
[Performance page](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/performance)
and in
[benchmarks/cocoon_rivals/RESULTS.md](https://github.com/redfieldchristabel/butterfly/blob/master/benchmarks/cocoon_rivals/RESULTS.md).

## What happens when you write

<p align="center"><img src="https://raw.githubusercontent.com/redfieldchristabel/butterfly/master/packages/cocoon/doc/gifs/cocoon_set_behind_the_scenes.gif" alt="What set() does: your object, canonical protobuf bytes, a row with typed index columns, the index entry, the change log, then watches fire after the commit" width="760"></p>

You call `set()`. Cocoon encodes the object as canonical protobuf, writes the
row, its index entries and a change-log row in one SQLite transaction, then
wakes only the watches on that collection.

## Learn more

Everything below lives on
[docs.page](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon).

- [Models & code generation](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/models): annotations, supported types, what the generator emits.
- [Queries & indexes](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/queries): filters, the index rule, collection groups, keyset pagination.
- [Aggregates & groupBy](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/aggregates): count, sum, average and group-by computed in SQLite.
- [Realtime & change log](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/realtime): document and query watches, `changesSince` for sync.
- [Transactions & collections](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/collections) and [batch, BulkWriter & getAll](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/bulk): atomic writes and fast imports.
- [Prefs & single models](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/prefs): key-value and one-of-a-kind typed values in the same file.
- [Backup & restore](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/backup): consistent whole-file copies and safe swaps.
- [Schema migrations](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/migrations): `cocoon.lock`, renames, conversions, backfills.
- [Isolates](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/isolates): move the engine off the UI isolate.
- [Tuning](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/performance#the-tuning-knobs): durability, cache size and the other `CocoonOptions` knobs.
- [DevTools inspector](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/inspector): browse and query a running app's database.
- [Writing an adapter by hand](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/models#without-code-generation): when you can't use codegen.
- [Butterfly CLI (optional)](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/getting-started): scaffolds models and forwards to the same pinned tools.

## Status

The storage engine, change log, realtime watches, `cocoon_generator` codegen
(with the interactive `migrate` command), the on-device migration runner and
the DevTools inspector are in. See [doc/design.md](doc/design.md).

## Development

From the Butterfly workspace root:

```sh
dart pub get
cd packages/cocoon
dart analyze
dart test
```
