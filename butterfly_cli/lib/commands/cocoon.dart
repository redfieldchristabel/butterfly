import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';

/// `butterfly cocoon` — shortcuts around the project's own Cocoon tooling.
///
/// The CLI only runs `dart run cocoon_generator:migrate` and
/// `dart run build_runner build -d` in the project root; it never generates
/// or diffs anything itself.
class CocoonCommand extends Command<void> {
  CocoonCommand(ICocoonService cocoonService, {void Function(int)? exitFn}) {
    addSubcommand(CocoonMigrateCommand(cocoonService, exitFn: exitFn));
    addSubcommand(CocoonBuildCommand(cocoonService, exitFn: exitFn));
  }

  @override
  String get description =>
      "Run this project's own Cocoon codegen tools (migrate, build)";

  @override
  String get name => 'cocoon';
}

/// `butterfly cocoon migrate [args...]` — forwards [args] verbatim to
/// `dart run cocoon_generator:migrate` with inherited stdio, so the
/// interactive rename/drop menus work exactly as when run directly, and
/// exits with its exit code unchanged.
class CocoonMigrateCommand extends Command<void> with ButterflyLogger {
  final ICocoonService _cocoonService;
  final void Function(int exitCode) _exit;

  CocoonMigrateCommand(this._cocoonService, {void Function(int)? exitFn})
      : _exit = exitFn ?? ((code) => exit(code));

  /// The migrate flags (`--check`, `--rename`, `--drop`, `--yes`, ...) belong
  /// to the project's `cocoon_generator:migrate`, not to this CLI. Accepting
  /// anything keeps the pass-through verbatim instead of mirroring the
  /// generator's flag set (the CLI may be older than the project's
  /// generator).
  @override
  final ArgParser argParser = ArgParser.allowAnything();

  @override
  String get description =>
      'Run this project\'s `dart run cocoon_generator:migrate` '
      '(args pass through verbatim)';

  @override
  String get name => 'migrate';

  @override
  Future<void> run() async {
    ensureRoot();
    final exitCode = await _cocoonService.migrate(argResults!.rest);
    if (exitCode != 0) _exit(exitCode);
  }
}

/// `butterfly cocoon build` — runs `dart run build_runner build -d` in the
/// project root with inherited stdio and exits with its exit code.
class CocoonBuildCommand extends Command<void> with ButterflyLogger {
  final ICocoonService _cocoonService;
  final void Function(int exitCode) _exit;

  CocoonBuildCommand(this._cocoonService, {void Function(int)? exitFn})
      : _exit = exitFn ?? ((code) => exit(code));

  @override
  String get description =>
      'Run this project\'s `dart run build_runner build -d`';

  @override
  String get name => 'build';

  @override
  Future<void> run() async {
    ensureRoot();
    final exitCode = await _cocoonService.build();
    if (exitCode != 0) _exit(exitCode);
  }
}
