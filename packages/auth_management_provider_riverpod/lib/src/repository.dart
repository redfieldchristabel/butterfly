import 'dart:async';

import 'package:auth_management/auth_management_provider.dart';
import 'package:auth_management_provider_riverpod/src/user.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Publishes the signed-in user to [riverpodUserStateProvider].
///
/// Return it from your auth service's `providerRepo`, then call [initialize]
/// once from your root widget. The auth service publishes and clears the user
/// for you from then on:
///
/// ```dart
/// final riverpodProvider = AuthManagementRiverpodRepository<AppUser>();
///
/// class AuthService extends AuthServiceRepository<AppUser> {
///   @override
///   AuthServiceProviderRepository<AppUser> get providerRepo =>
///       riverpodProvider;
///   // dbRepo, sign-in...
/// }
///
/// class App extends ConsumerStatefulWidget { /* ... */ }
///
/// class _AppState extends ConsumerState<App> {
///   @override
///   void initState() {
///     super.initState();
///     riverpodProvider.initialize(ref);
///   }
/// }
/// ```
class AuthManagementRiverpodRepository<T extends RiverpodUser>
    extends AuthServiceProviderRepository<T> {
  WidgetRef? _ref;

  /// Connects the bridge to Riverpod through [ref].
  ///
  /// Call once, from a widget that lives as long as the app (your root
  /// widget). Later calls are ignored. A user that signed in before this
  /// call is published right after it, outside the current build, so this is
  /// safe to call from `initState` or `build`.
  void initialize(WidgetRef ref) {
    if (_ref != null) return;
    _ref = ref;
    scheduleMicrotask(markInitialized);
  }

  WidgetRef get _requireRef =>
      _ref ??
      (throw StateError(
        'AuthManagementRiverpodRepository is not initialized. '
        'Call initialize(ref) from your root widget.',
      ));

  @override
  FutureOr<void> bindUserToProvider(T user) {
    _requireRef.read(riverpodUserStateProvider.notifier).linkUser(user);
  }

  @override
  FutureOr<void> clearUser() {
    _requireRef.read(riverpodUserStateProvider.notifier).clearUser();
  }

  @override
  FutureOr<T?> getUser() {
    return _ref?.read(riverpodUserStateProvider) as T?;
  }
}
