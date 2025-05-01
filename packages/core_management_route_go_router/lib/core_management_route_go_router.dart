import 'dart:async';

import 'package:core_management/services/base_route.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

abstract class GoRouterService<T> extends BaseRouteService<T> {
  List<RouteBase> get routes;

  /// Optional redirect path for role-based authorization after authentication.
  /// Ignored if [requiresAuth] is false.
  String? roleBasedRedirect(T? user) => null;

  FutureOr<String?> goRouterRedirect(
    BuildContext context,
    GoRouterState state,
  ) async {
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
