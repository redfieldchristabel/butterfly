import 'dart:async';

import 'package:auth_management/auth_management_provider.dart';
import 'package:auth_management_provider_riverpod/src/user.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuthManagementRiverpodRepository<T extends RiverpodUser>
    implements AuthServiceProviderRepository<T> {
  late final WidgetRef ref;

  void initialize(WidgetRef ref) {
    this.ref = ref;
  }

  @override
  FutureOr<void> bindUserToProvider(user) {
    ref.read(riverpodUserStateProvider.notifier).linkUser(user);
  }

  @override
  FutureOr<void> clearUser() {
    ref.read(riverpodUserStateProvider.notifier).clearUser();
  }

  @override
  FutureOr<T?> getUser() {
    return ref.read(riverpodUserStateProvider) as T?;
  }
}
