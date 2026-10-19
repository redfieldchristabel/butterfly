import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:flutter_test/flutter_test.dart';

class _User {
  final String uid;
  final int coins;

  _User(this.uid, this.coins);
}

class _FakeAuth extends IdentityAuthRepository<String, _User> {
  final _db = InMemoryDatabaseRepository<_User>();
  final _identities = StreamController<String?>.broadcast();

  String? identity;
  int fetchCount = 0;
  int remoteCoins = 10;
  Object? fetchError;

  void signInAs(String? uid) {
    identity = uid;
    _identities.add(uid);
  }

  @override
  AuthManagementDatabaseRepository<_User> get dbRepo => _db;

  @override
  Stream<String?> streamIdentity() async* {
    yield identity;
    yield* _identities.stream;
  }

  @override
  String? getIdentity() => identity;

  @override
  Future<_User> fetchUser(String uid) async {
    fetchCount++;
    await Future<void>.delayed(Duration.zero);
    final error = fetchError;
    if (error != null) throw error;
    return _User(uid, remoteCoins);
  }

  @override
  bool isCachedUserFor(_User cachedUser, String uid) => cachedUser.uid == uid;
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeAuth auth;

  setUp(() => auth = _FakeAuth());

  group('getUser', () {
    test('returns null without fetching when signed out', () async {
      expect(await auth.getUser(), isNull);
      expect(auth.fetchCount, 0);
    });

    test('fetches once, then serves the cache', () async {
      auth.identity = 'a';

      final first = await auth.getUser();
      final second = await auth.getUser();

      expect(first?.uid, 'a');
      expect(second?.uid, 'a');
      expect(auth.fetchCount, 1);
      expect((await auth.dbRepo.getUser())?.uid, 'a');
    });

    test('concurrent calls share one fetch', () async {
      auth.identity = 'a';

      await Future.wait([auth.getUser(), auth.getUser()]);

      expect(auth.fetchCount, 1);
    });

    test('refetches when a different account signs in', () async {
      auth.identity = 'a';
      await auth.getUser();

      auth.identity = 'b';
      final user = await auth.getUser();

      expect(user?.uid, 'b');
      expect(auth.fetchCount, 2);
    });
  });

  group('streamUser', () {
    test('follows sign-in and sign-out, clearing the cache', () async {
      final events = <String?>[];
      auth.streamUser().listen((u) => events.add(u?.uid));
      await _settle();

      auth.signInAs('a');
      await _settle();
      auth.signInAs(null);
      await _settle();

      expect(events, [null, 'a', null]);
      expect(await auth.dbRepo.getUser(), isNull);
    });

    test('late subscribers get the latest user immediately', () async {
      auth.streamUser().listen((_) {});
      auth.signInAs('a');
      await _settle();

      final lateUser = await auth.streamUser().first;

      expect(lateUser?.uid, 'a');
      expect(auth.fetchCount, 1);
    });

    test('surfaces fetch errors and keeps listening', () async {
      final users = <String?>[];
      final errors = <Object>[];
      auth.streamUser().listen((u) => users.add(u?.uid), onError: errors.add);
      await _settle();

      auth.fetchError = StateError('profile missing');
      auth.signInAs('a');
      await _settle();

      expect(errors, hasLength(1));

      auth.fetchError = null;
      auth.signInAs('a');
      await _settle();

      expect(users, [null, 'a']);
    });
  });

  group('refreshUser', () {
    test('bypasses the cache and pushes the new user to streamUser', () async {
      final coins = <int?>[];
      auth.streamUser().listen((u) => coins.add(u?.coins));
      auth.signInAs('a');
      await _settle();

      auth.remoteCoins = 99;
      final refreshed = await auth.refreshUser();
      await _settle();

      expect(refreshed?.coins, 99);
      expect(coins.last, 99);
      expect((await auth.dbRepo.getUser())?.coins, 99);
      expect(auth.fetchCount, 2);
    });

    test('returns null when signed out', () async {
      expect(await auth.refreshUser(), isNull);
      expect(auth.fetchCount, 0);
    });
  });
}
