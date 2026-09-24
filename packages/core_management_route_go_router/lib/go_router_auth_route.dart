import 'dart:async';
import 'dart:developer';

import 'package:core_management/mixins/auth_route.dart';
import 'package:core_management_route_go_router/core_management_route_go_router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show BuildContext;
import 'package:go_router/go_router.dart';

abstract class GoRouterAuthRoute<T> extends GoRouterService
    with BaseAuthRoute<T> {
  /// Optional redirect path for role-based authorization after authentication.
  String? roleBasedRedirect(T user, GoRouterState state) => null;

  @override
  void routeLog(GoRouterState state) {
    if (kDebugMode) {
      // TODO: Add full stack trace from root route
      final buffer = StringBuffer()
        ..writeln('🔄 AUTH ROUTER EVENT')
        ..writeln('├─ 📁 Route Details:')
        ..writeln('│   ├─ 📍 Path: ${state.uri.path}')
        ..writeln('│   └─ 🔗 Full URL: ${state.uri.toString()}');

      buffer
        ..writeln('├─ 🔐 Auth Status:')
        ..writeln('│   ├─ 👤 User: ${user?.runtimeType ?? "null"}')
        ..writeln(
          '│   └─ 🔐 Is Public Route: ${publicRoutes.contains(state.uri.path)}',
        );

      if (redirectOverride != null) {
        buffer
          ..writeln('├─ ⚙️ Redirect Details:')
          ..writeln('│   ├─ 🔄 Override: $redirectOverride')
          ..writeln('│   └─ ⏳ Temporary: $temporaryRedirect');
      }

      log(
        buffer.toString(),
        name: '🦋 GoRouterAuthService',
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
  @override
  @protected
  FutureOr<String?> goRouterRedirect(
    BuildContext context,
    GoRouterState state,
  ) async {
    routeLog(state);

    onRouteChanged(context, state);

    final user = this.user;

    if (redirectOverride != null) {
      final route = redirectOverride;
      redirectOverride = null;
      return route;
    }

    if (debugScreen != null) {
      if (state.matchedLocation == debugRoute) return null;

      if (debugRoutes.contains(state.fullPath) ||
          debugRoutes.contains(state.matchedLocation)) {
        return null;
      }

      return debugRoute;
    }

    final matchesPublicRoute = publicRoutes.contains(state.matchedLocation);
    final matchesAuthTriggerRoute = authTriggerRoutes.contains(
      state.matchedLocation,
    );
    if (user == null && !(matchesPublicRoute || matchesAuthTriggerRoute)) {
      temporaryRedirect = state.uri.toString();
      return signInRoute;
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

    if (user != null) return roleBasedRedirect(user, state);

    return null;
  }
}
