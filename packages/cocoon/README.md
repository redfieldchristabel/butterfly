# Cocoon

A typed, disk-backed, Firestore-style local database for Dart and Flutter,
built on SQLite.

- **Firestore-style API**: collections, documents and subcollections
  (`accounts/{accountId}/txns`).
- **Typed**: your model class is the schema. No `Map<String, Object?>`.
- **On disk**: data never loads into RAM wholesale; only a bounded cache of hot
  documents stays in memory.
- **Real queries**: indexed filters and sorts with keyset pagination.
- **No hand-written migrations**: `cocoon migrate` diffs your models against a
  committed lock file and only asks when it really can't tell (like a rename).

> Status: early scaffold. Paths, the canonical protobuf codec, cursors and the
> schema diff are in place; the storage engine, generator, CLI and DevTools
> inspector are next. See [doc/design.md](doc/design.md).

```dart
@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn {
  final int bookedOn;
  final int amountMinor;
  final String currency;
  final String? note;
  // ...
}
```

## Development

From the Butterfly workspace root:

```sh
dart pub get
cd packages/cocoon
dart analyze
dart test
```
