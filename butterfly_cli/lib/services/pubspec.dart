import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:yaml_edit/yaml_edit.dart';

class PubspecService with ButterflyLogger {
  late final File _pubspecFile;

  PubspecService() {
    frameworkService.ensureRootDirectory();
    _pubspecFile = File('pubspec.yaml');
  }

  Pubspec get _pubspec {
    detail('Read pubspec.yaml file');
    return Pubspec.parse(_pubspecFile.readAsStringSync());
  }

  void addDependency(String dependency) {

    final editor = YamlEditor(_pubspecFile.readAsStringSync());
    editor.update(['dependencies'], dependency);
    detail('Add dependency $dependency');
    _pubspecFile.writeAsStringSync(editor.toString());
    detail('Write to pubspec.yaml file');
  }

  void ensureFlutter() {
    if (_pubspec.flutter == null) {
      throw Exception('Unable to find flutter in pubspec.yaml');
    }
  }
}

final PubspecService pubspecService = PubspecService();
