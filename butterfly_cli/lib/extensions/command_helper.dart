import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:meta/meta.dart';

/// Mixin that provides convenient logger methods using GetIt-resolved
/// [ILoggerService]. Use this in commands instead of injecting
/// [ILoggerService] directly via constructor.
///
/// Tests can register a mock [ILoggerService] via GetIt before tests run.
mixin ButterflyLogger {
  ILoggerService get _butterflyLogger => getIt<ILoggerService>();

  @protected
  void info(String? message) => _butterflyLogger.info(message);

  @protected
  void detail(String? message) => _butterflyLogger.detail(message);

  @protected
  void err(String? message) => _butterflyLogger.err(message);

  @protected
  void warn(String? message) => _butterflyLogger.warn(message);

  @protected
  void alert(String? message) => _butterflyLogger.alert(message);

  @protected
  String? prompt(String message, {String? defaultValue}) =>
      _butterflyLogger.prompt(message, defaultValue: defaultValue);

  @protected
  bool confirm(String message, {bool defaultValue = true}) =>
      _butterflyLogger.confirm(message, defaultValue: defaultValue);

  @protected
  T chooseOne<T>(
    String message, {
    required List<T> choices,
    T? defaultValue,
    String Function(T)? display,
  }) =>
      _butterflyLogger.chooseOne<T>(
        message,
        choices: choices,
        defaultValue: defaultValue,
        display: display,
      );
}

/// Extension that provides convenient directory service methods using
/// GetIt-resolved [IDirectoryService].
extension CommandDirectoryHelper on Object {
  void ensureRoot() => getIt<IDirectoryService>().ensureRootDirectory();
  void ensureLibFolder() => getIt<IDirectoryService>().ensureLibFolder();
}
