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
  late final IsarCollection collection;

  Future<void> initialize(
    IsarGeneratedSchema userSchema, {
    List<IsarGeneratedSchema> schemas = const [],
  }) async {
    schema = userSchema;

    final initializeSchemas = [schema, ...schemas];
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

    collection = isar.collection<int,T>();
  }

  @override
  FutureOr<void> addUser(T user) {
    // TODO: find a way to save user from library
    isar.write((isar) => collection.put(user));

  }

  @override
  FutureOr<void> clearUser() {
    collection.clear();
  }

  @override
  FutureOr<T?> getUser() {
    final user = isar.collection().where().findFirst();
    return user as T?;
  }

  @override
  Stream<T?> streamUser() async* {
    final stream = collection.where().build().watch();
    await for (final event in stream) {
      final user = event.firstOrNull;

      if (user != null) {
        yield user as T;
      } else {
        yield null;
      }
    }
  }
}
