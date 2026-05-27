import 'dart:io';

import 'package:butterfly_cli/commands/generators/version.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:test/test.dart';

/// A helper that creates a minimal Flutter-like project structure
/// in a temporary directory and returns the path.
String _createTempProject() {
  final tmpDir = Directory.systemTemp.createTempSync('butterfly_cli_test_');
  final libDir = Directory('${tmpDir.path}/lib');
  libDir.createSync();

  // Write a minimal pubspec.yaml with a version
  File('${tmpDir.path}/pubspec.yaml').writeAsStringSync(
    'name: test_project\n'
    'version: 1.2.3\n'
    'environment:\n'
    '  sdk: ^3.5.0\n',
  );

  return tmpDir.path;
}

void main() {
  group('VersionGeneratorCommand', () {
    late String originalCwd;

    setUp(() {
      originalCwd = Directory.current.path;
    });

    tearDown(() {
      Directory.current = originalCwd;
    });

    test('has correct command name', () {
      final cmd = VersionGeneratorCommand();
      expect(cmd.name, equals('version'));
    });

    test('has correct description', () {
      final cmd = VersionGeneratorCommand();
      expect(cmd.description, contains('version.dart'));
    });

    test('generates version.dart file from pubspec version', () {
      final projectPath = _createTempProject();
      Directory.current = projectPath;

      final cmd = VersionGeneratorCommand();
      cmd.run();

      // Check the file was created
      final generatedFile = File('${projectPath}/lib/version.dart');
      expect(generatedFile.existsSync(), isTrue);

      final content = generatedFile.readAsStringSync();
      expect(content, contains('kVersion'));
      expect(content, contains('1.2.3'));

      // Cleanup
      Directory(projectPath).deleteSync(recursive: true);
    });

    test('overwrites existing version.dart', () {
      final projectPath = _createTempProject();
      Directory.current = projectPath;

      // Create an existing version.dart with stale content
      File('${projectPath}/lib/version.dart').writeAsStringSync(
        'const String kVersion = \'0.0.0-old\';',
      );

      final cmd = VersionGeneratorCommand();
      cmd.run();

      final content = File('${projectPath}/lib/version.dart').readAsStringSync();
      expect(content, contains('1.2.3'));
      expect(content, isNot(contains('0.0.0-old')));

      Directory(projectPath).deleteSync(recursive: true);
    });
  });
}
