import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/commit.dart';
import 'package:butterfly_cli/commands/generators/index.dart';
import 'package:butterfly_cli/commands/init.dart';
import 'package:butterfly_cli/commands/version.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:mason_logger/mason_logger.dart';

bool kDebugMode = false;

void main(List<String> arguments) {
  assert(() {
    kDebugMode = true;
    print("Debug mode: $kDebugMode");
    return true;
  }());

  final runner = CommandRunner('butterfly', 'A CLI tool for butterfly project');

  runner.argParser.addFlag('verbose', abbr: 'v', help: 'Print verbose output');
  runner.argParser.addFlag('dev mode',
      abbr: 'dev', help: 'Run in dev mode', defaultsTo: false);

  runner.addCommand(VersionCommand());
  runner.addCommand(InitCommand());
  runner.addCommand(CommitCommand());
  runner.addCommand(GenerateCommand());

  final result = runner.parse(arguments);

  runZonedGuarded(
    () {
      if (kDebugMode) {
        ButterflyLogger.level = Level.verbose;
      } else {
        ButterflyLogger.level =
            result.flag('verbose') ? Level.verbose : Level.info;
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
        if (kDebugMode) {
          logger.err("Please handle this error, this error"
              " will not show up in production.\n\n");
        } else {
          logger.err('Something went wrong. Please try again.');
        }
      }

      if (kDebugMode || result.flag('dev')) {
        print('\n\n');
        throw error;
      } else {
        exit(error is ReadableException ? error.code : 1);
      }
    },
  );
}
