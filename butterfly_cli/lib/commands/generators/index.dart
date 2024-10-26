import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/generators/version.dart';

class GenerateCommand extends Command {
  @override
  String get description => 'Generate a new object like model, etc...';

  @override
  String get name => 'generate';

  @override
  String get usage => 'butterfly generate [options] [arguments]';

  @override
  FutureOr? run() {
    //  TODO: add model generator command
    addSubcommand(VersionGeneratorCommand());
  }
}
