import 'dart:async';

abstract interface class AuthServiceRepository<T> {
  FutureOr<void> addUser(T user);

  FutureOr<void> clearUser();

  Stream<T> streamUser();

  FutureOr<T?> getUser();
}

