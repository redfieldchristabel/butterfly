import 'dart:async';

import 'package:flutter/cupertino.dart';

abstract class AuthServiceProviderRepository<T> {
  bool initialized = false;

  FutureOr<void> bindUserToProvider(T user);

  FutureOr<T?> getUser();

  FutureOr<void> clearUser();
}
