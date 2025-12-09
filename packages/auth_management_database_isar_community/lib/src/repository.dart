import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../auth_management_database_isar_community.dart';

class AuthManagementIsarRepository<T extends BaseUser>
    implements AuthManagementDatabaseRepository<T> {
  late final CollectionSchema schema;
  late final Isar isar;
  late final IsarCollection collection;

  Future<void> initialize(
    CollectionSchema userSchema, {
    List<CollectionSchema> schemas = const [],
  }) async {
    schema = userSchema;

    final initializeSchemas = [schema, ...schemas];
    if (kIsWeb) {
      // For web, make sure to initialize before
      throw Exception(
          'Web is not supported yet. Please use other auth management database provider.');
      // await Isar.initialize();
      //
      // // Use sync methods
      // isar = Isar.openSync(
      //   initializeSchemas,
      //   directory: ,
      // );
    } else {
      final dir = await getApplicationDocumentsDirectory();
      isar = await Isar.open(
        initializeSchemas,
        directory: dir.path,
      );
    }

    collection = isar.collection<T>();
  }

  @override
  FutureOr<void> addUser(T user) {
    // TODO: find a way to save user from library
    // isar.writeSync((isar) => collection.put(user));

    isar.writeTxnSync(
      () {
        collection.putSync(user);
      },
    );
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
