import 'dart:async';

abstract interface class AuthManagementDatabaseRepository<T> {
  FutureOr<T?> getUser();

  FutureOr<void> addUser(T user);

  FutureOr<void> clearUser();

  Stream<T?> streamUser();
}
