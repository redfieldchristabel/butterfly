import 'dart:async';
import 'dart:developer';

import 'package:auth_management/auth_management.dart';
import 'package:auth_management/auth_management_provider.dart';
import 'package:flutter/foundation.dart' show mustCallSuper;

/// The app-facing auth service: the one place your app asks
/// "who is signed in?".
///
/// Extend this directly when your sign-in flow already produces the full
/// user model [T] (for example, your own API returns the complete user on
/// login). Write it to [dbRepo] yourself and [streamUser] / [getUser] read it
/// back:
///
/// ```dart
/// class AuthService extends AuthServiceRepository<AppUser> {
///   Future<void> signIn(String email, String password) async {
///     final user = await api.login(email, password); // full user, role, coins
///     await dbRepo.addUser(user);
///   }
///
///   @override
///   AuthManagementDatabaseRepository<AppUser> get dbRepo => hiveRepo;
/// }
/// ```
///
/// If your provider only tells you **who** the user is (Firebase Auth,
/// OAuth2/OIDC, Supabase...) and the rest of the user lives in Firestore,
/// MySQL or an API, extend [IdentityAuthRepository] instead. It fetches and
/// caches that data for you.
abstract class AuthServiceRepository<T> {
  static late final AuthServiceRepository instance;

  /// The latest user emitted by [streamUser], or `null` when signed out.
  ///
  /// Only kept up to date after [initialize] has been called. Synchronous,
  /// so it is safe to read from route guards and build methods.
  T? currentUser;

  /// Registers this as [instance] and starts listening to [streamUser],
  /// keeping [currentUser] in sync and calling [onUserChanged].
  ///
  /// Call once at app start, before reading [currentUser].
  @mustCallSuper
  void initialize() {
    instance = this;
    streamUser().listen(
      (event) {
        currentUser = event;
        log('Auth User Stream $event', name: '🦋 Auth Management', level: 800);
        onUserChanged(event);
      },
      onError: onUserError,
    );
  }

  /// Local cache for the signed-in user.
  AuthManagementDatabaseRepository<T> get dbRepo;

  /// Optional state-management bridge (for example Riverpod).
  AuthServiceProviderRepository<T>? get providerRepo => null;

  /// Clears the cached user and the provider state.
  FutureOr<void> signOut() async {
    await dbRepo.clearUser();
    await providerRepo?.clearUser();
  }

  /// Emits the signed-in user, or `null` when signed out.
  Stream<T?> streamUser() {
    return dbRepo.streamUser();
  }

  /// Returns the signed-in user, or `null` when signed out.
  ///
  /// This is the method app code should call to read the user.
  FutureOr<T?> getUser() {
    return dbRepo.getUser();
  }

  /// Called after [currentUser] changes. Override to react, for example to
  /// notify a router.
  void onUserChanged(T? user) {}

  /// Called when [streamUser] emits an error, for example when
  /// [IdentityAuthRepository.fetchUser] throws.
  ///
  /// [currentUser] keeps its previous value. Logs by default; override to
  /// report or recover.
  void onUserError(Object error, StackTrace stackTrace) {
    log(
      'Auth User Stream error',
      name: '🦋 Auth Management',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
