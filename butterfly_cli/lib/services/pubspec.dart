import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_manager/pubspec_manager.dart';
import 'package:yaml_edit/yaml_edit.dart';

class PubspecService with ButterflyLogger {
  late final File _pubspecFile;

  PubspecService() {
    frameworkService.ensureRootDirectory();
    _pubspecFile = File('pubspec.yaml');
  }

  PubSpec get _pubspec {
    detail('Read pubspec.yaml file');
    return PubSpec.load();
    // return Pubspec.parse(_pubspecFile.readAsStringSync());
  }

  void addDependency(final String dependency, {final Dependency? option}) {
    final editor = YamlEditor(_pubspecFile.readAsStringSync());
    editor.update(['dependencies'], dependency);
    detail('Add dependency $dependency');
    _pubspecFile.writeAsStringSync(editor.toString());
    detail('Write to pubspec.yaml file');
  }

  void addDependencyX(String name) {
    final curDir = Directory.current.path;
    frameworkService.ensureRootDirectory();

    print("cur dir ${Directory.current.path}");
    // ensureFlutter();

    detail('Add dependency $name');
    final pubspec = PubSpec.load();
    final builder = DependencyBuilderGit(
      name: name,
      url: 'git@github.com:redfieldchristabel/butterfly.git',
      path: 'packages/$name',
      ref: 'develop',
    );
    pubspec.dependencies.add(builder);
    detail('Write to pubspec.yaml file');
    pubspec.save();

    frameworkService.changeWorkingDirectory(curDir);
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
