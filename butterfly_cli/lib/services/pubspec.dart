import 'dart:convert';
import 'dart:io';

import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_manager/pubspec_manager.dart' hide Version;

class PubspecService implements IPubspecService {
  final ILoggerService _logger;
  final IDirectoryService _directoryService;
  late final File _pubspecFile;

  PubspecService(this._logger, this._directoryService) {
    _pubspecFile = File('pubspec.yaml');
  }

  PubSpec get _pubspec {
    _logger.detail('Read pubspec.yaml file');
    return PubSpec.load();
  }

  @override
  Version get version {
    _logger.detail('Get version from pubspec.yaml file');
    return _pubspec.version.semVersion;
  }

  @override
  Future<void> addDependency(final String name, {bool dev = false}) async {
    _directoryService.ensureRootDirectory();

    _logger.info("cur dir ${Directory.current.path}");

    final pubspec = PubSpec.loadFromPath(_pubspecFile.path);

    _logger.detail('Check if $name dependency exist');
    final iDependency = dev ? pubspec.devDependencies : pubspec.dependencies;
    if (iDependency.exists(name)) {
      _logger.detail('$name dependency already exist, skip');
      return;
    }

    _logger.detail('Dependency not exist, asking to add ${iDependency.exists(name)}');

    _logger.detail('Add dependency $name');

    final add = _logger.confirm('Add $name dependency', defaultValue: true);

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
      if (mode == ProcessStartMode.normal) {
        process.stdout
            .transform(utf8.decoder)
            .listen((data) => stdout.write(data));
        process.stderr
            .transform(utf8.decoder)
            .listen((data) => stderr.write(data));
      }

      await process.exitCode;
    }
    return;
  }

  @override
  void addButterflyDependency(String name) {
    final curDir = Directory.current.path;
    _directoryService.ensureRootDirectory();

    print("cur dir ${Directory.current.path}");

    final pubspec = PubSpec.loadFromPath(_pubspecFile.path);

    _logger.detail('Check if $name dependency exist');
    if (pubspec.dependencies.exists(name)) {
      _logger.detail('$name dependency already exist, skip');
      return;
    }

    _logger.detail('Add dependency $name');
    pubspec.dependencies.add(DependencyBuilderGit(
      name: name,
      url: 'git@github.com:redfieldchristabel/butterfly.git',
      path: 'packages/$name',
      ref: 'master',
    ));
    _logger.detail('Write to pubspec.yaml file');
    pubspec.save();
    _directoryService.changeWorkingDirectory(curDir);
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
}
