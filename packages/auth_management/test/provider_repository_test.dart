import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:auth_management/auth_management_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider package as small as it gets: three methods and an initialize.
class _RecordingProvider extends AuthServiceProviderRepository<String> {
  final calls = <String>[];
  String? held;

  Future<void> initialize() => markInitialized();

  @override
  void bindUserToProvider(String user) {
    calls.add('bind $user');
    held = user;
  }

  @override
  void clearUser() {
    calls.add('clear');
    held = null;
  }

  @override
  String? getUser() => held;
}

class _Auth extends AuthServiceRepository<String> {
  final _users = StreamController<String?>.broadcast();
  String? stored;

  @override
  final AuthManagementDatabaseRepository<String> dbRepo =
      InMemoryDatabaseRepository<String>();

  @override
  final _RecordingProvider providerRepo = _RecordingProvider();

  @override
  Stream<String?> streamUser() => _users.stream;

  void emit(String? user) => _users.add(user);
}

void main() {
  test('sync holds only the latest change until initialized', () async {
    final provider = _RecordingProvider();
    await provider.sync('a');
    await provider.sync('b');
    expect(provider.calls, isEmpty);

    await provider.initialize();
    expect(provider.calls, ['bind b']);

    await provider.sync(null);
    expect(provider.calls, ['bind b', 'clear']);
  });

  test('a pending sign-out is delivered as a clear', () async {
    final provider = _RecordingProvider();
    await provider.sync('a');
    await provider.sync(null);
    await provider.initialize();
    expect(provider.calls, ['clear']);
  });

  test('auth service publishes every change and clears on sign-out', () async {
    final auth = _Auth()..initialize();
    await auth.providerRepo.initialize();

    auth.emit('ali');
    await pumpEventQueue();
    expect(auth.providerRepo.held, 'ali');

    auth.emit('siti');
    await pumpEventQueue();
    expect(auth.providerRepo.held, 'siti');

    await auth.signOut();
    expect(auth.providerRepo.held, isNull);
    expect(auth.providerRepo.calls, ['bind ali', 'bind siti', 'clear']);
  });
}
