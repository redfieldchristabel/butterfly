import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../auth_management.dart' show AuthManagementDatabaseRepository;

class InMemoryDatabaseRepository<T>
    implements AuthManagementDatabaseRepository<T> {
  final ValueNotifier<T?> iDb = ValueNotifier(null);

  @override
  FutureOr<void> addUser(T user) {
    iDb.value = user;
  }

  @override
  FutureOr<void> clearUser() {
    iDb.value = null;
  }

  @override
  FutureOr<T?> getUser() {
    return iDb.value;
  }

  @override
  Stream<T?> streamUser() {
    final controller = StreamController<T?>();
    iDb.addListener(() {
      controller.add(iDb.value);
    });

    return controller.stream;
  }
}
