import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:auth_management/auth_management_provider.dart';

abstract class AuthServiceRepository<T> {
  final AuthManagementDatabaseRepository<T> dbRepo;

  final AuthServiceProviderRepository<T>? providerRepo;

  AuthServiceRepository({required this.dbRepo, this.providerRepo});

  FutureOr<void> signOut();

  Stream<T?> streamUser();

  FutureOr<T?> getUser();
}
