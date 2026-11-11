/// Tests for `dart run cocoon_generator:index add <Model> <fields>`, driven
/// in-process through [runIndexAdd] with a fake terminal over throwaway
/// packages in temp directories (the same harness as `migrate_test.dart`).
///
/// Covered: the single-field edit writes `@Indexed()` (descending variant
/// included) on the right field, composites and path params append to the
/// `@Collection(indexes: [...])` list and create the named argument when it
/// is missing, an index declared in exactly that order is a no-op naming its
/// declarer, unknown names exit 1 with a "did you mean", annotation shapes
/// the command does not edit are refused with the exact text to paste, the
/// edited file is dart-formatted, and — via `runMigrate` — moving a one-field
/// index from the class to `@Indexed()` on the field leaves `cocoon.lock`
/// byte-identical (no schema version bump, no rebuild).
library;

import 'dart:io';

import 'package:cocoon_generator/index.dart';
import 'package:cocoon_generator/migrate.dart';
import 'package:test/test.dart';

import 'migrate_test.dart'
    show FakeTerminal, createdDirs, lockFileOf, lockOf, tempPackage;

/// A txn model with the canonical scope index and nothing else indexed:
/// `amountMinor` is a plain column, `accountId` a path param.
const txnModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn {
  const Txn({
    required this.bookedOn,
    required this.amountMinor,
    required this.currency,
  });

  final int bookedOn;
  final int amountMinor;
  final String currency;
}
''';

/// The same model with the one-field index on the class.
const txnClassIndexedModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
  Index(['amountMinor']),
])
class Txn {
  const Txn({
    required this.bookedOn,
    required this.amountMinor,
    required this.currency,
  });

  final int bookedOn;
  final int amountMinor;
  final String currency;
}
''';

/// The same model with the same index moved onto the field (fields
/// reordered on purpose: class order never matters, the lock pins numbers).
const txnFieldIndexedModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn {
  const Txn({
    required this.bookedOn,
    required this.amountMinor,
    required this.currency,
  });

  @Indexed()
  final int amountMinor;
  final int bookedOn;
  final String currency;
}
''';

final FakeTerminal io = FakeTerminal();

void main() {
  tearDown(() async {
    for (final dir in createdDirs) {
      dir.deleteSync(recursive: true);
    }
    createdDirs.clear();
  });

  Future<int> indexAdd(Directory pkg, String model, String fields) {
    io.reset([], tty: false);
    return runIndexAdd(
      packageRoot: pkg.path,
      args: ['add', model, fields],
      io: io,
    );
  }

  /// Whether `dart format` would still change [path] (exit 1) or not (0).
  Future<bool> isFormatted(String path) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      path,
    ]);
    return result.exitCode == 0;
  }

  String modelsOf(Directory pkg) =>
      File('${pkg.path}/lib/models.dart').readAsStringSync();

  group('a one-field index over a model field', () {
    test('adds @Indexed() to that field and prints the next steps', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor');
      expect(exit, 0);
      expect(modelsOf(pkg), contains('@Indexed()\n  final int amountMinor;'));
      // The other declarations are untouched.
      expect(modelsOf(pkg), contains("Index(['accountId', '-bookedOn'])"));
      // The two follow-up commands, in the order the user runs them.
      expect(io.out.toString(), contains('dart run cocoon_generator:migrate'));
      expect(io.out.toString(), contains('dart run build_runner build -d'));
      // The command formatted the file it edited.
      expect(await isFormatted('${pkg.path}/lib/models.dart'), isTrue);
    });

    test('descending becomes @Indexed(descending: true)', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', '-amountMinor');
      expect(exit, 0);
      expect(
        modelsOf(pkg),
        contains('@Indexed(descending: true)\n  final int amountMinor;'),
      );
    });
  });

  group('composites and path params', () {
    test('append Index([...]) to the existing indexes: list', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor,currency');
      expect(exit, 0);
      final models = modelsOf(pkg);
      expect(models, contains("Index(['accountId', '-bookedOn'])"));
      expect(models, contains("Index(['amountMinor', 'currency'])"));
      expect(await isFormatted('${pkg.path}/lib/models.dart'), isTrue);
    });

    test('a single path param stays a class-level composite', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'accountId');
      expect(exit, 0);
      // Not a field annotation: accountId is a path param, not a field.
      expect(modelsOf(pkg), isNot(contains('@Indexed')));
      expect(modelsOf(pkg), contains("Index(['accountId'])"));
    });

    test('create the named argument when the annotation has none', () async {
      const models = '''
import 'package:cocoon/cocoon.dart';

@Collection('accounts/{accountId}/txns')
class Txn {
  const Txn({required this.bookedOn, required this.amountMinor});
  final int bookedOn;
  final int amountMinor;
}
''';
      final pkg = await tempPackage(models: models);
      // One field over a model field goes on the field, not the class.
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor');
      expect(exit, 0);
      expect(modelsOf(pkg), contains('@Indexed()'));

      final composite = await tempPackage(models: models);
      final compositeExit = await indexAdd(
        composite,
        'Txn',
        'amountMinor,bookedOn',
      );
      expect(compositeExit, 0);
      final edited = modelsOf(composite);
      expect(edited, contains("Index(['amountMinor', 'bookedOn'])"));
      // The named argument was created on the path annotation.
      expect(edited, contains('indexes: ['));
      expect(edited, contains("'accounts/{accountId}/txns'"));
    });
  });

  group('idempotence', () {
    test('an existing class-level index is a no-op naming itself', () async {
      final pkg = await tempPackage(models: txnClassIndexedModels);
      final before = modelsOf(pkg);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor');
      expect(exit, 0);
      expect(io.out.toString(), contains('Nothing to do'));
      expect(modelsOf(pkg), before);
    });

    test('an existing @Indexed field is a no-op naming the field', () async {
      final pkg = await tempPackage(models: txnFieldIndexedModels);
      final before = modelsOf(pkg);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor');
      expect(exit, 0);
      expect(io.out.toString(), contains('Nothing to do'));
      expect(io.out.toString(), contains('@Indexed() on amountMinor'));
      expect(modelsOf(pkg), before);
    });
  });

  group('refusals', () {
    test('an unknown field exits 1 with a did-you-mean', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'amoutMinor');
      expect(exit, 1);
      expect(
        io.err.toString(),
        contains('has no field or path param named "amoutMinor"'),
      );
      expect(io.err.toString(), contains('Did you mean "amountMinor"?'));
    });

    test('an unknown model exits 1 with a did-you-mean', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txnn', 'amountMinor');
      expect(exit, 1);
      expect(io.err.toString(), contains('No @Collection class named "Txnn"'));
      expect(io.err.toString(), contains('Did you mean "Txn"?'));
      expect(io.err.toString(), contains('Declared collections: Txn'));
    });

    test('an indexes list built from a const variable is refused with the '
        'paste text', () async {
      const models = '''
import 'package:cocoon/cocoon.dart';

const staffIndexes = [Index(['name'])];

@Collection('staff', indexes: staffIndexes)
class Staff {
  const Staff({required this.name, required this.city});
  final String name;
  final String city;
}
''';
      final pkg = await tempPackage(models: models);
      final exit = await indexAdd(pkg, 'Staff', 'name,city');
      expect(exit, 1);
      final error = io.err.toString();
      expect(error, contains('not a shape this command edits'));
      expect(
        error,
        contains(
          "Paste by hand into Staff's @Collection(indexes: [...]): "
          "Index(['name', 'city'])",
        ),
      );
      expect(modelsOf(pkg), models);
    });

    test('a field declared together with others is refused with the paste '
        'text', () async {
      const models = '''
import 'package:cocoon/cocoon.dart';

@Collection('things')
class Thing {
  const Thing({required this.a, required this.b});
  final int a, b;
}
''';
      final pkg = await tempPackage(models: models);
      final exit = await indexAdd(pkg, 'Thing', 'a');
      expect(exit, 1);
      final error = io.err.toString();
      expect(error, contains('single-field declarations only'));
      expect(
        error,
        contains(
          "Paste by hand into Thing's @Collection(indexes: [...]): "
          "Index(['a'])",
        ),
      );
      expect(modelsOf(pkg), models);
    });

    test('a usage error exits 2', () async {
      final pkg = await tempPackage(models: txnModels);
      io.reset([], tty: false);
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', 'Txn'],
        io: io,
      );
      expect(exit, 2);
      expect(io.err.toString(), contains('Usage:'));
    });
  });

  test('moving a one-field index from the class to the field changes '
      'nothing in the lock', () async {
    // Write the lock for the class-level declaration.
    final pkg = await tempPackage(models: txnClassIndexedModels);
    io.reset([], tty: false);
    expect(await runMigrate(packageRoot: pkg.path, args: const [], io: io), 0);
    final before = lockFileOf(pkg);
    expect(lockOf(pkg).version, 1);

    // Move the same index onto the field.
    File(
      '${pkg.path}/lib/models.dart',
    ).writeAsStringSync(txnFieldIndexedModels);
    io.reset([], tty: false);
    expect(await runMigrate(packageRoot: pkg.path, args: const [], io: io), 0);
    expect(io.out.toString(), contains('Schema is up to date (version 1).'));
    // Byte-identical lock: same canonical form, same physical index name,
    // no version bump, no rebuild.
    expect(lockFileOf(pkg), before);
    expect(lockOf(pkg).version, 1);
  });
}
