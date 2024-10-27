import 'dart:async';

import 'package:auth_management_database_isar_community/auth_management_database_isar_community.dart';
import 'package:flutter/material.dart';

import 'package:auth_management/auth_management.dart';
import 'package:isar/isar.dart';

part 'main.g.dart';

final dbRepo = AuthManagementIsarRepository<MyUser>();
final authManagement = MockAuthManagement(dbRepo);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dbRepo.initialize(MyUserSchema);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const IsarExample(),
    );
  }
}

class IsarExample extends StatelessWidget {
  const IsarExample({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: StreamBuilder<MyUser?>(
            stream: authManagement.streamUser(),
            builder: (context, snapshot) {
              return Text('Isar Example, ${snapshot.data?.id}');
            }),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          authManagement.signIn();
        },
      ),
    );
  }
}

@collection
class MyUser extends BaseUser {
  MyUser({required super.id});
}

class MockAuthManagement implements AuthServiceRepository {
  final AuthManagementIsarRepository<MyUser> dbRepo;

  MockAuthManagement(this.dbRepo);

  void signIn() {
    dbRepo.addUser(MyUser(id: 1));
  }

  @override
  FutureOr getUser() {
    return dbRepo.getUser();
  }

  @override
  FutureOr<void> signOut() {
    dbRepo.clearUser();
  }

  @override
  Stream<MyUser?> streamUser() {
    return dbRepo.streamUser();
  }
}
