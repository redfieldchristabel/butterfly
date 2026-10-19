# auth_management_database_sembast

[Sembast](https://pub.dev/packages/sembast) storage for `auth_management`. It
caches the signed-in user as one JSON record in your app's Sembast database.

Your user model needs no base class, adapter or schema, only `fromJson` and
`toJson`. If your app already uses Sembast, the user lives in the same
database, in its own store.

## Usage

```dart
final userDbRepo = AuthManagementDatabaseSembast<AppUser>(
  fromJson: AppUser.fromJson,
  toJson: (user) => user.toJson(),
);

class AuthService extends FirebaseAuthManagementRepository<AppUser> {
  @override
  AuthManagementDatabaseRepository<AppUser> get dbRepo => userDbRepo;

  // fetchUser...
}

final authService = AuthService();

Future<void> main() async {
  final dir = await getApplicationDocumentsDirectory();
  final db = await databaseFactoryIo.openDatabase(join(dir.path, 'app.db'));

  userDbRepo.initialize(db); // before authService.initialize()
  authService.initialize();
  // runApp...
}
```

## Notes

- `initialize(db)` only attaches the database. The repository never opens or
  closes it, so your app keeps ownership.
- `toJson` must return values Sembast can store: `String`, `num`, `bool`,
  `null`, and lists or maps of those. Convert `DateTime` to a string or a
  Sembast `Timestamp`. With json_serializable, set `explicitToJson: true` for
  nested models.
- The user goes into the `auth_management_user` store. Pass `storeName` if
  that clashes with one of yours.
