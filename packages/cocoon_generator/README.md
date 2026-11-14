# cocoon_generator

build_runner code generation for
[Cocoon](https://pub.dev/packages/cocoon), the typed, Firestore-style local
database on SQLite. Standalone: no Butterfly packages required.

**Documentation: [Models & Code Generation](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/models)**
([Getting Started](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/getting-started) ·
[Schema Migrations](https://docs.page/redfieldchristabel/butterfly/libraries/cocoon/migrations))

For every `@Collection` model it generates the `CollectionAdapter`, typed
query handles (`Txn$.bookedOn`, `Txn$.accountId`) and the canonical protobuf
codec; for every `@Embedded` class, a nested-message codec. Field numbers come
from the committed `cocoon.lock` at the package root, and the build
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

Add `cocoon.lock` to the build sources (`build.yaml`), declare
`part '<file>.cocoon.dart';` in each model file, then run
`dart run build_runner build -d`. Supported types, defaults and naming are
documented in the Cocoon README ("Models and code generation"); a complete
working setup lives in
[cocoon_example](https://github.com/redfieldchristabel/butterfly/tree/master/packages/cocoon_example).

## Maintaining the lock: `migrate`

You never write `cocoon.lock` by hand. When a model changes, the build
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
- A field **added** to an existing collection that is non-nullable and has
  no constructor default would read its proto3 zero value (`''`, `0`,
  `false`, the epoch, the first enum value) in every document written
  before it existed. A menu shows that exact value and asks: write a
  backfill stub (default — the engine sets the field on existing documents
  at the next open), keep the zero value (recorded in the lock, never asked
  again), or abort. A brand-new collection asks nothing.
- Everything else is decided without asking: added fields get fresh numbers,
  reorders and index changes change nothing, and a **type change** always
  moves the field to a fresh number (the old number is reserved forever) and
  writes a conversion stub. Moving a collection to a different path is
  refused.

It then writes the updated `cocoon.lock` and — only when stored data
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

The lock is YAML, formatted like `pubspec.lock` so reviews next to the
migration files stay quiet. `migrate` reads a project's legacy
`cocoon.lock.json` and converts it in place (writes `cocoon.lock`, deletes
the JSON, and reminds you to commit both changes and to point build.yaml's
sources at the new name); both files present is an error, never a guess.

### A development tool, not a CI step

Run `migrate` on your machine after changing a model, answer its questions,
then review and commit `cocoon.lock` and `lib/cocoon_migrations/` together.
CI only builds: `dart run build_runner build` fails when the models and the
committed lock disagree, so a model change that skipped `migrate` cannot
pass CI, and the fix is always "run migrate locally and commit" — never
"run migrate in CI". Generating migrations in a pipeline would skip the
human decisions (rename vs drop, backfill vs zero) that keep stored data
correct. The non-interactive flags below exist for scripted runs on a
developer machine (an AI agent working in a checkout, say); `--check` is
read-only but redundant in CI, because the build already fails.

### Flags for scripts

| Flag | Meaning |
| --- | --- |
| `--rename Model.old=new` | Decide a rename without the menu (repeatable). |
| `--drop Model.field` | Drop a removed field, reserving its number (repeatable). |
| `--drop-collection Model` | Confirm a removed collection or embedded class (repeatable). |
| `--backfill Model.field` | Decide an added required field with a backfill stub (repeatable). |
| `--keep-zero Model.field` | Decide an added required field to keep its zero value; recorded in the lock (repeatable). |
| `--yes` | Accept the default answer of every rename menu and of every new-required-field question (a backfill stub, never keep-zero); never covers drops. |
| `--check` | Exit 1 if the run would change anything — pending required-field decisions and a pending `cocoon.lock.json` -> `cocoon.lock` conversion included; writes nothing. |

When stdin is not a terminal and a decision is missing, the command exits 2
and lists the flags that would resolve it. Exit codes: 0 up to date or
written, 1 refused/aborted/`--check` would change, 2 usage error or missing
non-interactive decision. Output is colored only when stdout is a terminal.
The flow is also importable as `runMigrate` (from
`package:cocoon_generator/migrate.dart`) with an injectable terminal for
tests.

## Adding an index: `index add`

A `MissingIndexException` names the index a query needs and ends with a
ready fix:

```text
Fix: dart run cocoon_generator:index add Txn accountId,-bookedOn (writes @Index(['accountId', '-bookedOn']) above the Txn class)
```

Run exactly that:

```sh
dart run cocoon_generator:index add Txn accountId,-bookedOn
```

`fields` is a comma list in index order with `-` prefixing a descending
part; model fields and path params are both allowed. The command finds the
`@Collection` class under `lib/` with the analyzer (like `migrate`),
validates every name (an unknown name exits 1 with a "did you mean"), and
edits the model's source:

- one field that is not a path param gets `@Indexed()` (or
  `@Indexed(descending: true)`, `@Indexed(unique: true)` with `--unique`) on
  the field;
- everything else — composites and path params — inserts ONE
  `@Index([...])` line directly above the class declaration, after the
  existing `@Collection(...)` and `@Index` lines. `indexes:` is never
  touched, so a model whose list is built from a shared `const` variable
  works like any other.

`--unique` makes the added index UNIQUE within the collection.

It then `dart format`s the edited file and prints the two next steps:

```sh
dart run cocoon_generator:migrate   # an index on an existing collection changes the lock version
dart run build_runner build -d
```

Re-running an index that is already declared in exactly that order changes
nothing and says where it is declared — through `indexes:`, as a stacked
`@Index`, or as `@Indexed()` on the field; all three forms declare the same
index. The edits are narrow: a field that is not a single-variable
declaration, or that already carries a different `@Indexed()`, is refused
with exit 1 and the exact `@Index([...])` text to paste by hand.

### From the log: `--missing`

On a phone the model files are on the device, but the log is text the
developer already has. The batch form scans a saved debug log for every
`Fix: dart run cocoon_generator:index add ...` line (any prefix: logcat
tags, timestamps, `I/flutter (1234):`), dedupes them, and applies each
through the same code path as the single command:

```sh
dart run cocoon_generator:index add --missing run.log   # a saved flutter run / adb logcat output
cat run.log | dart run cocoon_generator:index add --missing -
```

Each index prints one line — `Added ...` (where), `Nothing to do: ...`
(already declared, where), `refused: ...` (why) — then a summary and, once,
the two next steps. Exit 0 when every index ended up declared, 1 when any
was refused, 2 for usage errors; a log with no `Fix:` lines says so and
exits 0. `--dry-run` (both forms) prints what would change and writes
nothing.

Like `migrate`, this is a development tool for your machine (or an AI agent
working in a checkout), never a CI step. Exit codes: 0 added or already
declared, 1 refused (unknown name, unsupported shape, model not found), 2
usage error. The flow is also importable as `runIndexAdd` (from
`package:cocoon_generator/index.dart`) with an injectable terminal for
tests; the Butterfly CLI forwards it as
`butterfly cocoon index add <Model> <fields>` (`--missing` and `--dry-run`
included, verbatim), and its MCP server exposes
`index add` because — unlike `migrate`'s questions — it is exactly the
source edit the asking agent wants.
