import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:path_provider/path_provider.dart';

import 'base_user.dart';

class AuthManagementDatabaseHiveCe<T extends BaseUser>
    implements AuthManagementDatabaseRepository<T> {
  static const String boxName = 'currentUser';

  Future<void> initialize() async {
    final path = await getApplicationDocumentsDirectory();
    await Hive.openBox<T>(boxName, path: path.path);
  }

  @override
  FutureOr<void> addUser(T user) {
    final box = Hive.box<T>(boxName);
    box.put(0, user);
  }

  @override
  FutureOr<void> clearUser() {
    final box = Hive.box<T>(boxName);
    box.clear();
  }

  @override
  FutureOr<T?> getUser() {
    final box = Hive.box<T>(boxName);
    return box.get(0);
  }

@override
Stream<T?> streamUser() {
  final box = Hive.box<T>(boxName);
  return Stream<T?>.multi((controller) {
    // Emit the initial value
    controller.add(box.get(0));

    // Listen for changes and emit them
    final subscription = box.watch(key: 0).listen((event) {
      if (event.value == null) {
        controller.add(null);
      } else {
        controller.add(event.value as T);
      }
    });

    // Cancel the subscription when the stream is closed
    controller.onCancel = () {
      subscription.cancel();
    };
  });
}
}
