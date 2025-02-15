import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:butterfly_cli/services/project_configuration.dart';
import 'package:butterfly_cli/services/pubspec.dart';

class InitCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Initializes a Flutter project for butterfly pattern.';

  @override
  bool get takesArguments => false;

  @override
  String get name => 'init';

  @override
  Future<void> run() async {
    ensureRoot();

    final config = projectConfigurationService.create();

    info("Creating project Structure");

    frameworkService.changeWorkingDirectory('lib');

    detail("Check if models directory exist");

    _checkAndCreateDirectory('models');
    _checkAndCreateDirectory('services');
    _checkAndCreateDirectory('screens');
    _checkAndCreateDirectory('widgets');

    info('Project structure created successfully');

    info('Creating initial files');

    if (config.useCore) {
      // TODO: import code library
      pubspecService.addButterflyDependency("core_management");
      await frameworkService.createFrameworkService();
      await frameworkService.createThemeService();
    }

    if (config.useAuth) {
      pubspecService.addButterflyDependency("auth_management");
      await frameworkService.createAuthService();
    }

    if (config.useRouter && config.routerType != RouterType.other) {
      // TODO: import router type library
      await frameworkService.createRouteFile(config.routerType!);
    }

    info('Initial files created successfully');
  }

  void _checkAndCreateDirectory(final String dirName) {
    final dir = Directory(dirName);
    if (!dir.existsSync()) {
      info("Directory not exist, creating");
      dir.createSync();
    }
  }
}
