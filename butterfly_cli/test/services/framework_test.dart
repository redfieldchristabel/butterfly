import 'dart:io';

import 'package:butterfly_cli/services/framework.dart';
import 'package:test/test.dart';

/// Creates a temporary directory with a minimal project structure
/// (`pubspec.yaml` + `lib/`).
String _createProjectRoot() {
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

/// Creates a temporary directory that does NOT look like a project root
/// (no `pubspec.yaml` + `lib/` pair).
String _createNonRoot() {
  final tmpDir = Directory.systemTemp.createTempSync('butterfly_cli_not_root_');
  // Just an empty directory without pubspec.yaml and lib
  return tmpDir.path;
}

void main() {
  group('FrameworkService', () {
    late String originalCwd;

    setUp(() {
      originalCwd = Directory.current.path;
      // Reset the singleton state between tests
      frameworkService.directoryIsRoot = false;
    });

    tearDown(() {
      Directory.current = originalCwd;
    });

    group('ensureRootDirectory', () {
      test('detects project root from within the root', () {
        final projectPath = _createProjectRoot();
        Directory.current = projectPath;

        expect(frameworkService.directoryIsRoot, isFalse);
        frameworkService.ensureRootDirectory();
        expect(frameworkService.directoryIsRoot, isTrue);

        Directory(projectPath).deleteSync(recursive: true);
      });

      test('detects project root from a subdirectory (walks up)', () {
        final projectPath = _createProjectRoot();
        // Create a nested subdirectory to mimic being deep in the project
        final nestedDir = Directory('${projectPath}/lib/services');
        nestedDir.createSync(recursive: true);
        Directory.current = nestedDir.path;

        expect(frameworkService.directoryIsRoot, isFalse);
        frameworkService.ensureRootDirectory();

        // After ensure, Directory.current should be the project root,
        // and the flag should be set
        expect(frameworkService.directoryIsRoot, isTrue);
        expect(
          Directory.current.path,
          equals(projectPath),
        );

        Directory(projectPath).deleteSync(recursive: true);
      });

      test('is idempotent when already at root', () {
        final projectPath = _createProjectRoot();
        Directory.current = projectPath;

        frameworkService.ensureRootDirectory();
        final flagsBefore = frameworkService.directoryIsRoot;

        // Call again — should short-circuit on the flag
        frameworkService.ensureRootDirectory();

        expect(flagsBefore, isTrue);
        expect(frameworkService.directoryIsRoot, isTrue);

        Directory(projectPath).deleteSync(recursive: true);
      });

      test('resets flag after changeWorkingDirectory', () {
        final projectPath = _createProjectRoot();
        Directory.current = projectPath;

        frameworkService.ensureRootDirectory();
        expect(frameworkService.directoryIsRoot, isTrue);

        frameworkService.changeWorkingDirectory('lib');
        expect(frameworkService.directoryIsRoot, isFalse);

        Directory(projectPath).deleteSync(recursive: true);
      });

      test('sets Directory.current to root when called from subdirectory', () {
        final projectPath = _createProjectRoot();
        final subDir = Directory('${projectPath}/some/deep/path');
        subDir.createSync(recursive: true);
        Directory.current = subDir.path;

        frameworkService.ensureRootDirectory();
        expect(Directory.current.path, equals(projectPath));

        Directory(projectPath).deleteSync(recursive: true);
      });
    });

    group('ensureFlutterProject', () {
      test('calls ensureRootDirectory (delegation test)', () {
        final projectPath = _createProjectRoot();
        Directory.current = projectPath;

        // Should not throw — delegates to ensureRootDirectory
        frameworkService.ensureFlutterProject();
        expect(frameworkService.directoryIsRoot, isTrue);

        Directory(projectPath).deleteSync(recursive: true);
      });
    });

    group('ensureLibFolder', () {
      test('changes to lib/ after ensuring root', () {
        final projectPath = _createProjectRoot();
        Directory.current = projectPath;

        frameworkService.ensureLibFolder();
        // Current dir should now be the lib/ path
        expect(Directory.current.path, endsWith('/lib'));
        // The flag should be reset since changeWorkingDirectory was called
        expect(frameworkService.directoryIsRoot, isFalse);

        Directory(projectPath).deleteSync(recursive: true);
      });
    });

    group('changeWorkingDirectory', () {
      test('changes the working directory and resets the flag', () {
        final projectPath = _createProjectRoot();
        Directory.current = projectPath;
        frameworkService.directoryIsRoot = true;

        frameworkService.changeWorkingDirectory('lib');
        expect(Directory.current.path, endsWith('/lib'));
        expect(frameworkService.directoryIsRoot, isFalse);

        Directory(projectPath).deleteSync(recursive: true);
      });
    });
  });
}
