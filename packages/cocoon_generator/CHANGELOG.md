## Unreleased

- **`migrate` writes a YAML `cocoon.lock` now**, formatted like
  `pubspec.lock` so reviews next to the migration files stay quiet; the
  file is byte-stable — writing, reading and writing again is
  byte-identical — and the lock's fingerprint is unchanged, so nothing
  re-migrates. A project's legacy `cocoon.lock.json` is read as a fallback
  and converted in place: `migrate` writes `cocoon.lock`, deletes the JSON,
  and tells you to commit both changes and point build.yaml's sources at
  the new name. Both files present is an error, never a guess; `--check`
  counts a pending conversion as would-change; the builder reads either
  name and refuses to guess when both exist.
- **`migrate` is a development tool, not a CI step.** CI only builds: the
  build fails while the models and the committed lock disagree, so a model
  change that skipped `migrate` cannot pass CI. The non-interactive flags
  exist for scripted runs on a developer machine, and `--check` is
  read-only but redundant in CI because the build already fails.

## 0.1.0

This package is the build_runner code generator for
[Cocoon](https://pub.dev/packages/cocoon), the typed, disk-backed,
Firestore-style local database on SQLite. For every `@Collection` and
`@Embedded` model it writes the `CollectionAdapter`, the typed query handles
(`Txn$.bookedOn`) and the canonical protobuf wire codec, with field numbers
pinned by the committed `cocoon.lock`; the interactive `migrate`
command maintains that lock and writes on-device conversion stubs. First
published release; everything below is in it.

- `Map<String, V>` and `Map<int, V>` fields. The generated codec stores each
  entry as a nested message (key at field 1, value at field 2), written
  sorted by key so equal maps always encode to equal bytes; map keys must be
  `String` or `int`, values any supported non-Map type (nullable values and
  Maps inside Maps are build errors naming the field), and an `Index([...])`
  naming a map field is a build error.
- `migrate` handles map type changes like any other: the field moves to a
  fresh number and the migration stub declares the map's wire shape with
  `fromMap`/`toMap: MapWireType(key: ..., value: ...)`; the conversion
  receives the old entries as a `Map<Object?, Object?>` and its result is
  written back sorted by key.

- The interactive `dart run cocoon_generator:migrate` command. It diffs the
  models against the committed `cocoon.lock`, asks only what a human
  must answer (renames via a numbered best-first menu, plain `y/N` confirms
  for drops), refuses collection path moves, and writes the updated lock —
  plus, when a type change moved a field to a fresh number, a numbered
  `lib/cocoon_migrations/m<NNNN>_....dart` file with one typed conversion
  stub per rewrite and a regenerated `migrations.dart` list. Implement the
  stubs (the build fails while any still throws `UnimplementedError`), pass
  `schemaVersion: cocoonSchemaVersion` and `migrations: cocoonMigrations` to
  `Cocoon.open`, and pending migrations apply once, in order, on device.
- Script-friendly flags: `--rename Model.old=new`, `--drop Model.field`,
  `--drop-collection Model`, `--yes` (rename menus only, never drops) and
  `--check` for pre-commit hooks; a missing decision on non-interactive
  stdin exits 2 listing the flags that would resolve it. The flow is
  importable as `runMigrate` with an injectable terminal.
- The migration gate now matches `throw UnimplementedError` instead of the
  bare class name, so the generated file header (which documents the gate)
  no longer trips it.
- First version: build_runner codegen for `@Collection` and `@Embedded`
  classes. Emits the adapter, typed query handles and canonical wire codec
  using field numbers from the committed `cocoon.lock`, plus
  `cocoonSchemaVersion`. Fails the build when models and lock disagree.
