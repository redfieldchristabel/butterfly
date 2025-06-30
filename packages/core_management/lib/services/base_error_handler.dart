import 'package:flutter/foundation.dart';

/// An abstract base class for handling errors in the application.
///
/// This class defines the interface for error handling in the Butterfly ecosystem.
/// Concrete implementations must provide their own implementation of error
/// handling methods to handle both Flutter framework errors and platform-level errors.
///
/// Example implementation:
/// ```dart
/// class MyErrorHandler extends BaseErrorHandlerService {
///   @override
///   void onError(FlutterErrorDetails error) {
///     // Custom error handling implementation
///     debugPrint('Error occurred: ${error.exception}');
///   }
///
///   @override
///   bool onPlatformError(Object error, StackTrace stackTrace) {
///     // Custom platform error handling
///     debugPrint('Platform error: $error');
///     return true; // Return true if error was handled
///   }
/// }
/// ```
abstract class BaseErrorHandlerService {
  /// Handles Flutter framework errors.
  ///
  /// This method is called when a Flutter framework error occurs.
  ///
  /// When overriding this method, it's recommended to call `super.onError(error)`
  /// to maintain the default error presentation that Flutter developers are
  /// familiar with seeing in the console. However, you can choose to implement
  /// completely custom error handling if needed.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// void onError(FlutterErrorDetails error) {
  ///   // Custom error handling (e.g., logging, analytics)
  ///   debugPrint('Custom error handling: ${error.exception}');
  ///
  ///   // Call super to maintain default error presentation
  ///   super.onError(error);
  /// }
  /// ```
  ///
  /// Parameters:
  ///   - [error]: The [FlutterErrorDetails] object containing information
  ///     about the error that occurred.
  void onError(FlutterErrorDetails errorDetails) {
    FlutterError.presentError(errorDetails);
  }

  /// Handles platform-level errors.
  ///
  /// This method is called when a platform-level error occurs.
  ///
  /// Implement this method to handle platform-specific errors. Return `true`
  /// if the error was handled, or `false` to let other error handlers
  /// process the error.
  ///
  /// Parameters:
  ///   - [error]: The error that occurred.
  ///   - [stackTrace]: The stack trace associated with the error, if available.
  ///
  /// Returns:
  ///   `true` if the error was handled by this method, `false` otherwise.
  bool onPlatformError(Object error, StackTrace stackTrace) {
    return false;
  }
}
