import 'dart:async';
import 'dart:developer';

import 'package:core_management/services/base_route.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

abstract class GoRouterService<T> extends BaseRouteService<T> {
  // TODO: maybe move to parrent class
  static final GlobalKey<NavigatorState> _rootNavigator =
      GlobalKey<NavigatorState>();

  // getter to prevent assignment and can be access by this class descendant.
  GlobalKey<NavigatorState> get rootNavigator => _rootNavigator;

  List<RouteBase> get routes;

  /// Optional redirect path for role-based authorization after authentication.
  /// Ignored if [requiresAuth] is false.
  String? roleBasedRedirect(T? user) => null;

  /// Called whenever a route change occurs, before any redirection logic is processed.
  ///
  /// This method provides a hook to perform actions or side effects when the route changes,
  /// such as analytics tracking, logging, or updating application state.
  ///
  /// This method is called before any redirection logic in [goRouterRedirect], making it
  /// ideal for tracking all navigation attempts, even those that might be redirected.
  ///
  /// Parameters:
  /// - [context]: The current build context
  /// - [state]: The current router state containing navigation information
  ///
  /// Example:
  /// ```dart
  /// @override
  /// void onRouteChanged(BuildContext context, GoRouterState state) {
  ///   // Track page view in analytics
  ///   analytics.trackPageView(name: state.matchedLocation);
  ///
  ///   // Update app state based on new route
  ///   appState.updateCurrentRoute(state.fullPath);
  /// }
  /// ```
  @protected
  @mustCallSuper
  void onRouteChanged(BuildContext context, GoRouterState state) {
    if (kDebugMode) {
      log(
        '🔀 Router Redirect',
        name: 'GoRouterService',
        time: DateTime.now(),
        level: 800, // INFO level
        error: {
          'fullPath': state.fullPath,
          'matchedLocation': state.matchedLocation,
          'uri': state.uri.toString(),
          'temporaryRedirect': temporaryRedirect,
          'redirectOverride': redirectOverride,
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
    }
  }

  /// Handles route redirection logic for the GoRouter.
  ///
  /// This method is called by GoRouter whenever a navigation event occurs. It's responsible for:
  /// 1. Logging debug information in development mode
  /// 2. Executing any custom route change callbacks
  /// 3. Handling redirect overrides
  /// 4. Managing initial route redirection
  /// 5. Enforcing authentication requirements
  ///
  /// The method returns a [String] path to redirect to, or `null` to allow the navigation
  /// to proceed without redirection.
  ///
  /// Parameters:
  /// - [context]: The current build context
  /// - [state]: The current router state containing navigation information
  ///
  /// Returns:
  /// - A [String] representing the path to redirect to, or
  /// - `null` to allow the navigation to proceed without redirection
  ///
  /// Example:
  /// ```dart
  /// @override
  /// FutureOr<String?> goRouterRedirect(
  ///   BuildContext context,
  ///   GoRouterState state,
  /// ) {
  ///   // Custom redirection logic here
  ///   return null; // Allow navigation
  /// }
  /// ```
  @protected
  FutureOr<String?> goRouterRedirect(
    BuildContext context,
    GoRouterState state,
  ) async {
    onRouteChanged(context, state);

    if (redirectOverride != null) {
      final route = redirectOverride;
      redirectOverride = null;
      return route;
    }

    final initialRoute = initialRedirect;
    if (initialRoute != null) {
      return initialRoute;
    }

    if (!requiresAuth) {
      return null; // No auth checks, allow all routes
    }

    if (debugScreen != null &&
        debugRoutes.contains(state.uri.toString()) == true) {
      return '/test';
    }

    final user = this.user;

    if (user == null && !publicRoutes.contains(state.uri.toString())) {
      temporaryRedirect = state.uri.toString();
      return signInRoutePath;
    }

    if (user != null && authTriggerRoutes.contains(state.uri.toString())) {
      final route = temporaryRedirect ?? defaultAuthRoute;
      temporaryRedirect = null;
      return route;
    }

    if (temporaryRedirect != null) {
      final route = temporaryRedirect;
      temporaryRedirect = null;
      return route;
    }

    return roleBasedRedirect(user);
  }

  @override
  GoRouter get routerConfig {
    return GoRouter(
      navigatorKey: BaseRouteService.navigatorKey,
      initialLocation: '/',
      routes: routes,
      redirect: goRouterRedirect,
      errorBuilder: errorBuilder,
    );
  }
}
