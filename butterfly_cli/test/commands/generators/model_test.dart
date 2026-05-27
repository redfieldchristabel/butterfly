import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/generators/model.dart';
import 'package:butterfly_cli/commands/generators/index.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:test/test.dart';

/// Returns a [CommandRunner] with the generate command registered.
CommandRunner<void> _runner() {
  final runner = CommandRunner<void>('test', 'Test runner');
  runner.addCommand(GenerateCommand());
  return runner;
}

void main() {
  group('ModelGeneratorCommand', () {
    test('has correct command name', () {
      final cmd = ModelGeneratorCommand();
      expect(cmd.name, equals('model'));
    });

    test('has aliases', () {
      final cmd = ModelGeneratorCommand();
      expect(cmd.aliases, containsAll(['m', 'mdl']));
    });

    test('description mentions model generation', () {
      final cmd = ModelGeneratorCommand();
      expect(cmd.description, contains('model'));
      expect(cmd.description, contains('JsonSerializable'));
    });

    group('argument definitions', () {
      test('has --serializable flag', () {
        final cmd = ModelGeneratorCommand();
        expect(cmd.argParser.options.containsKey('serializable'), isTrue);
      });

      test('has --immutable flag', () {
        final cmd = ModelGeneratorCommand();
        expect(cmd.argParser.options.containsKey('immutable'), isTrue);
      });

      test('has --path option', () {
        final cmd = ModelGeneratorCommand();
        expect(cmd.argParser.options.containsKey('path'), isTrue);
      });
    });

    group('argument parsing', () {
      test('parses simple class name', () {
        final results = _runner().parse(['generate', 'model', 'User']);
        // The subcommand result is nested inside the 'generate' command
        expect(results.command?.name, equals('generate'));
        final genResult = results.command!;
        expect(genResult.command?.name, equals('model'));
        final modelResult = genResult.command!;
        expect(modelResult.rest, contains('User'));
      });

      test('defaults serializable to true', () {
        final results = _runner().parse(['generate', 'model', 'User']);
        final modelResult = results.command!.command!;
        expect(modelResult['serializable'], isTrue);
      });

      test('defaults immutable to false', () {
        final results = _runner().parse(['generate', 'model', 'User']);
        final modelResult = results.command!.command!;
        expect(modelResult['immutable'], isFalse);
      });

      test('defaults path to null', () {
        final results = _runner().parse(['generate', 'model', 'User']);
        final modelResult = results.command!.command!;
        expect(modelResult['path'], isNull);
      });

      test('parses --no-serializable', () {
        final results =
            _runner().parse(['generate', 'model', 'User', '--no-serializable']);
        final modelResult = results.command!.command!;
        expect(modelResult['serializable'], isFalse);
      });

      test('parses --immutable', () {
        final results =
            _runner().parse(['generate', 'model', 'User', '--immutable']);
        final modelResult = results.command!.command!;
        expect(modelResult['immutable'], isTrue);
      });

      test('parses --path', () {
        final results = _runner()
            .parse(['generate', 'model', 'AuthUser', '--path', 'auth']);
        final modelResult = results.command!.command!;
        expect(modelResult['path'], equals('auth'));
      });

      test('parses all arguments together', () {
        final results = _runner().parse([
          'generate',
          'model',
          'Customer',
          '--serializable',
          '--path',
          'billing',
          '--immutable',
        ]);
        final modelResult = results.command!.command!;
        expect(modelResult.rest, contains('Customer'));
        expect(modelResult['serializable'], isTrue);
        expect(modelResult['immutable'], isTrue);
        expect(modelResult['path'], equals('billing'));
      });

      test('short flags work: -s, -i, -p', () {
        final results =
            _runner().parse(['generate', 'model', 'Admin', '-s', '-i', '-p', 'system']);
        final modelResult = results.command!.command!;
        expect(modelResult['serializable'], isTrue);
        expect(modelResult['immutable'], isTrue);
        expect(modelResult['path'], equals('system'));
      });
    });

    group('execution', () {
      late String originalCwd;
      late String projectPath;

      setUp(() {
        originalCwd = Directory.current.path;
        projectPath = _createTempProject();
        Directory.current = projectPath;
      });

      tearDown(() {
        Directory.current = originalCwd;
        if (Directory(projectPath).existsSync()) {
          Directory(projectPath).deleteSync(recursive: true);
        }
      });

      test('throws UsageException when no class name provided', () {
        final runner = _runner();
        expect(
          () => runner.run(['generate', 'model']),
          throwsA(isA<UsageException>()),
        );
      });

      test('throws ReadableException when class name equals path', () {
        final runner = _runner();
        expect(
          () => runner.run(['generate', 'model', 'Auth', '--path', 'auth']),
          throwsA(isA<ReadableException>()),
        );
      });
    });
  });
}

/// Creates a temporary project structure needed by ensureRoot().
String _createTempProject() {
  final tmpDir = Directory.systemTemp.createTempSync('butterfly_cli_test_');
  Directory('${tmpDir.path}/lib').createSync();
  File('${tmpDir.path}/pubspec.yaml').writeAsStringSync(
    'name: test_project\n'
    'version: 0.1.0\n'
    'environment:\n'
    '  sdk: ^3.5.0\n',
  );
  return tmpDir.path;
}
