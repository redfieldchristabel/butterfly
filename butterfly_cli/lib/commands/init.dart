import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/services/project_configuration.dart';
import 'package:butterfly_cli/services/pubspec.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

class InitCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Initializes a Flutter project for butterfly pattern.';

  @override
  String get name => 'init';

  @override
  Future<void> run() async {
    ensureRoot();

    ProjectConfiguration? defaultValue;

    if (projectConfigurationService.exists()) {
      projectConfigurationService.ensureValid();

      logger.warn('You seem to have an existing project configuration');
      final ConfigExistAction action = logger.chooseOne<ConfigExistAction>(
          'What do you want to do',
          choices: ConfigExistAction.values,
          defaultValue: ConfigExistAction.skip,
          display: (choice) => '${choice.name}, $description');

      switch (action) {
        case ConfigExistAction.skip:
          info('Skipping initialization, exiting...');
          exit(0);
        case ConfigExistAction.overwrite:
          defaultValue = projectConfigurationService.configuration;
          detail('Use default value for new initialization');
          break;
        case ConfigExistAction.replace:
          defaultValue = null;
          break;
      }
    }

    await projectConfigurationService.create(defaultValue);

    info('Project initialized successfully');

    detail(
        'Add butterfly dependency to pubspec according to configuration file');

    final Uri gitUrl =
        Uri.parse('git@github.com:redfieldchristabel/butterfly.git');

    // if(projectConfigurationService.configuration.useCore){
    //   detail('Add butterfly core dependency to pubspec according to configuration file');
    //   pubspecService.addDependency('', option: GitDependency(gitUrl, path: 'packages/auth_management' ));
    // }

    if (projectConfigurationService.configuration.useAuth) {
      detail(
          'Add Butterfly auth dependency to pubspec according to configuration file');
      pubspecService.addDependency('auth_management',
          option: GitDependency(gitUrl, path: 'packages/auth_management'));
    }

    if(projectConfigurationService.configuration.useRouter){
      detail(
          'Add Butterfly router dependency to pubspec according to configuration file');
      pubspecService.addDependency('router_management',
          option: GitDependency(gitUrl, path: 'packages/router_management'));
    }

    // TODO: add butterfly core to pubspec yaml.
  }
}

enum ConfigExistAction {
  skip('Do noting and exit'),
  overwrite('Overwrite existing project configuration,'
      ' use as default value for new initialization'),
  replace('Replace existing project configuration and reinitialize'),
  ;

  const ConfigExistAction(this.description);

  final String description;
}
