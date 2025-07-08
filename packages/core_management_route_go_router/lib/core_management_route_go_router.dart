import 'dart:async';
import 'dart:developer';

import 'package:core_management/services/base_route.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

abstract class GoRouterService<T> extends BaseRouteService<T> {
  /// Gets the global navigator key used for navigation.
  ///
  /// This is a convenience getter that provides access to the static [BaseRouteService.navigatorKey].
  /// It allows accessing the navigator key through an instance of this class.
  GlobalKey<NavigatorState> get navigatorKey => BaseRouteService.navigatorKey;

  List<RouteBase> get routes;

  /// Optional redirect path for role-based authorization after authentication.
  /// Ignored if [requiresAuth] is false.
  String? roleBasedRedirect(T? user) => null;

  /// Optional [Listenable] to trigger route re-evaluation when it notifies its listeners.
  ///
  /// When this notifier triggers (by calling `notifyListeners()`), the router will
  /// re-evaluate the current route and potentially redirect based on the new state.
  ///
  /// This is useful for scenarios like authentication state changes, where you want
  /// to redirect the user when they log in or out.
  ///
  /// Example:
  /// ```dart
  /// final _authNotifier = ValueNotifier<bool>(false);
  ///
  /// @override
  /// Listenable? get refreshListenable => _authNotifier;
  ///
  /// // Later, when auth state changes:
  /// _authNotifier.value = true; // Will trigger route re-evaluation
  /// ```
  @protected
  Listenable? get refreshListenable => null;

  /// Called whenever a route change occurs, before any redirection logic is processed.
  ///
  /// This method provides a hook to perform actions or side effects when the route changes,
  /// such as analytics tracking, logging, or updating application state.
  ///
  /// This method is called before any redirection logic in [goRouterRedirect], making it
  /// ideal for tracking all navigation attempts, even those that might be redirected.
  ///
  /// In debug mode, it automatically logs route change information including:
  /// - Full path
  /// - Matched location
  /// - URI
  /// - Temporary redirect status
  /// - Any redirect overrides
  /// - Timestamp
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
  ///
  ///   // Call super to maintain default logging behavior
  ///   super.onRouteChanged(context, state);
  /// }
  /// ```
  @protected
  @mustCallSuper
  void onRouteChanged(BuildContext context, GoRouterState state) {
    if (kDebugMode) {
      // TODO: add full stack trace
      final buffer =
          StringBuffer()
            ..writeln('🔄 ROUTER REDIRECT')
            ..writeln('├─ 📍 Path: ${state.uri.path}')
            ..writeln('├─ 🔗 Full URL: ${state.uri.toString()}')
            ..writeln('├─ 🗂️  Full Path: ${state.fullPath}');

      buffer
        ..writeln('└─ ⚙️  Redirect Details:')
        ..writeln('   ├─ Temporary: $temporaryRedirect')
        ..writeln('   └─ Has Override: ${redirectOverride != null}');

      if (redirectOverride != null) {
        buffer.writeln('      └─ Override: $redirectOverride');
      }

      if (requiresAuth) {
        buffer.writeln('└─ 👤 User: ${user ?? "null"}');
      }

      log(
        buffer.toString(),
        name: '🦋 GoRouterService',
        time: DateTime.now(),
        level: 800,
      );
    }
  }

  /// Handles route redirection logic for the GoRouter.
  ///
  /// This method is called by GoRouter whenever a navigation event occurs. It's responsible for:
  /// 1. Executing [onRouteChanged] callback (which includes debug logging)
  /// 2. Handling redirect overrides
  /// 3. Managing initial route redirection
  /// 4. Enforcing authentication requirements
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

    final user = this.user;

    if (redirectOverride != null) {
      final route = redirectOverride;
      redirectOverride = null;
      return route;
    }

    if (!requiresAuth) {
      return null; // No auth checks, allow all routes
    }

    if (debugScreen != null &&
        debugRoutes.contains(state.uri.toString()) == true) {
      return '/test';
    }

    final matchesPublicRoute = publicRoutes.contains(state.matchedLocation);
    final matchesAuthTriggerRoute = authTriggerRoutes.contains(
      state.matchedLocation,
    );
    if (user == null && !(matchesPublicRoute || matchesAuthTriggerRoute)) {
      temporaryRedirect = state.uri.toString();
      return signInRoutePath;
    }

    if (user != null && authTriggerRoutes.contains(state.matchedLocation)) {
      final route = temporaryRedirect ?? defaultAuthRoute;
      temporaryRedirect = null;
      return route;
    }

    if (matchesAuthTriggerRoute) {
      return null;
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
      refreshListenable: refreshListenable,
      observers: observers,
      initialLocation: '/',
      routes: routes,
      redirect: goRouterRedirect,
      errorBuilder: errorBuilder,
    );
  }
}
