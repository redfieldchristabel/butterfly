import 'package:flutter/material.dart';

/// Abstract base class for route management services.
///
/// This class defines the configuration for routing and redirect logic in a Flutter application,
/// supporting both authenticated and non-authenticated apps. Subclasses implement the specific
/// router configuration (e.g., GoRouter, AutoRoute) and return a router configuration object
/// for use with [MaterialApp.router].
abstract class BaseRouteService<T> {
  /// Global key for the root navigator to access the top-level navigation context.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  BaseRouteService() {
    if (requiresAuth) {
      assert(authTriggerRoutes.isNotEmpty,
          'authTriggerRoutes must be at least one if requiresAuth is true.');
      assert(defaultAuthRoute.isNotEmpty,
          'defaultAuthRoute must be defined if requiresAuth is true.');
    }
  }

  /// The current [BuildContext] of the root navigator's overlay, if available.
  BuildContext? get context => navigatorKey.currentState?.overlay?.context;

  /// An optional route path to override the default navigation for one cycle.
  String? redirectOverride;

  /// An optional route path for temporary redirects, such as deep links or notifications.
  /// Cleared after use to avoid affecting subsequent navigations.
  String? temporaryRedirect;

  T? get user => null;

  /// Whether the application requires authentication.
  /// If false, all routes are treated as public, and auth-related properties are ignored.
  bool get requiresAuth => true;

  /// The default route path to navigate to after successful authentication.
  /// Ignored if [requiresAuth] is false.
  String get defaultAuthRoute => '/';

  /// Route paths that trigger navigation to [defaultAuthRoute] after authentication.
  /// Ignored if [requiresAuth] is false.
  List<String> get authTriggerRoutes => [signInRoutePath, signUpRoutePath];

  /// Route paths that do not require authentication (public routes).
  /// Ignored if [requiresAuth] is false, as all routes are public.
  List<String> get publicRoutes => [];

  /// The route path for the sign-in screen.
  /// Ignored if [requiresAuth] is false.
  String get signInRoutePath => '/login';

  /// The route path for the sign-up screen.
  /// Ignored if [requiresAuth] is false.
  String get signUpRoutePath => '/signup';


  /// Configures the router and returns a router configuration object for [MaterialApp.router].
  RouterConfig<Object> get routerConfig;

  /// Optional debug screen for bypassing authentication or any other checks
  /// during development.
  Widget? get debugScreen => null;

  /// Route paths accessible when [debugScreen] is active (for testing purposes).
  /// Ignored if [requiresAuth] is false.
  List<String> get debugRoutes => [];

  /// Optional list of [NavigatorObserver]s that will receive navigation events.
  ///
  /// These observers can be used to track navigation events, handle deep linking,
  /// or implement custom navigation behavior. The observers will be used by the
  /// router to notify about route changes.
  ///
  /// Returns `null` by default, which means no observers will be used.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// List<NavigatorObserver>? get observers => [
  ///   AnalyticsObserver(),
  ///   CustomNavigationObserver(),
  /// ];
  /// ```
  List<NavigatorObserver>? get observers => null;

  /// Optional builder for creating an error screen when navigation fails.
  Widget Function(BuildContext context, dynamic state)? get errorBuilder =>
      null;
}
