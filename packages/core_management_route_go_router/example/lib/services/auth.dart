import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:go_router_example/models/user.dart';

class AuthService extends AuthServiceRepository<User> with ChangeNotifier {
  final iDbRepo = InMemoryDatabaseRepository<User>();

  @override
  AuthManagementDatabaseRepository<User> get dbRepo => iDbRepo;

  void signIn() {
    final user = User(1);
    dbRepo.addUser(user);
  }

  @override
  void onUserChanged(User? user) {
    notifyListeners();
  }

  @override
  FutureOr<User> fetchUser() {
    // TODO: actual api call
    return User(1);
  }
}

final authService = AuthService();
