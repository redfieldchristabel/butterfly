import 'dart:async';
import 'dart:developer';

import 'package:auth_management/auth_management.dart';
import 'package:auth_management/auth_management_provider.dart';

abstract class AuthServiceRepository<T> {
  static late final AuthServiceRepository instance;

  T? currentUser;

  void initialize() {
    instance = this;
    streamUser().listen((event) {
      currentUser = event;
      log('Auth User Stream $event', name: '🦋 Auth Management', level: 800);
      onUserChanged(event);
    });
  }

  AuthManagementDatabaseRepository<T> get dbRepo;

  AuthServiceProviderRepository<T>? get providerRepo => null;

  FutureOr<void> signOut() {
    dbRepo.clearUser();
    providerRepo?.clearUser();
  }

  Stream<T?> streamUser() {
    return dbRepo.streamUser();
  }

  FutureOr<T?> getUser() {
    return dbRepo.getUser();
  }

  void onUserChanged(T? user) {}
}
