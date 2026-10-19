import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:sembast/sembast.dart';

/// Caches the signed-in user in a [Sembast](https://pub.dev/packages/sembast)
/// database.
///
/// The user is stored as one JSON record in its own store, so it can share
/// the database your app already uses for everything else:
///
/// ```dart
/// final userDbRepo = AuthManagementDatabaseSembast<AppUser>(
///   fromJson: AppUser.fromJson,
///   toJson: (user) => user.toJson(),
/// );
///
/// Future<void> main() async {
///   final db = await databaseFactoryIo.openDatabase('app.db');
///   userDbRepo.initialize(db);
///   authService.initialize();
///   // ...
/// }
///
/// class AuthService extends FirebaseAuthManagementRepository<AppUser> {
///   @override
///   AuthManagementDatabaseRepository<AppUser> get dbRepo => userDbRepo;
///   // ...
/// }
/// ```
///
/// Unlike Hive or Isar, your model needs no base class, adapter or schema:
/// only [fromJson] and [toJson].
class AuthManagementDatabaseSembast<T>
    implements AuthManagementDatabaseRepository<T> {
  /// Creates the repository. Call [initialize] before using it.
  ///
  /// [storeName] is the Sembast store that holds the user. Change it only if
  /// [defaultStoreName] clashes with one of your own stores.
  AuthManagementDatabaseSembast({
    required this.fromJson,
    required this.toJson,
    String storeName = defaultStoreName,
  }) : _record = StoreRef<String, Map<String, Object?>>(
         storeName,
       ).record(_recordKey);

  /// The store used when no `storeName` is given.
  static const String defaultStoreName = 'auth_management_user';
  static const String _recordKey = 'current';

  /// Builds your user model from the stored JSON.
  final T Function(Map<String, Object?> json) fromJson;

  /// Turns your user model into JSON for storage.
  ///
  /// Values must be types Sembast can store: `String`, `num`, `bool`,
  /// `null`, and `List` / `Map` of those. Convert `DateTime` to a string or
  /// a Sembast `Timestamp`, and nested models to maps (with
  /// json_serializable, set `explicitToJson: true`).
  final Map<String, Object?> Function(T user) toJson;

  final RecordRef<String, Map<String, Object?>> _record;
  Database? _database;

  /// Attaches the Sembast [database] to store the user in.
  ///
  /// Call once at app start, after opening the database and before
  /// `AuthServiceRepository.initialize`. The repository never opens or
  /// closes the database itself.
  void initialize(Database database) {
    _database = database;
  }

  /// The attached database.
  ///
  /// Throws a [StateError] if [initialize] hasn't been called yet.
  Database get database =>
      _database ??
      (throw StateError(
        'AuthManagementDatabaseSembast is not initialized. '
        'Call initialize(database) at app start before using it.',
      ));

  @override
  Future<void> addUser(T user) async {
    await _record.put(database, toJson(user));
  }

  @override
  Future<void> clearUser() async {
    await _record.delete(database);
  }

  @override
  Future<T?> getUser() async {
    final json = await _record.get(database);
    return json == null ? null : fromJson(json);
  }

  /// Emits the stored user right away, then on every change. Emits `null`
  /// when there is no user.
  @override
  Stream<T?> streamUser() {
    return _record
        .onSnapshot(database)
        .map((snapshot) => snapshot == null ? null : fromJson(snapshot.value));
  }
}
