## Unreleased

- The interactive `dart run cocoon_generator:migrate` command. It diffs the
  models against the committed `cocoon.lock.json`, asks only what a human
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
  using field numbers from the committed `cocoon.lock.json`, plus
  `cocoonSchemaVersion`. Fails the build when models and lock disagree.
