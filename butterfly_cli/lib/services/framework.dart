import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/services/mason.dart';

class FrameworkService with ButterflyLogger {
  bool directoryIsRoot = false;

  T askInput<T>({required String question}) {
    assert(T == String || T == int);
    print(question);
    final answer = stdin.readLineSync();

    return (T == int ? int.parse(answer!) : answer) as T;
  }

  /// {@template ensureRootDirectory}
  /// Ensure current working directory are at root of the project.
  ///
  /// This method will search up until find file named `pubspec.yaml` and
  /// directory named `lib` in same directory.
  ///
  /// If not found in the working directory, it will go up one directory and
  /// try again. This will be continued until it reach the root directory.
  /// {@endtemplate}
  void ensureRootDirectory() {
    if (directoryIsRoot) {
      detail('Current directory is already at root of the project');
      return;
    }
    detail('Ensure current working directory are at root of the project');
    var current = Directory.current;
    while (true) {
      if (File('${current.path}/pubspec.yaml').existsSync() &&
          Directory('${current.path}/lib').existsSync()) {
        Directory.current = current;
        info('Set $current as working directory');
        break;
      }
      if (current.path == '/') {
        // TODO: change to throw
        logger.err('Unable to find root directory of the project');
        exit(1);
      }
      detail('Current directory seem to not be root project\'s directory');
      current = current.parent;
      detail('Trying $current directory');
    }
    detail('Found project\'s root directory');
    directoryIsRoot = true;
  }

  void ensureFlutterProject() {
    ensureRootDirectory();
  }

  void ensureLibFolder() {
    ensureRootDirectory();
    changeWorkingDirectory('lib');
  }

  void changeWorkingDirectory(String dir) {
    detail('Changing directory to $dir');
    directoryIsRoot = false;
    Directory.current = dir;
  }

  Future<void> createFrameworkService() async {
    info('Creating framework service');
    detail('Check if framework.dart file already exist in services directory');

    final dir = Directory('services');
    if (!dir.existsSync()) {
      info('Directory not exist, creating');
      dir.createSync();
    }

    final file = File('lib/services/framework.dart');
    if (!file.existsSync()) {
      info('File not exist, creating');
      //   TODO: use mason generator
      await masonService.generateFrameworkService();
    }

    info('Framework service created');
  }

  Future<void> createThemeService() async {
    info('Creating theme service');
    detail('Check if theme.dart file already exist in services directory');

    final dir = Directory('services');
    if (!dir.existsSync()) {
      info('Directory not exist, creating');
      dir.createSync();
    }

    final file = File('lib/services/theme.dart');
    if (!file.existsSync()) {
      info('File not exist, creating');
      //   TODO: use mason generator
      await masonService.generateThemeService();
    }

    info('Framework service created');
  }

  Future<void> createAuthService() async {
    info('Creating framework service');
    detail('Check if auth.dart file already exist in services directory');

    final dir = Directory('services');
    if (!dir.existsSync()) {
      info('Directory not exist, creating');
      dir.createSync();
    }

    final file = File('lib/services/auth_service.dart');
    if (!file.existsSync()) {
      info('File not exist, creating');
      //   TODO: use mason generator
      await masonService.generateFrameworkService();
    }

    info('Auth service created');
  }

  Future<void> createRouteFile(RouterType type) async {
    info('Creating route file');
    detail('Check if route.dart file already exist in lib directory');

    final file = File('lib/route.dart');
    if (!file.existsSync()) {
      info('File not exist, creating');
      //   TODO: use mason generator
      await masonService.generateRouteFile(type);
    }

    info('Route file created');
  }
}

final FrameworkService frameworkService = FrameworkService();
