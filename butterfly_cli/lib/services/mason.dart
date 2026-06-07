import 'dart:io';

import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/model_gen_params.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:dart_style/dart_style.dart';
import 'package:mason/mason.dart';

class FileAlreadyExistsException implements Exception {
  final String path;
  FileAlreadyExistsException(this.path);

  @override
  String toString() =>
      'File already exists at $path. Set overwrite=true to replace it.';
}

class MasonService implements IMasonService {
  final ILoggerService _logger;

  MasonService(this._logger);

  @override
  Future<void> generateModel(ModelGenParams params,
      {bool overwrite = false}) async {
    final targetFile = File('${params.path.path}/${params.fileName}.dart');
    if (targetFile.existsSync() && !overwrite) {
      throw FileAlreadyExistsException(targetFile.absolute.path);
    }

    final generator = await _getGenerator('mason/model');

    _logger.detail('generating directory to create this model');

    if (!params.path.existsSync()) {
      _logger.detail("Directory not exist, creating");
      await params.path.create(recursive: true);
    }
    final target = DirectoryGeneratorTarget(params.path);
    _logger.detail('generating model using mason');
    final files = await generator.generate(
      target,
      vars: <String, dynamic>{
        'name': params.name,
        'fileName': params.fileName,
        'isSerializable': params.serializable
      },
    );

    _logger.info('model generated successfully');

    final generatedFile = File(files.first.path);
    String generatedFileRaw = generatedFile.readAsStringSync();

    final formatedFile =
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
            .format(generatedFileRaw);

    generatedFile.writeAsStringSync(formatedFile);
  }

  @override
  Future<void> generateImmutableModel(ModelGenParams params,
      {bool overwrite = false}) async {
    final targetFile = File('${params.path.path}/${params.fileName}.dart');
    if (targetFile.existsSync() && !overwrite) {
      throw FileAlreadyExistsException(targetFile.absolute.path);
    }

    final generator = await _getGenerator('mason/immutable_model');

    _logger.detail('generating directory to create this model');

    if (!params.path.existsSync()) {
      _logger.detail("Directory not exist, creating");
      await params.path.create(recursive: true);
    }
    final target = DirectoryGeneratorTarget(params.path);
    _logger.detail('generating model using mason');
    final files = await generator.generate(
      target,
      vars: <String, dynamic>{
        'name': params.name,
        'fileName': params.fileName,
        'isSerializable': params.serializable
      },
    );

    _logger.info('model generated successfully');

    final generatedFile = File(files.first.path);
    String generatedFileRaw = generatedFile.readAsStringSync();

    final formatedFile =
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
            .format(generatedFileRaw);

    generatedFile.writeAsStringSync(formatedFile);
  }

  @override
  Future<void> generateCoreService() =>
      _generateButterflyService('core_service');

  @override
  Future<void> generateThemeService() =>
      _generateButterflyService('theme_service');

  @override
  Future<void> generateAuthService() =>
      _generateButterflyService('auth_service');

  Future<void> _generateButterflyService(String name) async {
    final generator = await _getGenerator('mason/$name');
    _logger.detail('generating directory to create this service');

    final target = DirectoryGeneratorTarget(Directory('lib/services'));
    _logger.detail('generating service using mason');
    final files = await generator.generate(target);

    _logger.info(
        'service generated successfully at ${File(files.first.path).absolute.uri}');
  }

  @override
  Future<void> generateRouteFile(RouterType type) async {
    final generator = await switch (type) {
      RouterType.goRouter => _getGenerator('mason/go_router_route_file'),
      RouterType.other => throw UnimplementedError(),
    };

    _logger.detail('generating directory to create this service');

    final target = DirectoryGeneratorTarget(Directory('lib'));
    _logger.detail('generating service using mason');
    final files = await generator.generate(target);

    _logger.info(
        'service generated successfully at ${File(files.first.path).absolute.uri}');
  }

  Future<MasonGenerator> _getGenerator(String path) async {
    _logger.detail('fetching $path mason from github');
    final brick = Brick.git(
      GitPath(
        'https://github.com/redfieldchristabel/butterfly',
        path: path,
        ref: 'master',
      ),
    );
    return await MasonGenerator.fromBrick(brick);
  }
}
