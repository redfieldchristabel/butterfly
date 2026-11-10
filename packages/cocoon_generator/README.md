# cocoon_generator

build_runner code generation for
[Cocoon](https://pub.dev/packages/cocoon), the typed, Firestore-style local
database on SQLite. Standalone: no Butterfly packages required.

For every `@Collection` model it generates the `CollectionAdapter`, typed
query handles (`Txn$.bookedOn`, `Txn$.accountId`) and the canonical protobuf
codec; for every `@Embedded` class, a nested-message codec. Field numbers come
from the committed `cocoon.lock.json` at the package root, and the build
fails when the models and the lock disagree. The builder never writes the
lock.

```sh
dart pub add cocoon
dart pub add --dev cocoon_generator build_runner
```

```yaml
# pubspec.yaml
dev_dependencies:
  build_runner: ^2.4.13
  cocoon_generator: ^0.1.0
```

Add `cocoon.lock.json` to the build sources (`build.yaml`), declare
`part '<file>.cocoon.dart';` in each model file, then run
`dart run build_runner build -d`. Supported types, defaults and naming are
documented in the Cocoon README ("Models and code generation"); a complete
working setup lives in
[cocoon_example](https://github.com/redfieldchristabel/butterfly/tree/master/packages/cocoon_example).

## Maintaining the lock: `migrate`

You never write `cocoon.lock.json` by hand. When a model changes, the build
fails and tells you to run:

```sh
dart run cocoon_generator:migrate
```

The command reads the models under `lib/` with the analyzer, diffs them
against the committed lock, and asks only what a human must answer:

- For every removed field that has new fields alongside it, a numbered menu
  offers the rename candidates, best first (`Enter` accepts the
  preselection), plus a final `drop` option. A candidate already chosen for
  another field is not offered again.
- Removed fields without candidates and removed collections ask a plain
  `y/N` confirm; the default (`No`) aborts without writing anything.
- Everything else is decided without asking: added fields get fresh numbers,
  reorders and index changes change nothing, and a **type change** always
  moves the field to a fresh number (the old number is reserved forever) and
  writes a conversion stub. Moving a collection to a different path is
  refused.

It then writes the updated `cocoon.lock.json` and — only when stored data
must change — a numbered migration file under `lib/cocoon_migrations/`
(`m0002_....dart`, plus the `migrations.dart` list that collects every
file). Implement the `upgrade...` functions in the new file — the build
fails while any of them still throws `UnimplementedError` — and commit the
lock, the migration file and the models together. On the device, hand both
generated artifacts to the engine:

```dart
final db = await Cocoon.open(
  file,
  collections: [accounts, txns],
  schemaVersion: cocoonSchemaVersion, // from lib/cocoon_schema.g.dart
  migrations: cocoonMigrations, // from lib/cocoon_migrations/migrations.dart
);
```

`Cocoon.open` applies pending migrations once, in order, in one transaction;
see the Cocoon README's "Schema migrations" section.

### Flags for scripts

| Flag | Meaning |
| --- | --- |
| `--rename Model.old=new` | Decide a rename without the menu (repeatable). |
| `--drop Model.field` | Drop a removed field, reserving its number (repeatable). |
| `--drop-collection Model` | Confirm a removed collection or embedded class (repeatable). |
| `--yes` | Accept the default answer of every rename menu; never covers drops. |
| `--check` | Exit 1 if the run would change anything; writes nothing. |

When stdin is not a terminal and a decision is missing, the command exits 2
and lists the flags that would resolve it. Exit codes: 0 up to date or
written, 1 refused/aborted/`--check` would change, 2 usage error or missing
non-interactive decision. Output is colored only when stdout is a terminal.
The flow is also importable as `runMigrate` (from
`package:cocoon_generator/migrate.dart`) with an injectable terminal for
tests.
