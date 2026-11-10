# butterfly_cli

The `butterfly` CLI automates repetitive project tasks: scaffolding models,
stamping `lib/version.dart` from `pubspec.yaml`, creating conventional
commits, and exposing an MCP server for AI coding agents.

Install once per machine:

```sh
dart pub global activate --source git https://github.com/redfieldchristabel/butterfly
```

## Commands

| Command | Aliases | Description |
| --- | --- | --- |
| `butterfly version` | — | Prints the built-in CLI version. |
| `butterfly init` | — | Interactive project wizard (auth, core, router). |
| `butterfly generate model <Name>` | `gen`/`g`, `m`/`mdl` | Scaffolds a model class under `lib/models/` (`--serializable`, `--immutable`, `--path`). |
| `butterfly generate model <Name> --cocoon` | | Scaffolds a Cocoon `@Collection` model (see below). |
| `butterfly generate version` | | Writes `lib/version.dart` from the pubspec version. |
| `butterfly commit` | `c`, `comit`, `commits`, `cm` | Interactive or flag-driven conventional `git commit`. |
| `butterfly cocoon migrate [args...]` | | Runs the project's `cocoon_generator:migrate` (see below). |
| `butterfly cocoon build` | | Runs the project's `build_runner build -d` (see below). |
| `butterfly mcp-server` | `mcp`, `mcp-srv` | Launches the stdio MCP server. |

Global flags: `--verbose` (`-v`) for detailed logging, `--dev` (`-D`) to
rethrow errors with stack traces. No `butterfly init` is needed for
`generate` and `cocoon` commands: a project root (`pubspec.yaml` + `lib/`) is
the only precondition.

## Cocoon shortcuts (optional)

Cocoon (`packages/cocoon`) works entirely without the Butterfly CLI: its real
tooling is `build_runner` + `cocoon_generator`, pinned in each project's
pubspec. These shortcuts only save typing — the CLI **never generates or
diffs anything itself**. It is installed once per machine and may be older
than the project's Cocoon; that is safe because every command delegates to
the project's own pinned tools.

### Scaffold a `@Collection` model

```sh
butterfly generate model Txn --cocoon
butterfly generate model Txn --cocoon --collection accounts/{accountId}/txns
butterfly generate model AuthUser --cocoon --path auth
```

- Writes a starter file under `lib/models/` (`@Collection('txns', indexes:
  [])`, a final field, `part 'txn.cocoon.dart';`, and dartdoc lines pointing
  at `Index` and `@Mirrored()`), then prints the next steps.
- `--collection` defaults to the plural snake_case of the name (`Txn` ->
  `txns`); a path with `{param}` segments is written as-is.
- `--cocoon` with `--immutable` is a usage error; `--serializable` is ignored
  for Cocoon models.
- If the pubspec is missing `cocoon`, `cocoon_generator` or `build_runner`,
  the hint with the exact `dart pub add` lines is printed — the file is
  still written, and the pubspec is never edited for you:

  ```sh
  dart pub add cocoon
  dart pub add --dev cocoon_generator build_runner
  ```

- Then, from the project root:

  ```sh
  dart run build_runner build -d
  butterfly cocoon migrate
  ```

### Run the project's codegen tools

```sh
butterfly cocoon migrate --check
butterfly cocoon migrate --rename Txn.bookedOn=day --yes
butterfly cocoon build
```

`cocoon migrate [args...]` forwards every argument verbatim to the project's
`dart run cocoon_generator:migrate` with inherited stdio, so the interactive
rename/drop menus work exactly as when run directly, and the CLI exits with
the same code (0 up to date or written, 1 refused/aborted/`--check` would
change, 2 usage error or missing non-interactive decision). `cocoon build`
runs `dart run build_runner build -d` the same way.

Both subcommands check the project's pubspec for `cocoon_generator`
(dev_)dependency and `build_runner` first; when something is missing they
fail with a readable message containing the `dart pub add` lines above
instead of editing the pubspec.

## MCP server

`butterfly mcp-server` exposes the generate commands as tools; the Cocoon
model scaffold is exposed as `generate_cocoon_model`, and the read-only
`cocoon_migrate_check` tool runs the project's `cocoon_generator:migrate
--check` (capturing output — the server's stdio carries the MCP protocol).
