import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/services/project_configuration.dart';
import 'package:yaml_edit/yaml_edit.dart';

class InitCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Initializes a Flutter project for butterfly pattern.';

  @override
  String get name => 'init';

  @override
  void run() {
    ensureRoot();

    if (projectConfigurationService.exists()) {
      projectConfigurationService.ensureValid();
    }


  }
}
