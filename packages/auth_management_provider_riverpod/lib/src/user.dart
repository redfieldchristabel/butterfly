import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'user.g.dart';

mixin RiverpodUser {}

@riverpod
class RiverpodUserState extends _$RiverpodUserState {
  @override
  RiverpodUser? build() => null;

  void linkUser(RiverpodUser user) {
    state = user;
  }

  void clearUser() {
    state = null;
  }
}
