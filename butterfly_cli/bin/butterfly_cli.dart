import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/commit.dart';
import 'package:butterfly_cli/commands/generators/index.dart';
import 'package:butterfly_cli/commands/init.dart';
import 'package:butterfly_cli/commands/version.dart';
import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:mason_logger/mason_logger.dart';

void main(List<String> arguments) {
  configureDependencies();

  final runner = CommandRunner('butterfly', 'A CLI tool for butterfly project');

  runner.argParser.addFlag('verbose', abbr: 'v', help: 'Print verbose output');
  runner.argParser.addFlag('dev',
      abbr: 'D', help: 'Run in dev mode', defaultsTo: false);

  runner.addCommand(getIt<VersionCommand>());
  runner.addCommand(getIt<InitCommand>());
  runner.addCommand(getIt<CommitCommand>());
  runner.addCommand(getIt<GenerateCommand>());

  final result = runner.parse(arguments);

  runZonedGuarded(
    () {
      if (result.flag('verbose')) {
        final logger = Logger();
        logger.level = Level.verbose;
      }
      return runner.run(arguments);
    },
    (error, stack) {
      final logger = Logger();

      if (error is ReadableException) {
        logger
          ..err('${error.title}, code: ${error.code}')
          ..warn(error.message);
        if (error.hint != null) {
          logger.warn(error.hint);
        }
      } else if (error is UsageException) {
        logger.err(error.message);
        logger.info(error.usage);
      } else {
        logger.err('Something went wrong. Please try again.');
      }

      if (result.flag('dev')) {
        print('\n\n');
        throw error;
      } else {
        exit(error is ReadableException ? error.code : 1);
      }
    },
  );
}
