import 'dart:async';

import 'package:auth_management/auth_management_provider.dart';
import 'package:auth_management_provider_riverpod/src/user.dart';
import 'package:riverpod/riverpod.dart';

class AuthManagementIsarRepository<T extends RiverpodUser>
    implements AuthServiceProviderRepository<T> {
  late final Ref ref;

  void initialize(Ref ref) {
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
