import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:mason_logger/mason_logger.dart';

class LoggerServiceImpl implements ILoggerService {
  final Logger _logger;

  LoggerServiceImpl({Level level = Level.info}) : _logger = Logger(level: level);

  @override
  void info(String? message) => _logger.info(message);

  @override
  void detail(String? message) => _logger.detail(message);

  @override
  void err(String? message) => _logger.err(message);

  @override
  void warn(String? message) => _logger.warn(message);

  @override
  void alert(String? message) => _logger.alert(message);

  @override
  String? prompt(String message, {String? defaultValue}) =>
      _logger.prompt(message, defaultValue: defaultValue);

  @override
  bool confirm(String message, {bool defaultValue = true}) =>
      _logger.confirm(message, defaultValue: defaultValue);

  @override
  T chooseOne<T>(String message,
          {required List<T> choices, T? defaultValue, String Function(T)? display}) =>
      _logger.chooseOne(message,
          choices: choices, defaultValue: defaultValue, display: display);
}
