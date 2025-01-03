import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:butterfly_cli/services/project_configuration.dart';
import 'package:butterfly_cli/services/pubspec.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

class InitCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Initializes a Flutter project for butterfly pattern.';

  @override
  bool get takesArguments => false;

  @override
  String get name => 'init';

  @override
  void run() {
    ensureRoot();

    final config = projectConfigurationService.create();

    info("Creating project Structure");

    detail('Changing directory to lib');
    Directory.current = '${Directory.current.path}/lib';

    detail("Check if models directory exist");

    _checkAndCreateDirectory('models');
    _checkAndCreateDirectory('services');
    _checkAndCreateDirectory('screens');
    _checkAndCreateDirectory('widgets');

    info('Project structure created successfully');

    info('Creating initial files');

    if (config.useCore) {
      // TODO: import code library
      pubspecService.addDependencyX(
        "core_management",
        dependency: GitDependency(
          Uri.parse('git@github.com:redfieldchristabel/butterfly.git'),
          path: 'packages/core_management',
          ref: 'master',
        ),
      );
      frameworkService.createFrameworkService();
      frameworkService.createThemeService();
    }

    if (config.useAuth) {
      // TODO: import auth library
      frameworkService.createAuthService();
    }

    if (config.useRouter && config.routerType != RouterType.other) {
      // TODO: import router type library
      frameworkService.createRouteFile(config.routerType!);
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
