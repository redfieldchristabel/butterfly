/// Tests for `dart run cocoon_generator:index add`, driven in-process
/// through [runIndexAdd] with a fake terminal over throwaway packages in
/// temp directories (the same harness as `migrate_test.dart`).
///
/// Covered: the single-field edit writes `@Indexed()` (descending and unique
/// variants included) on the right field, composites and path params insert
/// one stacked `@Index([...])` line above the class declaration (after the
/// existing annotations, `indexes:` never touched — a const-variable list
/// included), `--unique` makes the index UNIQUE, an index already declared
/// in any of the three forms (`indexes:`, stacked `@Index`, `@Indexed()`) is
/// a no-op naming its declarer, unknown names exit 1 with a "did you mean",
/// shapes the command does not edit are refused with the exact text to
/// paste, `--dry-run` prints without writing, `--missing` scans a saved log
/// for `Fix:` lines (any prefix) and applies each, and — via `runMigrate` —
/// moving an index between `indexes:`, a stacked `@Index` and `@Indexed()`
/// leaves `cocoon.lock` byte-identical (no schema version bump, no
/// rebuild).
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

/// The same model with the composite moved from `indexes:` to a stacked
/// `@Index` above the class (`amountMinor` stays where it was).
const txnStackedModels = '''
import 'package:cocoon/cocoon.dart';

@Collection('accounts/{accountId}/txns', indexes: [
  Index(['amountMinor']),
])
@Index(['accountId', '-bookedOn'])
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

/// A model whose `indexes:` list is built from a const variable.
const staffConstIndexesModels = '''
import 'package:cocoon/cocoon.dart';

const staffIndexes = [Index(['name'])];

@Collection('staff', indexes: staffIndexes)
class Staff {
  const Staff({required this.name, required this.city});
  final String name;
  final String city;
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

  Future<int> indexAdd(
    Directory pkg,
    String model,
    String fields, [
    List<String> flags = const [],
  ]) {
    io.reset([], tty: false);
    return runIndexAdd(
      packageRoot: pkg.path,
      args: ['add', model, fields, ...flags],
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
      // The result line names what was written and where.
      expect(io.out.toString(), contains('Added @Indexed() on amountMinor'));
      expect(io.out.toString(), contains('lib/models.dart'));
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

    test('--unique becomes @Indexed(unique: true)', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'currency', ['--unique']);
      expect(exit, 0);
      expect(
        modelsOf(pkg),
        contains('@Indexed(unique: true)\n  final String currency;'),
      );
    });
  });

  group('composites and path params', () {
    test(
      'insert one stacked @Index above the class, indexes: untouched',
      () async {
        final pkg = await tempPackage(models: txnModels);
        final exit = await indexAdd(pkg, 'Txn', 'amountMinor,currency');
        expect(exit, 0);
        final models = modelsOf(pkg);
        // The old list entry is still exactly where it was.
        expect(models, contains("Index(['accountId', '-bookedOn'])"));
        // The new declaration is a stacked line right above the class.
        expect(
          models,
          contains(")\n@Index(['amountMinor', 'currency'])\nclass Txn {"),
        );
        expect(await isFormatted('${pkg.path}/lib/models.dart'), isTrue);
      },
    );

    test('insert after existing stacked @Index lines', () async {
      final pkg = await tempPackage(models: txnStackedModels);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor,currency');
      expect(exit, 0);
      final models = modelsOf(pkg);
      expect(
        models,
        contains(
          "@Index(['accountId', '-bookedOn'])\n"
          "@Index(['amountMinor', 'currency'])\n"
          'class Txn {',
        ),
      );
      expect(await isFormatted('${pkg.path}/lib/models.dart'), isTrue);
    });

    test('--unique adds unique: true to the stacked line', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'bookedOn,currency', [
        '--unique',
      ]);
      expect(exit, 0);
      expect(
        modelsOf(pkg),
        contains("@Index(['bookedOn', 'currency'], unique: true)"),
      );
    });

    test('a single path param stays a class-level stacked line', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'accountId');
      expect(exit, 0);
      // Not a field annotation: accountId is a path param, not a field.
      expect(modelsOf(pkg), isNot(contains('@Indexed')));
      expect(modelsOf(pkg), contains("@Index(['accountId'])\nclass Txn {"));
    });

    test(
      'a model without an indexes: argument is edited the same way',
      () async {
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
        expect(edited, contains("@Index(['amountMinor', 'bookedOn'])"));
        expect(edited, contains("@Collection('accounts/{accountId}/txns')"));
      },
    );

    test('a const-variable indexes: list now gets a stacked line', () async {
      final pkg = await tempPackage(models: staffConstIndexesModels);
      final before = modelsOf(pkg);
      final exit = await indexAdd(pkg, 'Staff', 'name,city');
      expect(exit, 0);
      final models = modelsOf(pkg);
      // The stacked line went above the class; the shared const list the
      // developer wrote is untouched.
      expect(models, contains('indexes: staffIndexes'));
      expect(models, contains("@Index(['name', 'city'])\nclass Staff {"));
      expect(models, contains("Index(['name'])"));
      expect(before, isNot(models));
      expect(await isFormatted('${pkg.path}/lib/models.dart'), isTrue);
    });
  });

  group('idempotence', () {
    test('an index in indexes: is a no-op naming the list', () async {
      final pkg = await tempPackage(models: txnClassIndexedModels);
      final before = modelsOf(pkg);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor');
      expect(exit, 0);
      expect(io.out.toString(), contains('Nothing to do'));
      expect(io.out.toString(), contains('in @Collection(indexes: [...])'));
      expect(modelsOf(pkg), before);
    });

    test('an existing @Indexed field is a no-op naming the field', () async {
      final pkg = await tempPackage(models: txnFieldIndexedModels);
      final before = modelsOf(pkg);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor');
      expect(exit, 0);
      expect(io.out.toString(), contains('Nothing to do'));
      expect(io.out.toString(), contains('by @Indexed() on amountMinor'));
      expect(modelsOf(pkg), before);
    });

    test('an existing stacked @Index is a no-op naming the stack', () async {
      final pkg = await tempPackage(models: txnStackedModels);
      final before = modelsOf(pkg);
      final exit = await indexAdd(pkg, 'Txn', 'accountId,-bookedOn');
      expect(exit, 0);
      expect(io.out.toString(), contains('Nothing to do'));
      expect(
        io.out.toString(),
        contains('as a stacked @Index above the class'),
      );
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
          'Paste by hand as a stacked @Index above Thing\'s class '
          "declaration: @Index(['a'])",
        ),
      );
      expect(modelsOf(pkg), models);
    });

    test('an unknown option exits 2', () async {
      final pkg = await tempPackage(models: txnModels);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor', ['--nope']);
      expect(exit, 2);
      expect(io.err.toString(), contains('Unknown option "--nope"'));
      expect(io.err.toString(), contains('Usage:'));
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

  group('dry run', () {
    test(
      'the field form prints what would change and writes nothing',
      () async {
        final pkg = await tempPackage(models: txnModels);
        final before = modelsOf(pkg);
        final exit = await indexAdd(pkg, 'Txn', 'amountMinor', ['--dry-run']);
        expect(exit, 0);
        expect(modelsOf(pkg), before);
        expect(
          io.out.toString(),
          contains(
            'Would add @Indexed() on amountMinor to Txn in lib/models.dart '
            '(dry run: nothing written).',
          ),
        );
        // A dry run prints no follow-up commands: nothing happened yet.
        expect(
          io.out.toString(),
          isNot(contains('dart run cocoon_generator:migrate')),
        );
      },
    );

    test(
      'the stacked form prints what would change and writes nothing',
      () async {
        final pkg = await tempPackage(models: txnModels);
        final before = modelsOf(pkg);
        final exit = await indexAdd(pkg, 'Txn', 'amountMinor,currency', [
          '--dry-run',
        ]);
        expect(exit, 0);
        expect(modelsOf(pkg), before);
        expect(
          io.out.toString(),
          contains(
            "Would add @Index(['amountMinor', 'currency']) above the Txn class "
            'in lib/models.dart (dry run: nothing written).',
          ),
        );
      },
    );

    test('an already-declared index still says so, unchanged', () async {
      final pkg = await tempPackage(models: txnFieldIndexedModels);
      final before = modelsOf(pkg);
      final exit = await indexAdd(pkg, 'Txn', 'amountMinor', ['--dry-run']);
      expect(exit, 0);
      expect(modelsOf(pkg), before);
      expect(io.out.toString(), contains('Nothing to do'));
    });
  });

  group('--missing', () {
    /// A saved debug log: logcat tags, timestamps, an `I/flutter (1234):`
    /// prefix, a duplicate Fix line, a one-field fix, an already-declared
    /// index and an unknown model.
    const mixedLog = '''
11-12 08:14:02.101  4321  5678 I flutter : [cocoon] MissingIndexException: No index serves this query on Txn
11-12 08:14:02.101  4321  5678 I flutter : (accounts/{accountId}/txns). Add Index(['accountId', '-currency']) above its @Collection class, or call .allowFullScan() to read it anyway.
11-12 08:14:02.101  4321  5678 I flutter : Fix: dart run cocoon_generator:index add Txn accountId,-currency (writes Index(['accountId', '-currency']) above the Txn class)
I/flutter (4321): [cocoon] Txn: amountMinor (where amountMinor ==). Fix: dart run cocoon_generator:index add Txn amountMinor
2026-11-12T08:15:00.000Z [warn] Fix: dart run cocoon_generator:index add Txn accountId,-currency (writes Index(['accountId', '-currency']) above the Txn class)
I/flutter (4321): [cocoon] Txn: currency (where currency ==). Fix: dart run cocoon_generator:index add Txn currency
I/flutter (4321): [cocoon] Txnn: amountMinor (where amountMinor ==). Fix: dart run cocoon_generator:index add Txnn amountMinor
''';

    /// A model where `currency` is already declared (@Indexed) and
    /// `amountMinor` is a plain field.
    Future<Directory> packageWithCurrencyIndexed() => tempPackage(
      models: '''
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
  @Indexed()
  final String currency;
}
''',
    );

    test('applies every distinct Fix line and reports per index', () async {
      final pkg = await packageWithCurrencyIndexed();
      io.reset([], tty: false);
      final log = File('${pkg.path}/run.log')..writeAsStringSync(mixedLog);
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing', log.path],
        io: io,
      );
      // The unknown model is refused; everything else was declared.
      expect(exit, 1);
      final out = io.out.toString();
      // The composite with the descending part: one stacked line, added.
      expect(
        out,
        contains(
          "Added @Index(['accountId', '-currency']) above the Txn class in "
          'lib/models.dart',
        ),
      );
      // The one-field fix went onto the field.
      expect(out, contains('Added @Indexed() on amountMinor to Txn'));
      // The duplicate Fix line was applied once; the currency line is a
      // no-op naming its declarer.
      expect(out, contains("Nothing to do: Index(['currency'])"));
      expect(out, contains('by @Indexed() on currency'));
      // The unknown model: refused with the reason on one line.
      expect(out, contains('refused: '));
      expect(out, contains('No @Collection class named "Txnn"'));
      expect(out, contains('Did you mean "Txn"?'));
      // One line per index (four distinct Fix lines), then the summary.
      expect(RegExp(r'^Added', multiLine: true).allMatches(out), hasLength(2));
      expect(out, contains('2 added, 1 already declared, 1 refused, of 4 in'));
      // The follow-up commands print once, after the summary.
      expect(out.indexOf('Added'), lessThan(out.lastIndexOf('Next:')));
      expect('Next:'.allMatches(out), hasLength(1));
      // The model file was edited (twice) and is formatted.
      expect(await isFormatted('${pkg.path}/lib/models.dart'), isTrue);
    });

    test('exits 0 when every index ended up declared', () async {
      final pkg = await tempPackage(models: txnModels);
      io.reset([], tty: false);
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing', '-'],
        io: io
          ..pipedInput =
              'Fix: dart run cocoon_generator:index add Txn '
              'amountMinor\n',
      );
      expect(exit, 0);
      expect(modelsOf(pkg), contains('@Indexed()'));
    });

    test('a log with no Fix lines prints that and exits 0', () async {
      final pkg = await tempPackage(models: txnModels);
      final before = modelsOf(pkg);
      io.reset([], tty: false);
      final log = File('${pkg.path}/run.log')
        ..writeAsStringSync('nothing to see here\nI/flutter (1): hello\n');
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing', log.path],
        io: io,
      );
      expect(exit, 0);
      expect(io.out.toString(), contains('No "Fix:'));

      final stdinExit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing', '-'],
        io: io..pipedInput = 'no fixes either\n',
      );
      expect(stdinExit, 0);
      expect(io.out.toString(), contains('No "Fix:'));
      expect(modelsOf(pkg), before);
    });

    test('a nonexistent file is a usage error (exit 2)', () async {
      final pkg = await tempPackage(models: txnModels);
      io.reset([], tty: false);
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing', '${pkg.path}/nope.log'],
        io: io,
      );
      expect(exit, 2);
      expect(io.err.toString(), contains('No such file'));
    });

    test('--missing without a file exits 2', () async {
      final pkg = await tempPackage(models: txnModels);
      io.reset([], tty: false);
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing'],
        io: io,
      );
      expect(exit, 2);
      expect(io.err.toString(), contains('Usage:'));
    });

    test('--dry-run reports without writing', () async {
      final pkg = await packageWithCurrencyIndexed();
      final before = modelsOf(pkg);
      io.reset([], tty: false);
      final log = File('${pkg.path}/run.log')..writeAsStringSync(mixedLog);
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing', log.path, '--dry-run'],
        io: io,
      );
      expect(exit, 1);
      final out = io.out.toString();
      expect(out, contains("Would add @Index(['accountId', '-currency'])"));
      expect(out, contains('Would add @Indexed() on amountMinor'));
      expect(out, contains('2 added (dry run)'));
      expect(modelsOf(pkg), before);
    });

    test('the same index from two Fix spellings is applied once', () async {
      final pkg = await tempPackage(models: txnModels);
      io.reset([], tty: false);
      final exit = await runIndexAdd(
        packageRoot: pkg.path,
        args: ['add', '--missing', '-'],
        io: io
          ..pipedInput =
              'Fix: dart run cocoon_generator:index add Txn '
              'bookedOn,currency\n'
              'Fix: dart run cocoon_generator:index add Txn '
              'bookedOn,currency\n',
      );
      expect(exit, 0);
      final models = modelsOf(pkg);
      expect(
        "@Index(['bookedOn', 'currency'])".allMatches(models),
        hasLength(1),
      );
      expect(
        io.out.toString(),
        contains(
          '1 added, 0 already declared, 0 '
          'refused, of 1 in stdin',
        ),
      );
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

  test('moving an index from indexes: to a stacked @Index leaves the lock '
      'byte-identical', () async {
    final pkg = await tempPackage(models: txnClassIndexedModels);
    io.reset([], tty: false);
    expect(await runMigrate(packageRoot: pkg.path, args: const [], io: io), 0);
    final before = lockFileOf(pkg);
    expect(lockOf(pkg).version, 1);

    // Move the composite onto a stacked @Index line.
    File('${pkg.path}/lib/models.dart').writeAsStringSync(txnStackedModels);
    io.reset([], tty: false);
    expect(await runMigrate(packageRoot: pkg.path, args: const [], io: io), 0);
    expect(io.out.toString(), contains('Schema is up to date (version 1).'));
    expect(lockFileOf(pkg), before);
    expect(lockOf(pkg).version, 1);
  });

  test('moving a one-field index from the field to a stacked @Index leaves '
      'the lock byte-identical', () async {
    final pkg = await tempPackage(models: txnFieldIndexedModels);
    io.reset([], tty: false);
    expect(await runMigrate(packageRoot: pkg.path, args: const [], io: io), 0);
    final before = lockFileOf(pkg);

    // Move the same one-field index onto a stacked class line.
    File('${pkg.path}/lib/models.dart').writeAsStringSync('''
import 'package:cocoon/cocoon.dart';

@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
@Index(['amountMinor'])
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
''');
    io.reset([], tty: false);
    expect(await runMigrate(packageRoot: pkg.path, args: const [], io: io), 0);
    expect(io.out.toString(), contains('Schema is up to date (version 1).'));
    expect(lockFileOf(pkg), before);
    expect(lockOf(pkg).version, 1);
  });
}
