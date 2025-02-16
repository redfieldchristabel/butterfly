import 'dart:convert';
import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/framework.dart';
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

  Future<void> addDependency(final String name, {bool dev = false}) async {
    final curDir = Directory.current.path;
    frameworkService.ensureRootDirectory();

    info("cur dir ${Directory.current.path}");

    final pubspec = PubSpec.loadFromPath(_pubspecFile.path);

    detail('Check if $name dependency exist');
    final iDependency = dev ? pubspec.devDependencies : pubspec.devDependencies;
    if (iDependency.exists(name)) {
      detail('$name dependency already exist, skip');
      return;
    }

    detail('Dependency not exist, asking to add ${iDependency.exists(name)}');

    // ensureFlutter();
    detail('Add dependency $name');

    final add = logger.confirm('Add $name dependency', defaultValue: true);

    if (add) {
      final mode = stdout.hasTerminal
          ? ProcessStartMode.inheritStdio
          : ProcessStartMode.normal;
      final process = await Process.start(
        'flutter',
        ['pub', 'add', if (dev) '--dev', name],
        mode: mode,
        runInShell: true,
      );

      // Pipe stdout and stderr to the console:
      process.stdout
          .transform(utf8.decoder)
          .listen((data) => stdout.write(data));
      process.stderr
          .transform(utf8.decoder)
          .listen((data) => stderr.write(data));

      await process.exitCode;
    }
    return;

    final dependency = DependencyBuilderPubHosted(name: name);
    if (dev) {
      pubspec.devDependencies.add(dependency);
    } else {
      pubspec.dependencies.add(dependency);
    }
    detail('Write to pubspec.yaml file');
    pubspec.save();
    frameworkService.changeWorkingDirectory(curDir);
  }

  void addButterflyDependency(String name) {
    final curDir = Directory.current.path;
    frameworkService.ensureRootDirectory();

    print("cur dir ${Directory.current.path}");

    final pubspec = PubSpec.loadFromPath(_pubspecFile.path);

    detail('Check if $name dependency exist');
    if (pubspec.dependencies.exists(name)) {
      detail('$name dependency already exist, skip');
      return;
    }

    // ensureFlutter();
    detail('Add dependency $name');
    pubspec.dependencies.add(DependencyBuilderGit(
      name: name,
      url: 'git@github.com:redfieldchristabel/butterfly.git',
      path: 'packages/$name',
      ref: 'develop',
    ));
    detail('Write to pubspec.yaml file');
    pubspec.save();
    frameworkService.changeWorkingDirectory(curDir);
  }

  void ensureFlutter() {
    if (!_pubspec.dependencies.exists('flutter')) {
      throw ReadableException(
          title: 'Not Flutter Project',
          message: 'Flutter SDK not found in pubspec.yaml',
          code: 66,
          hint: 'Try again with flutter project');
    }
  }

  Version get version {
    detail('Get version from pubspec.yaml file');
    return _pubspec.version;
  }
}

final PubspecService pubspecService = PubspecService();
