import 'dart:async';

import 'package:flutter/foundation.dart' show protected, visibleForOverriding;

import 'repository.dart';

/// An [AuthServiceRepository] for providers that know **who** the user is,
/// but not **what** your app knows about them.
///
/// Most auth providers only hand you an identity [I]: a uid, an email, a
/// token. Firebase Auth gives you a `User`, OAuth2 gives you credentials,
/// Supabase gives you an `auth.users` row. Your app's user model [T] (role,
/// coins, plan, profile...) lives somewhere else: Firestore, MySQL, your API.
///
/// This class joins the two. Every time the identity changes it resolves
/// the matching [T]:
///
/// 1. No identity (signed out): clears the cache and emits `null`.
/// 2. A cached user in [dbRepo] that [isCachedUserFor] the identity: emits
///    it. No network call, works offline.
/// 3. Otherwise: calls [fetchUser], saves the result to [dbRepo], emits it.
///
/// Provider packages (Firebase, OAuth2...) implement [streamIdentity] and
/// [getIdentity]. Your app implements [fetchUser] and reads the user with
/// [getUser], [streamUser] or [currentUser], the same way for every
/// provider.
abstract class IdentityAuthRepository<I, T> extends AuthServiceRepository<T> {
  final StreamController<T?> _users = StreamController<T?>.broadcast();
  StreamSubscription<T?>? _identitySubscription;
  T? _latestUser;
  bool _hasLatestUser = false;
  Future<T>? _pendingFetch;

  /// Emits the provider's identity, or `null` when signed out.
  ///
  /// Must emit the current identity when listened to, then every change.
  /// Implemented by provider packages, not by apps.
  @protected
  Stream<I?> streamIdentity();

  /// Returns the provider's current identity, or `null` when signed out.
  ///
  /// Implemented by provider packages, not by apps.
  @protected
  FutureOr<I?> getIdentity();

  /// Loads your app's user model [T] for [identity].
  ///
  /// **You implement this.** Load whatever the provider doesn't store
  /// (role, coins, profile...) from Firestore, MySQL, an API, and build [T].
  ///
  /// ## When it's called
  /// Only when there is an identity and [dbRepo] has no cached user for it:
  /// * the first sign-in on a device,
  /// * a different account signs in (see [isCachedUserFor]),
  /// * [refreshUser] is called.
  ///
  /// Once the result is cached it is not called again, including on app
  /// restarts, until sign-out or [refreshUser].
  ///
  /// ## Contract
  /// * Don't write to [dbRepo]. The result is cached for you.
  /// * Don't call [getUser], [streamUser] or [refreshUser] from here.
  /// * If this throws, [streamUser] emits the error, [getUser] throws it and
  ///   [currentUser] keeps its previous value (see [onUserError]). The next
  ///   identity change or [refreshUser] tries again.
  @protected
  @visibleForOverriding
  FutureOr<T> fetchUser(I identity);

  /// Whether [cachedUser] belongs to [identity].
  ///
  /// Return `false` to discard the cache and call [fetchUser], for example
  /// when a different account signed in without signing out first.
  /// Defaults to `true` (trust the cache). Provider packages override this
  /// when the identity has a stable id.
  @protected
  FutureOr<bool> isCachedUserFor(T cachedUser, I identity) => true;

  @override
  Stream<T?> streamUser() {
    _identitySubscription ??= streamIdentity()
        .asyncMap(_resolve)
        .listen(_emit, onError: _users.addError);

    late final StreamController<T?> controller;
    StreamSubscription<T?>? subscription;
    controller = StreamController<T?>(
      onListen: () {
        if (_hasLatestUser) controller.add(_latestUser);
        subscription =
            _users.stream.listen(controller.add, onError: controller.addError);
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  @override
  Future<T?> getUser() async => _resolve(await getIdentity());

  /// Ignores the cache, calls [fetchUser] again and emits the result.
  ///
  /// Call this when the user's data changed outside the app, for example
  /// after a purchase updates their coins or an admin changes their role.
  /// Returns `null` when signed out, or when the account changed while
  /// fetching.
  Future<T?> refreshUser() async {
    final identity = await getIdentity();
    if (identity == null) return null;

    final user = await fetchUser(identity);

    final current = await getIdentity();
    if (current == null || !await isCachedUserFor(user, current)) return null;

    await dbRepo.addUser(user);
    _emit(user);
    return user;
  }

  void _emit(T? user) {
    _latestUser = user;
    _hasLatestUser = true;
    _users.add(user);
  }

  Future<T?> _resolve(I? identity) async {
    if (identity == null) {
      await dbRepo.clearUser();
      return null;
    }

    final cached = await dbRepo.getUser();
    if (cached != null && await isCachedUserFor(cached, identity)) {
      return cached;
    }

    var user = await _fetchShared(identity);
    if (!await isCachedUserFor(user, identity)) {
      // The shared fetch was started for a different account.
      user = await fetchUser(identity);
    }

    await dbRepo.addUser(user);
    return user;
  }

  /// Lets [getUser] and [streamUser] share one [fetchUser] call when both
  /// resolve at the same time, for example right after sign-in.
  Future<T> _fetchShared(I identity) {
    final pending = _pendingFetch;
    if (pending != null) return pending;

    final fetch = Future<T>.sync(() => fetchUser(identity));
    _pendingFetch = fetch;
    fetch.whenComplete(() {
      if (identical(_pendingFetch, fetch)) _pendingFetch = null;
    }).ignore();
    return fetch;
  }
}
