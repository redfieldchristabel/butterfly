import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../auth_management_database_isar_community.dart';

class AuthManagementIsarRepository<T extends BaseUser>
    implements AuthManagementDatabaseRepository<T> {
  late final IsarGeneratedSchema schema;
  late final Isar isar;

  Future<void> initialize( IsarGeneratedSchema userSchema ,{
    List<IsarGeneratedSchema> schemas = const [],
  }) async {
    schema = userSchema;

    final initializeSchemas = [schema,...schemas];
    if (kIsWeb) {
      // For web, make sure to initialize before
      await Isar.initialize();

      // Use sync methods
      isar = Isar.open(
        schemas: initializeSchemas,
        directory: Isar.sqliteInMemory,
        engine: IsarEngine.sqlite,
      );
    } else {
      final dir = await getApplicationDocumentsDirectory();
      isar = await Isar.openAsync(
        schemas: initializeSchemas,
        directory: dir.path,
      );
    }
  }

  @override
  FutureOr<void> addUser(T user) {
    // TODO: find a way to save user from library
    isar.write((isar) => );
  }

  @override
  FutureOr<void> clearUser() {
    isar.baseUsers.clear();
  }

  @override
  FutureOr<T?> getUser() {
    final user = isar.baseUsers.where().findFirst();
    return user as T?;
  }

  Stream<T?> streamUser() async* {
    final stream = isar.baseUsers.where().build().watch();
    await for (final event in stream) {
      final user = event.firstOrNull;

      if (user != null) {
        print(user);
        yield user as T;
      } else {
        yield null;
      }
    }
  }
}
