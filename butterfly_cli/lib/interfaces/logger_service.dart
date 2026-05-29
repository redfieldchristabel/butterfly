abstract class ILoggerService {
  void info(String? message);
  void detail(String? message);
  void err(String? message);
  void warn(String? message);
  void alert(String? message);
  String? prompt(String message, {String? defaultValue});
  bool confirm(String message, {bool defaultValue = true});
  T chooseOne<T>(String message, {required List<T> choices, T? defaultValue, String Function(T)? display});
}
