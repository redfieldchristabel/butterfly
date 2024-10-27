import 'dart:async';

abstract interface class AuthServiceRepository<T> {
  FutureOr<void> signOut();

  Stream<T?> streamUser();

  FutureOr<T?> getUser();
}
