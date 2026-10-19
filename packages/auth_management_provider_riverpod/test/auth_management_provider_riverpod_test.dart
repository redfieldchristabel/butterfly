import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:auth_management/auth_management_provider.dart';
import 'package:auth_management_provider_riverpod/auth_management_provider_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _User with RiverpodUser {
  _User(this.name);
  final String name;
}

/// Emits the stored user on listen, then every change.
class _Db implements AuthManagementDatabaseRepository<_User> {
  _User? user;
  final _changes = StreamController<_User?>.broadcast();

  @override
  _User? getUser() => user;

  @override
  void addUser(_User user) {
    this.user = user;
    _changes.add(user);
  }

  @override
  void clearUser() {
    user = null;
    _changes.add(null);
  }

  @override
  Stream<_User?> streamUser() async* {
    yield user;
    yield* _changes.stream;
  }
}

final riverpodProvider = AuthManagementRiverpodRepository<_User>();

class _Auth extends AuthServiceRepository<_User> {
  _Auth(this.dbRepo);

  @override
  final _Db dbRepo;

  @override
  AuthServiceProviderRepository<_User> get providerRepo => riverpodProvider;
}

// One auth service per isolate: AuthServiceRepository.instance is late final.
final _db = _Db();
final _auth = _Auth(_db)..initialize();

class _App extends ConsumerStatefulWidget {
  const _App();

  @override
  ConsumerState<_App> createState() => _AppState();
}

class _AppState extends ConsumerState<_App> {
  @override
  void initState() {
    super.initState();
    riverpodProvider.initialize(ref);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(riverpodUserStateProvider) as _User?;
    return Text(user?.name ?? 'signed out', textDirection: TextDirection.ltr);
  }
}

void main() {
  testWidgets(
    'publishes and clears the user with no app wiring beyond initialize',
    (tester) async {
      // A persisted session, then auth.initialize() in main() before runApp:
      // the user resolves before the widget tree (and the bridge) exists.
      _db.addUser(_User('Ali'));
      _auth; // first access runs initialize()
      await tester.pump();
      expect(_auth.currentUser?.name, 'Ali');
      expect(riverpodProvider.initialized, isFalse);

      await tester.pumpWidget(const ProviderScope(child: _App()));
      await tester.pump();
      expect(find.text('Ali'), findsOneWidget);

      // Later sign-in changes flow through automatically.
      _db.addUser(_User('Siti'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Siti'), findsOneWidget);

      // Base signOut clears provider state too.
      await _auth.signOut();
      await tester.pump();
      await tester.pump();
      expect(find.text('signed out'), findsOneWidget);
      expect(await _auth.providerRepo.getUser(), isNull);

      // Repeated initialize is ignored rather than throwing.
      final state = tester.state<_AppState>(find.byType(_App));
      riverpodProvider.initialize(state.ref);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
