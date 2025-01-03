import 'package:args/command_runner.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';

extension CommandHelper on Command {
  /// {@macro ensureRootDirectory}
  void ensureRoot() => frameworkService.ensureRootDirectory();
}

typedef LoggerMethod = void Function(String? message, {LogStyle? style});

mixin ButterflyLogger {
  static Level level = Level.info;

  @protected
  final logger = Logger(
    level: level,
  );

  @protected
  LoggerMethod get detail => logger.detail;

  @protected
  LoggerMethod get info => logger.info;
}
