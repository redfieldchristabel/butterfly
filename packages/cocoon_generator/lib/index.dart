/// Programmatic entry point of `dart run cocoon_generator:index add`.
///
/// Exposed so tests (and tooling) can drive the `index add` flow in-process
/// against a package root with an injected terminal instead of spawning the
/// executable:
///
/// ```dart
/// final code = await runIndexAdd(
///   packageRoot: tempPackage.path,
///   args: ['add', 'Txn', 'accountId,-bookedOn'],
///   io: FakeTerminal(),
/// );
/// ```
///
/// The flags pass through the same list: `--unique`, `--dry-run`, and the
/// batch form `['add', '--missing', 'log.txt']` (or `-` for stdin, read via
/// `MigrateIo.readAll`).
///
/// See the cocoon_generator README for the shape the command edits, its
/// refusals and exit codes.
library;

export 'src/index_cli.dart'
    show IndexAddException, indexDeclarationSource, runIndexAdd;
export 'src/migrate_cli.dart' show MigrateIo;
