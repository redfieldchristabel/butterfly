import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/init.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:mason_logger/mason_logger.dart';

bool isDebugMode = false;

void main(List<String> arguments) {
  assert(() {
    isDebugMode = true;
    print("Debug mode: $isDebugMode");
    return true;
  }());

  var runner =
      CommandRunner('butterfly_cli', 'A CLI tool for butterfly project');

  runner.addCommand(InitCommand());

  runZonedGuarded(
    () => runner.run(arguments),
    (error, stack) {
      if (error is ReadableException) {
        final logger = Logger();
        logger
          ..err('${error.title}, code: ${error.code}')
          ..warn(error.message);
        if (error.hint != null) {
          logger.warn(error.hint);
        }
      } else {
        if (isDebugMode) {
          print("Please handle this error, this error"
              " will not show up in production.\n\n");
        }
      }

      if (isDebugMode) {
        print('\n\n');
        throw error;
      } else {
        if (error is ReadableException) {
          exit(error.code);
        }
      }
    },
  );
}
