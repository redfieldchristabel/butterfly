import 'package:flutter/material.dart';

/// Abstract base class for route management services.
///
/// This class defines the configuration for routing and redirect logic in a Flutter application,
/// supporting both authenticated and non-authenticated apps. Subclasses implement the specific
/// router configuration (e.g., GoRouter, AutoRoute) and return a router configuration object
/// for use with [MaterialApp.router].
abstract class BaseRouteService {
  /// Global key for the root navigator to access the top-level navigation context.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// The current [BuildContext] of the root navigator's overlay, if available.
  BuildContext? get context => navigatorKey.currentState?.overlay?.context;

  String initialRoute = '/';

  /// An optional route path to override the default navigation for one cycle.
  String? redirectOverride;

  /// An optional route path for temporary redirects, such as deep links or notifications.
  /// Cleared after use to avoid affecting subsequent navigations.
  String? temporaryRedirect;

  /// Configures the router and returns a router configuration object for [MaterialApp.router].
  RouterConfig<Object> get routerConfig;

  /// Optional debug screen for bypassing authentication or any other checks
  /// during development.
  Widget? get debugScreen => null;

  /// Route paths accessible when [debugScreen] is active (for testing purposes).
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
