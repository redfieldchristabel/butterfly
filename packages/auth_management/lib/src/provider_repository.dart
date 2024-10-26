import 'dart:async';

import 'package:auth_management/auth_management.dart';

abstract interface class AuthServiceProviderRepository<T>
    implements AuthServiceRepository<T> {
  FutureOr<void> bindUserToProvider(T user);
}
