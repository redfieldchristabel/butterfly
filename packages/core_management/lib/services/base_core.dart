// TODO: add locking mechanism
// TODO: add theme mechanism  mechanism
// TODO: add queue for build statefull widget

import 'package:core_management/services/base_error_handler.dart';
import 'package:core_management/services/base_loading.dart';
import 'package:core_management/services/base_route.dart';
import 'package:core_management/src/services/default_error_handler.dart';
import 'package:core_management/src/services/default_loading.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeData;

import '../src/services/default_theme.dart';
import 'base_theme.dart';

/// A base service class that serves as the foundation for core application services.
///
/// This abstract class provides a flexible and extensible foundation for managing
/// various core functionalities in the application. It's designed to be extended
/// to include features such as:
/// - Error handling
/// - Theme management
/// - State management
/// - Navigation/routing
/// - Localization
/// - And other cross-cutting concerns
///
/// The class follows the service locator pattern, allowing different parts of the
/// application to access shared services through a single entry point.
///
/// Example usage with multiple services:
/// ```dart
/// class AppCoreService extends BaseCoreService {
///   // Override default error handler
///   @override
///   final BaseErrorHandlerService errorHandlerService = AppErrorHandler();
///
///   // Add theme service
///   final ThemeService _themeService = AppThemeService();
///   ThemeService get themeService => _themeService;
///
///   // Add navigation service
///   final NavigationService _navigationService = AppNavigationService();
///   NavigationService get navigationService => _navigationService;
///
///   // Add other services as needed...
/// }
/// ```
///
/// Then in your main.dart:
/// ```dart
/// void main() {
///   final core = AppCoreService();
///   core.errorHandler(); // Initialize error handling
///   core.themeService.initialize(); // Initialize theme
///   runApp(MyApp(core: core));
/// }
/// ```
abstract class BaseCoreService {
  static late final BaseCoreService instance;

  BaseCoreService() {
    instance = this;
  }

  // ---------------- Services ----------------

  /// Gets the error handler service instance.
  ///
  /// This getter should be overridden to provide a custom error handler.
  /// If not overridden, it returns `null` and the default error handler
  /// will be used when [errorHandler] is called.
  @protected
  BaseErrorHandlerService get errorHandlerService => DefaultErrorHandler();

  BaseThemeService get themeService => DefaultThemeService();

  BaseLoadingService get loadingService => DefaultLoadingService();

  BaseRouteService? get routeService => null;

  // ---------------- Services End ----------------

  /// Sets up the global error handling for the application.
  ///
  /// This method initializes the error handling by setting up both Flutter's
  /// error handling and platform-level error handling using the provided
  /// [errorHandlerService] or a default [BaseErrorHandlerService] if none is provided.
  ///
  /// Call this method during the application's initialization, typically in
  /// `main()` before running the app:
  ///
  /// ```dart
  /// void main() {
  ///   final coreService = MyCoreService();
  ///   coreService.errorHandler();
  ///   runApp(MyApp());
  /// }
  /// ```
  ///
  /// This method should be called before any other code that might throw errors
  /// to ensure all errors are properly caught and handled.
  void errorHandler() {
    final handler = errorHandlerService;

    FlutterError.onError = handler.onError;
    PlatformDispatcher.instance.onError = handler.onPlatformError;
  }

  ThemeData get theme => themeService.theme;
}
