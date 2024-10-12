import 'package:args/command_runner.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:mason_logger/mason_logger.dart';

extension CommandHelper on Command {
  /// {@macro ensureRootDirectory}
  void ensureRoot() => frameworkService.ensureRootDirectory();
}

typedef LoggerMethod = void Function(String? message, {LogStyle? style});

mixin ButterflyLogger {
  final logger = Logger(
    level: Level.verbose,
  );

  LoggerMethod get detail => logger.detail;

  LoggerMethod get info => logger.info;


}
