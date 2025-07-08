import 'package:core_management/core_management.dart';
import 'package:flutter/material.dart' show RouterConfig;

/// A mixin that provides route service functionality to any class that extends [BaseCoreService].
/// 
/// This mixin allows easy access to the router configuration and navigation methods
/// throughout your application. It's particularly useful for services that need to
/// handle navigation without direct access to [BuildContext].
///
/// ## Usage
///
/// ```dart
/// class MyService extends BaseCoreService with RouteServiceMixin {
///   // Access route service methods directly
///   void navigateToHome() {
///     routeService.pushReplacement('/home');
///   }
/// }
/// ```
mixin RouteServiceMixin on BaseCoreService {
  /// The route service instance that provides navigation capabilities.
  ///
  /// This getter must be implemented by the class using this mixin.
  BaseRouteService get routeService;

  /// The router configuration used by the application.
  ///
  /// This provides access to the root [RouterConfig] which includes the route map,
  /// route information parser, and router delegate.
  RouterConfig<Object> get routerConfig => routeService.routerConfig;
}
