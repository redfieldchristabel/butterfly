import 'package:core_management/core_management.dart';

/// Mixin that provides authentication-related routing functionality.
///
/// This mixin helps manage authentication state and routes in your Flutter application.
/// It provides a structured way to handle:
/// - Protected routes that require authentication
/// - Public routes that don't require authentication
/// - Authentication flow (sign-in/sign-up)
/// - Post-authentication navigation
///
/// To use this mixin:
/// 1. Mix it into your route service class
/// 2. Implement the [user] getter when [requiresAuth] is true
/// 3. Configure auth-related routes as needed
///
/// Example usage:
/// ```dart
/// class MyRouteService with AuthRoute<User> {
///   @override
///   User? get user => AuthService.currentUser;
///   
///   // Optional: customize auth routes
///   @override
///   List<String> get authTriggerRoutes => ['/profile', '/settings'];
/// }
/// ```
///
/// Note: This mixin works in conjunction with [BaseRouteService] and should be
/// used when implementing authentication in your application.
mixin AuthRoute<T> on BaseRouteService {
  /// Returns the current authenticated user, or null if no user is signed in.
  ///
  /// This getter must be implemented when [requiresAuth] is true to provide
  /// access to the current authentication state. The routing system uses this
  /// information to handle authentication-based redirects and protect routes.
  ///
  /// Important notes:
  /// - This getter must be synchronous. If you're using a stream-based
  ///   authentication system, you should listen to the auth state changes
  ///   and update a synchronous getter or variable that this returns.
  /// - When [requiresAuth] is true, this getter must be implemented to return
  ///   the current user or null if no user is authenticated.
  /// - When [requiresAuth] is false, this getter is not used and can be left
  ///   unimplemented.
  ///
  /// Example implementation:
  /// ```dart
  /// @override
  /// User? get user => AuthService.currentUser;
  /// ```
  ///
  /// @throws UnimplementedError if the getter is not implemented when required.
  T? get user;

  /// Route paths that trigger navigation to [defaultAuthRoute] after authentication.
  /// Ignored if [requiresAuth] is false.
  List<String> get authTriggerRoutes => [signInRoutePath, signUpRoutePath];

  /// The default route path to navigate to after successful authentication.
  /// Ignored if [requiresAuth] is false.
  String get defaultAuthRoute => '/';

  /// The route path for the sign-in screen.
  /// Ignored if [requiresAuth] is false.
  String get signInRoutePath => '/login';

  /// The route path for the sign-up screen.
  /// Ignored if [requiresAuth] is false.
  String get signUpRoutePath => '/signup';

  /// Route paths that do not require authentication (public routes).
  /// Ignored if [requiresAuth] is false, as all routes are public.
  List<String> get publicRoutes => [];
}
