import 'dart:async';

abstract interface class AuthServiceProviderRepository<T> {
  FutureOr<void> bindUserToProvider(T user);

  FutureOr<T?> getUser();

  FutureOr<void> clearUser();
}
