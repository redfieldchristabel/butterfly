/// Programmatic entry point of `dart run cocoon_generator:migrate`.
///
/// Exposed so tests (and tooling) can drive the migrate flow in-process
/// against a package root with an injected [MigrateIo] terminal instead of
/// spawning the executable:
///
/// ```dart
/// final code = await runMigrate(
///   packageRoot: tempPackage.path,
///   args: ['--rename', 'Txn.currency=currencyCode'],
///   io: FakeTerminal(),
/// );
/// ```
///
/// See the cocoon_generator README for the flags and exit codes.
library;

export 'src/migrate_cli.dart' show MigrateException, MigrateIo, runMigrate;
