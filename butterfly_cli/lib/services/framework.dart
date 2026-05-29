import 'dart:io';

import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/project_configuration.dart';

class FrameworkService implements IDirectoryService {
  final ILoggerService _logger;

  FrameworkService(this._logger);

  @override
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
  @override
  void ensureRootDirectory() {
    if (directoryIsRoot) {
      _logger.detail('Current directory is already at root of the project');
      return;
    }
    _logger.detail('Ensure current working directory are at root of the project');
    var current = Directory.current;
    while (true) {
      if (File('${current.path}/pubspec.yaml').existsSync() &&
          Directory('${current.path}/lib').existsSync()) {
        Directory.current = current;
        _logger.info('Set $current as working directory');
        break;
      }
      if (current.path == '/') {
        // TODO: change to throw
        _logger.err('Unable to find root directory of the project');
        exit(1);
      }
      _logger.detail('Current directory seem to not be root project\'s directory');
      current = current.parent;
      _logger.detail('Trying $current directory');
    }
    _logger.detail('Found project\'s root directory');
    directoryIsRoot = true;
  }

  @override
  void ensureFlutterProject() {
    ensureRootDirectory();
  }

  @override
  void ensureLibFolder() {
    ensureRootDirectory();
    changeWorkingDirectory('lib');
  }

  @override
  void changeWorkingDirectory(String dir) {
    _logger.detail('Changing directory to $dir');
    directoryIsRoot = false;
    Directory.current = dir;
  }

  Future<void> createCoreService() async {
    _logger.info('Creating core service');
    _logger.detail('Check if core.dart file already exist in services directory');

    final dir = Directory('services');
    if (!dir.existsSync()) {
      _logger.info('Directory not exist, creating');
      dir.createSync();
    }

    final file = File('lib/services/core.dart');
    if (!file.existsSync()) {
      _logger.info('File not exist, creating');
    }

    _logger.info('Core service created');
  }

  Future<void> createThemeService() async {
    _logger.info('Creating theme service');
    _logger.detail('Check if theme.dart file already exist in services directory');

    final dir = Directory('services');
    if (!dir.existsSync()) {
      _logger.info('Directory not exist, creating');
      dir.createSync();
    }

    final file = File('lib/services/theme.dart');
    if (!file.existsSync()) {
      _logger.info('File not exist, creating');
    }

    _logger.info('Framework service created');
  }

  Future<void> createAuthService() async {
    _logger.info('Creating auth service');
    _logger.detail('Check if auth.dart file already exist in services directory');

    final dir = Directory('services');
    if (!dir.existsSync()) {
      _logger.info('Directory not exist, creating');
      dir.createSync();
    }

    final file = File('lib/services/auth_service.dart');
    if (!file.existsSync()) {
      _logger.info('File not exist, creating');
    }

    _logger.info('Auth service created');
  }

  Future<void> createRouteFile(RouterType type) async {
    _logger.info('Creating route file');
    _logger.detail('Check if route.dart file already exist in lib directory');

    final file = File('lib/route.dart');
    if (!file.existsSync()) {
      _logger.info('File not exist, creating');
    }

    _logger.info('Route file created');
  }
}
