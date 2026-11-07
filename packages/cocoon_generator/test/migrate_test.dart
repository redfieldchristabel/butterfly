/// Tests for `dart run cocoon_generator:migrate`, driven with fake terminals
/// over throwaway packages in temp directories.
///
/// The throwaway packages get a hand-written `.dart_tool/package_config.json`
/// that points `package:cocoon` (and its dependency closure) at the real
/// workspace packages, so the analyzer resolves the models without a pub get.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:collection';
import 'dart:isolate';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_generator/migrate.dart';
import 'package:package_config/package_config.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The fake terminal of the most recent [migrate] call.
final FakeTerminal lastIo = FakeTerminal();

// -- Fake terminal -------------------------------------------------------------

final class FakeTerminal implements MigrateIo {
  @override
  bool stdinIsTerminal = false;
  @override
  bool stdoutIsTerminal = false;

  final StringBuffer out = StringBuffer();
  Queue<String> _lines = Queue<String>();

  /// Prepares the terminal for one [migrate] call.
  void reset(List<String> lines, {required bool tty}) {
    _lines = Queue<String>.of(lines);
    out.clear();
    stdinIsTerminal = tty;
    stdoutIsTerminal = tty;
  }

  @override
  String readLine() => _lines.isEmpty ? '' : _lines.removeFirst();

  @override
  void write(String text) => out.write(text);
}

// -- Throwaway packages ---------------------------------------------------------

const _neededPackages = [
  'cocoon',
  'meta',
  'sqlite_async',
  'sqlite3',
  'ffi',
  'path',
  'async',
  'collection',
  'web',
];

final Future<Map<String, String>> _packageRoots = _readPackageRoots();

Future<Map<String, String>> _readPackageRoots() async {
  final configUri = await Isolate.packageConfig;
  final config = await loadPackageConfigUri(configUri!);
  return {
    for (final name in _neededPackages)
      name: configUri
          .resolveUri(config.packages.firstWhere((p) => p.name == name).root)
          .toString(),
  };
}

final createdDirs = <Directory>[];

Future<Directory> tempPackage({
  required String models,
  String? lock,
  String? extraFile,
  String? extraContent,
}) async {
  final dir = await Directory.systemTemp.createTemp('cocoon_migrate_pkg');
  createdDirs.add(dir);
  File(
    '${dir.path}/pubspec.yaml',
  ).writeAsStringSync('name: migrate_test_pkg\nenvironment:\n  sdk: ^3.11.0\n');
  Directory('${dir.path}/lib').createSync();
  File('${dir.path}/lib/models.dart').writeAsStringSync(models);
  if (lock != null) {
    File('${dir.path}/cocoon.lock.json').writeAsStringSync(lock);
  }
  if (extraFile != null) {
    File('${dir.path}/$extraFile')
      ..createSync(recursive: true)
      ..writeAsStringSync(extraContent!);
  }
  final roots = await _packageRoots;
  File('${dir.path}/.dart_tool/package_config.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'migrate_test_pkg',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.11',
          },
          for (final name in _neededPackages)
            {
              'name': name,
              'rootUri': roots[name],
              'packageUri': 'lib/',
              'languageVersion': '3.11',
            },
        ],
      }),
    );
  return dir;
}

// -- Fixtures --------------------------------------------------------------------

/// A staff model with `staffId` — the v1 shape every lock below pins.
const staffV1Models = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffId});
  final String name;
  final String staffId;
}
''';

final staffV1Lock = lockText(
  version: 1,
  collections: {
    'Staff': TestCollection(
      'staff',
      {'name': 'String', 'staffId': 'String'},
      indexes: [
        ['name'],
      ],
    ),
  },
);

/// `staffId` renamed to `staffUid`, same type: the canonical rename prompt.
const staffRenamedModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffUid});
  final String name;
  final String staffUid;
}
''';

/// `staffId` dropped, `staffUid` added: two removals, one candidate each
/// once `staffUid` is taken.
const staffTwoRemovedModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffUid, this.tag = ''});
  final String name;
  final String staffUid;
  final String tag;
}
''';

/// `staffId` renamed to `staffUid` and `code` renamed (and converted) to
/// `code2`: once `staffUid` is taken it must not be offered to `code`.
const staffCodeIntModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({
    required this.name,
    required this.staffUid,
    required this.code2,
  });
  final String name;
  final String staffUid;
  final int code2;
}
''';

/// `staffId` changed from String to int: a pure type change, no decisions.
const staffIdIntModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffId});
  final String name;
  final int staffId;
}
''';

/// `staffId` changed from int to double (after the int step above).
const staffIdDoubleModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffId});
  final String name;
  final double staffId;
}
''';

/// The model moved to a different collection path: refused.
const staffMovedModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('people', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffId});
  final String name;
  final String staffId;
}
''';

String lockFileOf(Directory pkg) =>
    File('${pkg.path}/cocoon.lock.json').readAsStringSync();

bool migrationDirExists(Directory pkg) =>
    Directory('${pkg.path}/lib/cocoon_migrations').existsSync();

void main() {
  tearDown(() async {
    for (final dir in createdDirs) {
      await dir.delete(recursive: true);
    }
    createdDirs.clear();
  });

  Future<int> migrate(
    Directory pkg, {
    List<String> args = const [],
    List<String> lines = const [],
    bool tty = false,
  }) {
    lastIo.reset(lines, tty: tty);
    return runMigrate(packageRoot: pkg.path, args: args, io: lastIo);
  }

  test('no changes: up to date, nothing written', () async {
    final pkg = await tempPackage(models: staffV1Models, lock: staffV1Lock);
    final exit = await migrate(pkg);
    expect(exit, 0);
    expect(
      lastIo.out.toString(),
      contains('Schema is up to date (version 1).'),
    );
    expect(migrationDirExists(pkg), isFalse);
    expect(lockFileOf(pkg), staffV1Lock);
  });

  test(
    'rename chosen from the menu: Enter accepts the best candidate',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg, tty: true, lines: ['']);
      expect(exit, 0);
      expect(
        lastIo.out.toString(),
        contains('Staff: `staffId` (String, #2) is gone and these are new:'),
      );
      expect(
        lastIo.out.toString(),
        contains('1) staffUid (String)  rename, keep data'),
      );
      expect(
        lastIo.out.toString(),
        contains('2) drop staffId (its number is reserved forever)'),
      );

      final lock = SchemaLock.parse(lockFileOf(pkg));
      expect(lock.version, 2);
      final staff = lock.collections['Staff']!;
      expect(staff.field('staffUid')!.number, 2); // keeps the old number
      expect(staff.reserved, isEmpty); // rename: nothing reserved
      expect(migrationDirExists(pkg), isFalse); // same type: no migration
    },
  );

  test(
    'drop chosen from the menu reserves the number',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg, tty: true, lines: ['2']);
      expect(exit, 0);
      expect(lastIo.out.toString(), contains('2) drop staffId'));

      final lock = SchemaLock.parse(lockFileOf(pkg));
      final staff = lock.collections['Staff']!;
      expect(staff.field('staffUid')!.number, 3); // a fresh number
      expect(staff.reserved, [2]);
    },
  );

  test(
    'two renames in one run, both answered',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffTwoRemovedModels,
        lock: lockText(
          version: 1,
          collections: {
            'Staff': TestCollection(
              'staff',
              {'name': 'String', 'staffId': 'String', 'badge': 'String'},
              indexes: [
                ['name'],
              ],
            ),
          },
        ),
      );
      final exit = await migrate(pkg, tty: true, lines: ['', '']);
      expect(exit, 0);
      final lock = SchemaLock.parse(lockFileOf(pkg));
      final staff = lock.collections['Staff']!;
      expect(staff.field('staffUid')!.number, 2);
      expect(staff.field('tag')!.number, 3);
      expect(staff.reserved, isEmpty);
    },
  );

  test(
    'a candidate already chosen for another field is not offered again',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffCodeIntModels,
        lock: lockText(
          version: 1,
          collections: {
            'Staff': TestCollection(
              'staff',
              {'name': 'String', 'staffId': 'String', 'code': 'String'},
              indexes: [
                ['name'],
              ],
            ),
          },
        ),
      );
      // 1st menu (staffId): 1) staffUid, 2) code2, 3) drop -> Enter takes
      // staffUid. 2nd menu (code): staffUid is taken, so only code2 and the
      // drop option remain -> Enter takes code2.
      final exit = await migrate(pkg, tty: true, lines: ['', '']);
      expect(exit, 0);
      final out = lastIo.out.toString();
      expect(
        out,
        contains('Staff: `staffId` (String, #2) is gone and these are new:'),
      );
      expect(out, contains('1) staffUid (String)  rename, keep data'));
      expect(out, contains('2) code2 (int)  rename, convert data'));
      expect(
        out,
        contains('Staff: `code` (String, #3) is gone and these are new:'),
      );
      expect(
        out.indexOf('1) staffUid (String)  rename, keep data'),
        out.lastIndexOf('1) staffUid (String)  rename, keep data'),
      ); // staffUid is offered exactly once: not to `code`
      expect(out, contains('1) code2 (int)  rename, convert data'));

      final lock = SchemaLock.parse(lockFileOf(pkg));
      expect(lock.version, 2);
      final staff = lock.collections['Staff']!;
      expect(staff.field('staffUid')!.number, 2); // rename keeps the number
      expect(staff.field('code2')!.number, 4); // type change: fresh number
      expect(staff.reserved, [3]);
      expect(migrationDirExists(pkg), isTrue); // code -> code2 is an upgrade
    },
  );

  test(
    'a leftover field with no candidates asks a plain drop confirm; No '
    'aborts without writing anything',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final lock = lockText(
        version: 1,
        collections: {
          'Staff': TestCollection(
            'staff',
            {
              'name': 'String',
              'staffId': 'String',
              'badge': 'String',
              'note': 'String',
            },
            indexes: [
              ['name'],
            ],
          ),
        },
      );
      final pkg = await tempPackage(models: staffTwoRemovedModels, lock: lock);
      // staffId -> staffUid (Enter), badge -> tag (Enter); `note` has no
      // candidates left and asks the plain confirm, which `No` aborts.
      final exit = await migrate(pkg, tty: true, lines: ['', '', 'n']);
      expect(exit, 1);
      expect(
        lastIo.out.toString(),
        contains('`note` (String, #4) is gone. Drop it'),
      );
      expect(lastIo.out.toString(), contains('Aborted; nothing was written.'));
      expect(lockFileOf(pkg), lock); // nothing written
      expect(migrationDirExists(pkg), isFalse);
    },
  );

  test(
    'a type change needs no decision and writes the stub and the list',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffIdIntModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg); // non-interactive: nothing to ask
      expect(exit, 0);

      final lock = SchemaLock.parse(lockFileOf(pkg));
      expect(lock.version, 2);
      final staff = lock.collections['Staff']!;
      expect(staff.field('staffId')!.number, 3);
      expect(staff.field('staffId')!.type, 'int');
      expect(staff.reserved, [2]);

      final migrations = Directory('${pkg.path}/lib/cocoon_migrations');
      final migrationFile = migrations.listSync().whereType<File>().singleWhere(
        (f) => f.path.endsWith('.dart') && !f.path.endsWith('migrations.dart'),
      );
      expect(
        migrationFile.uri.pathSegments.last,
        'm0002_staff_staff_id_to_staff_id.dart',
      );
      final source = migrationFile.readAsStringSync();
      expect(
        source,
        contains(
          "int upgradeStaffStaffId(String old) => "
          "throw UnimplementedError('Write the conversion');",
        ),
      );
      expect(
        source,
        contains('// Staff.staffId: String (#2) -> staffId: int (#3)'),
      );
      expect(source, contains('fromWire: MigrationWireType.text,'));
      expect(source, contains('toWire: MigrationWireType.sint64,'));

      final list = File(
        '${migrations.path}/migrations.dart',
      ).readAsStringSync();
      expect(
        list,
        contains("import 'm0002_staff_staff_id_to_staff_id.dart' as m0002;"),
      );
      expect(
        list,
        contains('CocoonMigration(version: 2, fields: m0002.m0002Migrations),'),
      );
    },
  );

  test(
    'a map type change moves the field and writes the map stub',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // v1: meta is Map<String,int>; the model changes it to Map<int,String>
      // (key and value types both changed: a type change, no decisions).
      const metaMapV1Models = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffId});
  final String name;
  final String staffId;
}

@Collection('ledgers')
class Ledger {
  const Ledger({required this.meta});
  final Map<String, int> meta;
}
''';
      const metaMapV2Models = '''
import 'package:cocoon/cocoon.dart';

@Collection('staff', indexes: [Index(['name'])])
class Staff {
  const Staff({required this.name, required this.staffId});
  final String name;
  final String staffId;
}

@Collection('ledgers')
class Ledger {
  const Ledger({required this.meta});
  final Map<int, String> meta;
}
''';
      final ledgerV1Lock = lockText(
        collections: {
          'Staff': TestCollection(
            'staff',
            const {'name': 'String', 'staffId': 'String'},
            indexes: const [
              ['name'],
            ],
          ),
          'Ledger': TestCollection('ledgers', const {
            'meta': 'Map<String,int>',
          }),
        },
      );
      final pkg = await tempPackage(
        models: metaMapV1Models,
        lock: ledgerV1Lock,
      );
      File('${pkg.path}/lib/models.dart').writeAsStringSync(metaMapV2Models);
      final exit = await migrate(pkg); // non-interactive: nothing to ask
      expect(exit, 0);

      final lock = SchemaLock.parse(lockFileOf(pkg));
      expect(lock.version, 2);
      final ledger = lock.collections['Ledger']!;
      expect(ledger.field('meta')!.number, 2);
      expect(ledger.field('meta')!.type, 'Map<int,String>');
      expect(ledger.reserved, [1]);

      final migrations = Directory('${pkg.path}/lib/cocoon_migrations');
      final migrationFile = migrations.listSync().whereType<File>().singleWhere(
        (f) => f.path.endsWith('.dart') && !f.path.endsWith('migrations.dart'),
      );
      final source = migrationFile.readAsStringSync();
      // The stub converts the old map's parts as their stored
      // representations (String keys, int values).
      expect(
        source,
        contains(
          'Map<int, String> upgradeLedgerMeta(Map<String, int> old) => '
          "throw UnimplementedError('Write the conversion');",
        ),
      );
      // The rewrite carries both sides' entry encodings and casts the
      // decoded map to the old field's map type.
      expect(source, contains('fromWire: MigrationWireType.map,'));
      expect(
        source,
        contains(
          'fromMap: MapWireType(\n'
          '      key: MigrationWireType.text,\n'
          '      value: MigrationWireType.sint64,\n'
          '    ),',
        ),
      );
      expect(source, contains('toWire: MigrationWireType.map,'));
      expect(
        source,
        contains(
          'toMap: MapWireType(\n'
          '      key: MigrationWireType.sint64,\n'
          '      value: MigrationWireType.text,\n'
          '    ),',
        ),
      );
      expect(
        source,
        contains(
          '(value! as Map<Object?, Object?>).cast<String, int>(),',
        ),
      );
    },
  );

  test(
    'a map with a list value refuses the generated conversion',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      const listsV1Models = '''
import 'package:cocoon/cocoon.dart';

@Collection('ledgers')
class Ledger {
  const Ledger({required this.meta});
  final Map<String, List<String>> meta;
}
''';
      const listsV2Models = '''
import 'package:cocoon/cocoon.dart';

@Collection('ledgers')
class Ledger {
  const Ledger({required this.meta});
  final Map<String, int> meta;
}
''';
      final ledgerV1Lock = lockText(
        collections: {
          'Ledger': TestCollection('ledgers', const {
            'meta': 'Map<String,List<String>>',
          }),
        },
      );
      final pkg = await tempPackage(
        models: listsV1Models,
        lock: ledgerV1Lock,
      );
      File('${pkg.path}/lib/models.dart').writeAsStringSync(listsV2Models);
      final exit = await migrate(pkg);
      expect(exit, 1);
      expect(
        lastIo.out.toString(),
        contains('Change the field in two steps instead'),
      );
      // Nothing was written.
      expect(SchemaLock.parse(lockFileOf(pkg)).version, 1);
    },
  );

  test(
    'a second migrate regenerates the list with every file',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final pkg = await tempPackage(
        models: staffIdIntModels,
        lock: staffV1Lock,
      );
      await migrate(pkg);
      File(
        '${pkg.path}/lib/models.dart',
      ).writeAsStringSync(staffIdDoubleModels);
      final exit = await migrate(pkg);
      expect(exit, 0);

      final migrations = Directory('${pkg.path}/lib/cocoon_migrations');
      final names =
          migrations
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((n) => n != 'migrations.dart')
              .toList()
            ..sort();
      expect(names, [
        'm0002_staff_staff_id_to_staff_id.dart',
        'm0003_staff_staff_id_to_staff_id.dart',
      ]);
      final list = File(
        '${migrations.path}/migrations.dart',
      ).readAsStringSync();
      expect(list, contains('m0002.m0002Migrations'));
      expect(list, contains('m0003.m0003Migrations'));
      expect(list, contains('CocoonMigration(version: 3'));
      // The second stub converts int -> double.
      final third = File(
        '${migrations.path}/m0003_staff_staff_id_to_staff_id.dart',
      ).readAsStringSync();
      expect(third, contains('double upgradeStaffStaffId(int old)'));
    },
  );

  test(
    'non-interactive stdin with a missing decision exits 2 and names the '
    'flags',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg);
      expect(exit, 2);
      expect(
        lastIo.out.toString(),
        contains('--rename Staff.staffId=staffUid (or --drop Staff.staffId)'),
      );
      expect(lockFileOf(pkg), staffV1Lock); // nothing written
    },
  );

  test(
    'the --rename flag decides without a terminal',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(
        pkg,
        args: ['--rename', 'Staff.staffId=staffUid'],
      );
      expect(exit, 0);
      final lock = SchemaLock.parse(lockFileOf(pkg));
      expect(lock.collections['Staff']!.field('staffUid')!.number, 2);
      expect(migrationDirExists(pkg), isFalse);
    },
  );

  test(
    'the --drop flag reserves the number without a terminal',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg, args: ['--drop', 'Staff.staffId']);
      expect(exit, 0);
      final lock = SchemaLock.parse(lockFileOf(pkg));
      final staff = lock.collections['Staff']!;
      expect(staff.field('staffUid')!.number, 3);
      expect(staff.reserved, [2]);
    },
  );

  test(
    '--yes accepts the default answer of rename menus but never drops',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg, args: ['--yes'], tty: true);
      expect(exit, 0);
      expect(
        SchemaLock.parse(
          lockFileOf(pkg),
        ).collections['Staff']!.field('staffUid')!.number,
        2,
      );

      // --yes cannot answer a drop: without candidates and without a flag it
      // still exits 2 on non-interactive stdin.
      final dropPkg = await tempPackage(
        models: staffIdIntModels,
        lock: lockText(
          version: 1,
          collections: {
            'Staff': TestCollection(
              'staff',
              {'name': 'String', 'staffId': 'String', 'badge': 'String'},
              indexes: [
                ['name'],
              ],
            ),
          },
        ),
      );
      // staffId changed type -> upgrade; badge removed with no candidates.
      final dropExit = await migrate(dropPkg, args: ['--yes']);
      expect(dropExit, 2);
      expect(lastIo.out.toString(), contains('--drop Staff.badge'));
    },
  );

  test(
    '--check exits 1 when the schema would change and writes nothing',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg, args: ['--check']);
      expect(exit, 1);
      expect(lastIo.out.toString(), contains('The schema would change:'));
      expect(
        lastIo.out.toString(),
        contains('Staff: added: staffUid; removed: staffId'),
      );
      expect(
        lastIo.out.toString(),
        contains('cocoon.lock.json was not written (--check).'),
      );
      expect(lockFileOf(pkg), staffV1Lock);
    },
  );

  test(
    '--check is silent-ok when up to date',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(models: staffV1Models, lock: staffV1Lock);
      final exit = await migrate(pkg, args: ['--check']);
      expect(exit, 0);
    },
  );

  test(
    'a collection path change is refused',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(
        models: staffMovedModels,
        lock: staffV1Lock,
      );
      final exit = await migrate(pkg);
      expect(exit, 1);
      expect(
        lastIo.out.toString(),
        contains('Moving a collection is not supported'),
      );
      expect(lockFileOf(pkg), staffV1Lock);
    },
  );

  test(
    'a removed collection asks a confirm; --drop-collection skips it',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final twoModelsLock = lockText(
        version: 1,
        collections: {
          'Staff': TestCollection(
            'staff',
            {'name': 'String', 'staffId': 'String'},
            indexes: [
              ['name'],
            ],
          ),
          'Team': TestCollection('teams', {'title': 'String'}),
        },
      );
      final pkg = await tempPackage(models: staffV1Models, lock: twoModelsLock);
      final exit = await migrate(pkg, tty: true, lines: ['y']);
      expect(exit, 0);
      expect(
        lastIo.out.toString(),
        contains('Collection Team has no model anymore. Drop it'),
      );
      final lock = SchemaLock.parse(lockFileOf(pkg));
      expect(lock.collections.keys, ['Staff']);
      expect(lock.version, 2);

      // And explicitly by flag, without a terminal.
      final flagged = await tempPackage(
        models: staffV1Models,
        lock: twoModelsLock,
      );
      final flaggedExit = await migrate(
        flagged,
        args: ['--drop-collection', 'Team'],
      );
      expect(flaggedExit, 0);
      expect(SchemaLock.parse(lockFileOf(flagged)).collections.keys, ['Staff']);
    },
  );

  test(
    'unknown flags and bad values exit 2',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final pkg = await tempPackage(models: staffV1Models, lock: staffV1Lock);
      expect((await migrate(pkg, args: ['--wat'])), 2);
      expect(lastIo.out.toString(), contains('Unknown argument "--wat"'));

      final bad = await tempPackage(
        models: staffRenamedModels,
        lock: staffV1Lock,
      );
      expect(
        (await migrate(bad, args: ['--rename', 'Staff.badge=staffUid'])),
        2,
      );
      expect(
        lastIo.out.toString(),
        contains('"badge" is not a removed field of Staff'),
      );
    },
  );

  test(
    'the cocoon_example lock is what migrate writes for its v2 lock',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      // The committed example lock (v3, `Txn.meta` added) was produced by
      // this exact flow: its v2 lock (the committed one minus `meta`) plus
      // its real models, migrated without flags (a pure field addition
      // needs no decisions). The generated part file is present, like in
      // every real package.
      final exampleLib = Directory('../cocoon_example/lib');
      final models = File('${exampleLib.path}/models.dart').readAsStringSync();

      final pkg = await tempPackage(
        models: models,
        lock: exampleV2Lock(),
        extraFile: 'lib/models.cocoon.dart',
        extraContent: "part of 'models.dart';\n",
      );
      final exit = await migrate(pkg); // non-interactive: nothing to ask
      expect(exit, 0, reason: lastIo.out.toString());
      // A field addition writes no migration file.
      expect(migrationDirExists(pkg), isFalse);

      // The written lock is byte-for-byte the committed one.
      final committedLock = File(
        '../cocoon_example/cocoon.lock.json',
      ).readAsStringSync();
      expect(lockFileOf(pkg), committedLock);
    },
  );

  test(
    'the example m0002 stub is what migrate writes for its v1 lock',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      // The committed m0002 migration file was produced by migrating the v1
      // lock (`Txn.bookedOn` a String at number 1) against the real models.
      // The `meta` addition in the same run needs no decision and no
      // migration file, so the field-rewrite list is exactly the committed
      // one. The generated part file is present, like in every real package.
      final exampleLib = Directory('../cocoon_example/lib');
      final models = File('${exampleLib.path}/models.dart').readAsStringSync();

      final pkg = await tempPackage(
        models: models,
        lock: exampleV1Lock(),
        extraFile: 'lib/models.cocoon.dart',
        extraContent: "part of 'models.dart';\n",
      );
      final exit = await migrate(pkg); // non-interactive: nothing to ask
      expect(exit, 0, reason: lastIo.out.toString());
      expect(
        lastIo.out.toString(),
        contains(
          'Wrote lib/cocoon_migrations/m0002_txn_booked_on_to_booked_on.dart.',
        ),
      );

      // The generated list file is byte-for-byte the committed one.
      final committedList = File(
        '${exampleLib.path}/cocoon_migrations/migrations.dart',
      ).readAsStringSync();
      expect(
        File(
          '${pkg.path}/lib/cocoon_migrations/migrations.dart',
        ).readAsStringSync(),
        committedList,
      );

      // The committed migration file is the generated stub with only the
      // conversion body implemented: compare from the field-rewrite list on.
      final stub = File(
        '${pkg.path}/lib/cocoon_migrations/m0002_txn_booked_on_to_booked_on.dart',
      ).readAsStringSync();
      final committed = File(
        '${exampleLib.path}/cocoon_migrations/'
        'm0002_txn_booked_on_to_booked_on.dart',
      ).readAsStringSync();
      const listMarker = 'final m0002Migrations = <FieldMigration>[';
      expect(stub, contains(listMarker));
      expect(
        stub.substring(stub.indexOf(listMarker)),
        committed.substring(committed.indexOf(listMarker)),
      );
      expect(committed, contains('int upgradeTxnBookedOn(String old) =>'));
    },
  );
}

/// The example package's v2 lock: the committed v3 lock minus the `meta`
/// field addition, one version back. The committed lock is its `migrate`
/// output.
String exampleV2Lock() {
  final committed =
      jsonDecode(
            File(
              '../cocoon_example/cocoon.lock.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final collections = committed['collections']! as Map<String, Object?>;
  final txn = collections['Txn']! as Map<String, Object?>;
  (txn['fields']! as Map<String, Object?>).remove('meta');
  committed['version'] = 2;
  return '${const JsonEncoder.withIndent('  ').convert(committed)}\n';
}

/// The example package's v1 lock: the current schema with `Txn.bookedOn`
/// still a String at number 1. The committed lock is its `migrate` output.
String exampleV1Lock() => lockText(
  version: 1,
  collections: {
    'Account': TestCollection(
      'accounts',
      const {
        'name': 'String',
        'openedAt': 'DateTime',
        'balanceMinor': 'int',
        'active': 'bool',
        'tags': 'List<String>',
        'address': 'embedded:Address?',
        'avatar': 'Uint8List?',
      },
      indexes: [
        ['name'],
      ],
    ),
    'Txn': TestCollection(
      'accounts/{accountId}/txns',
      const {
        'bookedOn': 'String',
        'amountMinor': 'int',
        'currency': 'String',
        'status': 'enum:TxnStatus',
        'createdAt': 'DateTime',
        'rate': 'double',
        'memo': 'String?',
        'labels': 'List<String>',
        'receipt': 'Uint8List?',
      },
      indexes: [
        ['accountId', '-bookedOn'],
        ['status', 'bookedOn'],
      ],
    ),
    'Split': TestCollection(
      'accounts/{accountId}/txns/{txnId}/splits',
      const {'label': 'String', 'shareMinor': 'int', 'note': 'String?'},
      indexes: [
        ['accountId', 'txnId', '-shareMinor'],
      ],
    ),
  },
  embedded: {
    'Address': const {
      'city': 'String',
      'postCode': 'String',
      'line2': 'String?',
      'geo': 'embedded:GeoPoint?',
    },
    'GeoPoint': const {'lat': 'double', 'lon': 'double'},
  },
);
