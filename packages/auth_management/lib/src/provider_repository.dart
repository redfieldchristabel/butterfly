import 'dart:async';

import 'package:flutter/foundation.dart' show nonVirtual, protected;

/// Bridges the signed-in user into a state-management library (Riverpod,
/// Provider, BLoC...).
///
/// Return an instance from `AuthServiceRepository.providerRepo` and the auth
/// service keeps it in sync for you: every user change is forwarded through
/// [sync], which calls [bindUserToProvider] for a user and [clearUser] for
/// sign-out. Apps never call those two methods themselves.
///
/// A provider package only implements [bindUserToProvider], [clearUser] and
/// [getUser], plus an `initialize` that captures whatever handle it needs
/// (a `WidgetRef`, a `BuildContext`...) and then calls [markInitialized].
/// Changes that arrive before that are held and delivered by
/// [markInitialized], so it does not matter whether auth or the widget tree
/// is ready first.
abstract class AuthServiceProviderRepository<T> {
  /// Whether [markInitialized] has run. Before that, [sync] only remembers
  /// the latest user.
  bool initialized = false;

  T? _pendingUser;
  bool _hasPendingUser = false;

  /// Pushes [user] into the state-management library.
  ///
  /// Called by [sync]. Do not call it from app code.
  @protected
  FutureOr<void> bindUserToProvider(T user);

  /// Reads the user currently held by the state-management library.
  FutureOr<T?> getUser();

  /// Removes the user from the state-management library.
  ///
  /// Called by [sync] on sign-out. Do not call it from app code.
  @protected
  FutureOr<void> clearUser();

  /// Forwards a user change: [bindUserToProvider] for a user, [clearUser]
  /// for `null`.
  ///
  /// Called by `AuthServiceRepository` on every change. Before
  /// [markInitialized], only the latest change is kept and delivered later.
  @nonVirtual
  Future<void> sync(T? user) async {
    if (!initialized) {
      _pendingUser = user;
      _hasPendingUser = true;
      return;
    }

    if (user == null) {
      await clearUser();
    } else {
      await bindUserToProvider(user);
    }
  }

  /// Marks the bridge ready and delivers the latest change that arrived
  /// before it was.
  ///
  /// Provider packages call this at the end of their `initialize`.
  @protected
  @nonVirtual
  Future<void> markInitialized() async {
    initialized = true;
    if (!_hasPendingUser) return;

    final user = _pendingUser;
    _pendingUser = null;
    _hasPendingUser = false;
    await sync(user);
  }
}
