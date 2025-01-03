import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:pub_semver/pub_semver.dart';
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

  void addDependencyX(String name, {Dependency? dependency}) {
    dependency ??= HostedDependency();
    detail('Add dependency $name');
    final pubspec = Pubspec.parse(_pubspecFile.readAsStringSync());
    pubspec.dependencies.addEntries([MapEntry(name, dependency)]);
    _pubspecFile.writeAsStringSync(pubspec.toString());
    detail('Write to pubspec.yaml file');
  }

  void ensureFlutter() {
    if (_pubspec.flutter == null) {
      throw ReadableException(
          title: 'Not Flutter Project',
          message: 'Flutter SDK not found in pubspec.yaml',
          code: 66,
          hint: 'Try again with flutter project');
    }
  }

  Version get version {
    detail('Get version from pubspec.yaml file');
    return _pubspec.version!;
  }
}

final PubspecService pubspecService = PubspecService();
