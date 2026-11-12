import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/cocoon.dart';
import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/cocoon.dart';
import 'package:test/test.dart';

import '../helpers/mocks.dart';

void main() {
  group('CocoonCommand', () {
    test('registers migrate, index and build subcommands', () {
      final cmd = CocoonCommand(MockCocoonService());
      expect(cmd.name, equals('cocoon'));
      expect(cmd.subcommands.keys, containsAll(['migrate', 'index', 'build']));
    });
  });

  group('CocoonMigrateCommand', () {
    test('has correct command name', () {
      expect(CocoonMigrateCommand(MockCocoonService()).name, equals('migrate'));
    });

    test('passes args verbatim to the project migrate with inherited stdio',
        () async {
      getIt.reset();
      getIt.registerSingleton<ILoggerService>(MockLoggerService());
      getIt.registerSingleton<IDirectoryService>(MockDirectoryService());
      final process = MockProcessRunner();
      final service = _service(process);

      final runner = CommandRunner<void>('test', 'Test runner');
      runner.addCommand(CocoonCommand(service));

      await runner.run([
        'cocoon',
        'migrate',
        '--check',
        '--rename',
        'Txn.bookedOn=day',
        '--yes',
      ]);

      expect(process.calls, hasLength(1));
      final call = process.calls.single;
      expect(call.executable, equals('dart'));
      expect(
        call.arguments,
        equals([
          'run',
          'cocoon_generator:migrate',
          '--check',
          '--rename',
          'Txn.bookedOn=day',
          '--yes',
        ]),
      );
      expect(call.inheritedStdio, isTrue);
    });

    test('propagates exit code 0 without exiting', () async {
      final exits = <int>[];
      final runner = _runner(MockProcessRunner()..nextExitCode = 0, exits);
      await runner.run(['cocoon', 'migrate']);
      expect(exits, isEmpty);
    });

    test('propagates exit code 1', () async {
      final exits = <int>[];
      final runner = _runner(MockProcessRunner()..nextExitCode = 1, exits);
      await runner.run(['cocoon', 'migrate', '--check']);
      expect(exits, equals([1]));
    });

    test('propagates exit code 2', () async {
      final exits = <int>[];
      final runner = _runner(MockProcessRunner()..nextExitCode = 2, exits);
      await runner.run(['cocoon', 'migrate', '--bogus-flag']);
      expect(exits, equals([2]));
    });

    test(
        'throws a ReadableException with the pub add lines when the tools '
        'are missing, without running anything', () async {
      final process = MockProcessRunner();
      getIt.reset();
      getIt.registerSingleton<ILoggerService>(MockLoggerService());
      getIt.registerSingleton<IDirectoryService>(MockDirectoryService());
      final runner = CommandRunner<void>('test', 'Test runner');
      runner.addCommand(CocoonCommand(
          _service(process, MockPubspecService(dependencies: {}))));

      await expectLater(
        runner.run(['cocoon', 'migrate', '--check']),
        throwsA(isA<ReadableException>().having(
            (e) => e.hint!,
            'hint',
            allOf(contains('dart pub add cocoon'),
                contains('dart pub add --dev cocoon_generator build_runner')))),
      );
      expect(process.calls, isEmpty);
    });
  });

  group('CocoonIndexAddCommand', () {
    test('has correct command path', () {
      final cmd = CocoonIndexCommand(MockCocoonService());
      expect(cmd.name, equals('index'));
      expect(cmd.subcommands.keys, equals(['add']));
    });

    test('passes model and fields verbatim to index add with inherited stdio',
        () async {
      final process = MockProcessRunner();
      final runner = _runner(process, <int>[]);
      await runner
          .run(['cocoon', 'index', 'add', 'Txn', 'accountId,-bookedOn']);

      final call = process.calls.single;
      expect(call.executable, equals('dart'));
      expect(
          call.arguments,
          equals([
            'run',
            'cocoon_generator:index',
            'add',
            'Txn',
            'accountId,-bookedOn',
          ]));
      expect(call.inheritedStdio, isTrue);
    });

    test('forwards --missing and --dry-run verbatim', () async {
      final process = MockProcessRunner();
      final runner = _runner(process, <int>[]);
      await runner.run(['cocoon', 'index', 'add', '--missing', 'log.txt']);

      final call = process.calls.first;
      expect(
          call.arguments,
          equals([
            'run',
            'cocoon_generator:index',
            'add',
            '--missing',
            'log.txt',
          ]));
      expect(call.inheritedStdio, isTrue);

      await runner
          .run(['cocoon', 'index', 'add', 'Txn', 'amountMinor', '--dry-run']);
      expect(
          process.calls.last.arguments,
          equals([
            'run',
            'cocoon_generator:index',
            'add',
            'Txn',
            'amountMinor',
            '--dry-run',
          ]));
    });

    test('propagates a failing exit code', () async {
      final exits = <int>[];
      final runner = _runner(MockProcessRunner()..nextExitCode = 1, exits);
      await runner.run(['cocoon', 'index', 'add', 'Txn', 'nope']);
      expect(exits, equals([1]));
    });

    test(
        'throws a ReadableException when the tools are missing, without '
        'running anything', () async {
      final process = MockProcessRunner();
      getIt.reset();
      getIt.registerSingleton<ILoggerService>(MockLoggerService());
      getIt.registerSingleton<IDirectoryService>(MockDirectoryService());
      final runner = CommandRunner<void>('test', 'Test runner');
      runner.addCommand(CocoonCommand(
          _service(process, MockPubspecService(dependencies: {}))));

      await expectLater(
        runner.run(['cocoon', 'index', 'add', 'Txn', 'name']),
        throwsA(isA<ReadableException>()),
      );
      expect(process.calls, isEmpty);
    });
  });

  group('CocoonBuildCommand', () {
    test('has correct command name', () {
      expect(CocoonBuildCommand(MockCocoonService()).name, equals('build'));
    });

    test('runs build_runner build -d', () async {
      final process = MockProcessRunner();
      final runner = _runner(process, <int>[]);
      await runner.run(['cocoon', 'build']);

      final call = process.calls.single;
      expect(call.arguments, equals(['run', 'build_runner', 'build', '-d']));
      expect(call.inheritedStdio, isTrue);
    });

    test('propagates a failing exit code', () async {
      final exits = <int>[];
      final runner = _runner(MockProcessRunner()..nextExitCode = 1, exits);
      await runner.run(['cocoon', 'build']);
      expect(exits, equals([1]));
    });
  });
}

ICocoonService _service(MockProcessRunner process,
    [MockPubspecService? pubspec]) {
  return CocoonService(
    MockLoggerService(),
    pubspec ?? MockPubspecService(),
    MockMasonService(),
    process,
  );
}

/// A runner with the real [CocoonCommand] wired to mocks. No project
/// configuration service is registered: `cocoon` subcommands work without
/// `butterfly init`. Exit calls are recorded in [exits].
CommandRunner<void> _runner(MockProcessRunner process, List<int> exits) {
  getIt.reset();
  getIt.registerSingleton<ILoggerService>(MockLoggerService());
  getIt.registerSingleton<IDirectoryService>(MockDirectoryService());

  final runner = CommandRunner<void>('test', 'Test runner');
  runner.addCommand(CocoonCommand(_service(process), exitFn: exits.add));
  return runner;
}
