import 'package:auth_management/auth_management.dart';
import 'package:auth_management_database_sembast/auth_management_database_sembast.dart';
import 'package:sembast/sembast_memory.dart';

class AppUser {
  final String id;
  final String name;

  AppUser({required this.id, required this.name});

  factory AppUser.fromJson(Map<String, Object?> json) =>
      AppUser(id: json['id'] as String, name: json['name'] as String);

  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

final userDbRepo = AuthManagementDatabaseSembast<AppUser>(
  fromJson: AppUser.fromJson,
  toJson: (user) => user.toJson(),
);

class AuthService extends AuthServiceRepository<AppUser> {
  @override
  AuthManagementDatabaseRepository<AppUser> get dbRepo => userDbRepo;

  // Your sign-in flow returns the full user, so store it yourself. With an
  // identity provider (Firebase, OAuth2) the library stores it for you.
  Future<void> signIn() async {
    await dbRepo.addUser(AppUser(id: '1', name: 'Ali'));
  }
}

final authService = AuthService();

Future<void> main() async {
  // Use databaseFactoryIo (sembast/sembast_io.dart) for a file on disk.
  final db = await databaseFactoryMemory.openDatabase('app.db');
  userDbRepo.initialize(db);
  authService.initialize();

  await authService.signIn();
  final user = await authService.getUser();
  // ignore: avoid_print
  print('Signed in as ${user?.name}');
}
