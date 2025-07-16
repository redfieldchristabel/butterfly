import 'dart:async';

abstract interface class AuthManagementDatabaseRepository<T> {
  static late final AuthManagementDatabaseRepository instance;

  AuthManagementDatabaseRepository() {
    instance = this;
  }

  FutureOr<T?> getUser();

  FutureOr<void> addUser(T user);

  FutureOr<void> clearUser();

  Stream<T?> streamUser();
}
