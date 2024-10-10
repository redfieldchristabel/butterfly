import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:yaml_edit/yaml_edit.dart';

class PubspecService with ButterflyLogger {
  late final YamlEditor _pubspecEditor;

  PubspecService() {
    frameworkService.ensureRootDirectory();
    info('Read pubspec.yaml file');
    _pubspecEditor = YamlEditor(File('pubspec.yaml').readAsStringSync());
  }

  void addDependency(String dependency) {
    _pubspecEditor.update(['dependencies'], dependency);
  }
}

final PubspecService pubspecService = PubspecService();
