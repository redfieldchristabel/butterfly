class ReadableException implements Exception {
  final String title;
  final String message;
  final String? hint;
  final int code;

  ReadableException(
      {required this.title,
      required this.message,
      required this.code,
      this.hint});
}
