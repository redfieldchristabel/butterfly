import 'dart:async';

import 'package:auth_management_database_hive_ce/base_user.dart';
import 'package:flutter/material.dart';
import 'package:auth_management_database_hive_ce/auth_management_database_hive_ce.dart';
import 'package:auth_management/auth_management.dart';
import 'package:hive_ce/hive.dart';
import 'hive/hive_registrar.g.dart';

// part 'main.g.dart';

final hiveCe = AuthManagementDatabaseHiveCe<User>();
final authManagement = AuthService(dbRepo: hiveCe);

class User extends BaseUser {
  final String id;

  User(this.id);
}

abstract class MockAuthManagement extends AuthServiceRepository<User> {
  MockAuthManagement({required super.dbRepo});

  void signIn() {
    final user = User('My Id');
    dbRepo.addUser(user);
  }

  @override
  FutureOr<User?> getUser() {
    return dbRepo.getUser();
  }

  @override
  FutureOr<void> signOut() {
    dbRepo.clearUser();
  }

  @override
  Stream<User?> streamUser() {
    return dbRepo.streamUser();
  }
}

class AuthService extends MockAuthManagement {
  AuthService({required super.dbRepo});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Hive.registerAdapters();
  await hiveCe.initialize();
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
      ),
      home: const HiveCeExample(),
    );
  }
}

class HiveCeExample extends StatelessWidget {
  const HiveCeExample({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: StreamBuilder<User?>(
          stream: authManagement.streamUser(),
          builder: (context, snapshot) {
            return Text('Isar Example, ${snapshot.data?.id}');
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          authManagement.signIn();
        },
      ),
    );
  }
}
