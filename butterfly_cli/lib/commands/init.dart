import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/project_configuration.dart';

class InitCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Initializes a Flutter project for butterfly pattern.';

  @override
  String get name => 'init';

  @override
  void run() {
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
          exit(0);
        case ConfigExistAction.overwrite:
          defaultValue = projectConfigurationService.configuration;
          break;
        case ConfigExistAction.replace:
          defaultValue = null;
          break;
      }
    }

    projectConfigurationService.init(defaultValue);
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
