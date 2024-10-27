class AuthManagementException implements Exception {
  final String title;
  final String message;
  final int code;

  AuthManagementException(
      {required this.title, required this.message, required this.code});
}
