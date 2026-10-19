import 'package:auth_management/auth_management.dart';
import 'package:auth_management_provider_riverpod/auth_management_provider_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _User with RiverpodUser {
  _User(this.name);
  final String name;
}

class _Auth extends AuthServiceRepository<_User> {
  @override
  final dbRepo = InMemoryDatabaseRepository<_User>();

  @override
  final AuthManagementRiverpodRepository<_User> providerRepo =
      AuthManagementRiverpodRepository<_User>();
}

final _auth = _Auth()..initialize();

/// The root widget is a plain ConsumerWidget that initializes in build.
class _App extends ConsumerWidget {
  const _App();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _auth.providerRepo.initialize(ref);
    final user = ref.watch(riverpodUserStateProvider) as _User?;
    return Text(user?.name ?? 'signed out', textDirection: TextDirection.ltr);
  }
}

void main() {
  testWidgets('initialize(ref) inside a root ConsumerWidget build is safe', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: _App()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('signed out'), findsOneWidget);

    _auth.dbRepo.addUser(_User('Ali'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Ali'), findsOneWidget);

    await _auth.signOut();
    await tester.pump();
    await tester.pump();
    expect(find.text('signed out'), findsOneWidget);
  });
}
