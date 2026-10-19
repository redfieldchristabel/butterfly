import 'package:auth_management_database_sembast/auth_management_database_sembast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

class _User {
  final String id;
  final int coins;

  _User(this.id, this.coins);

  factory _User.fromJson(Map<String, Object?> json) =>
      _User(json['id'] as String, json['coins'] as int);

  Map<String, Object?> toJson() => {'id': id, 'coins': coins};
}

AuthManagementDatabaseSembast<_User> _repo({
  String storeName = AuthManagementDatabaseSembast.defaultStoreName,
}) => AuthManagementDatabaseSembast<_User>(
  fromJson: _User.fromJson,
  toJson: (user) => user.toJson(),
  storeName: storeName,
);

void main() {
  late Database db;
  late AuthManagementDatabaseSembast<_User> repo;

  setUp(() async {
    db = await newDatabaseFactoryMemory().openDatabase('test.db');
    repo = _repo()..initialize(db);
  });

  tearDown(() => db.close());

  test('getUser returns null when nothing is stored', () async {
    expect(await repo.getUser(), isNull);
  });

  test('addUser then getUser round-trips the user', () async {
    await repo.addUser(_User('a', 10));

    final user = await repo.getUser();

    expect(user?.id, 'a');
    expect(user?.coins, 10);
  });

  test('addUser replaces the previous user', () async {
    await repo.addUser(_User('a', 10));
    await repo.addUser(_User('b', 20));

    expect((await repo.getUser())?.id, 'b');
  });

  test('clearUser removes the user', () async {
    await repo.addUser(_User('a', 10));
    await repo.clearUser();

    expect(await repo.getUser(), isNull);
  });

  test('streamUser emits the current value, then every change', () async {
    final events = <String?>[];
    final subscription = repo.streamUser().listen((u) => events.add(u?.id));
    await pumpEventQueue();

    await repo.addUser(_User('a', 10));
    await pumpEventQueue();
    await repo.clearUser();
    await pumpEventQueue();
    await subscription.cancel();

    expect(events, [null, 'a', null]);
  });

  test('stores separately per storeName', () async {
    final other = _repo(storeName: 'other_user')..initialize(db);

    await repo.addUser(_User('a', 10));

    expect(await other.getUser(), isNull);
  });

  test('throws a StateError when used before initialize', () {
    expect(() => _repo().getUser(), throwsStateError);
  });
}
