import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:dart_style/dart_style.dart';
import 'package:mason/mason.dart';

class MasonService with ButterflyLogger {
  Future<void> generateModel(ModelGenParams params) async {
    final generator = await _getGenerator('mason/model');

    detail('generating directory to create this model');

    if (!params.path.existsSync()) {
      detail("Directory not exist, creating");
      await params.path.create(recursive: true);
    }
    final target = DirectoryGeneratorTarget(params.path);
    detail('generating model using mason');
    final files = await generator.generate(
      target,
      vars: <String, dynamic>{
        'name': params.name,
        'fileName': params.fileName,
        'isSerializable': params.serializable
      },
    );

    info('model generated successfully');

    final generatedFile = File(files.first.path);
    String generatedFileRaw = generatedFile.readAsStringSync();

    final formatedFile =
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
            .format(generatedFileRaw);

    generatedFile.writeAsStringSync(formatedFile);
  }

  Future<void> generateImmutableModel(ModelGenParams params) async {
    final generator = await _getGenerator('mason/immutable_model');

    detail('generating directory to create this model');

    if (!params.path.existsSync()) {
      detail("Directory not exist, creating");
      await params.path.create(recursive: true);
    }
    final target = DirectoryGeneratorTarget(params.path);
    detail('generating model using mason');
    final files = await generator.generate(
      target,
      vars: <String, dynamic>{
        'name': params.name,
        'fileName': params.fileName,
        'isSerializable': params.serializable
      },
    );

    info('model generated successfully');

    final generatedFile = File(files.first.path);
    String generatedFileRaw = generatedFile.readAsStringSync();

    final formatedFile =
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
            .format(generatedFileRaw);

    generatedFile.writeAsStringSync(formatedFile);
  }

  Future<void> generateCoreService() =>
      _generateButterflyService('core_service');

  Future<void> generateThemeService() =>
      _generateButterflyService('theme_service');

  Future<void> generateAuthService() =>
      _generateButterflyService('auth_service');

  Future<void> _generateButterflyService(String name) async {
    final generator = await _getGenerator('mason/$name');
    detail('generating directory to create this service');

    final target = DirectoryGeneratorTarget(Directory('lib/services'));
    detail('generating service using mason');
    final files = await generator.generate(target);

    info(
        'service generated successfully at ${File(files.first.path).absolute.uri}');
  }

  Future<void> generateRouteFile(RouterType type) async {
    final generator = await switch (type) {
      RouterType.goRouter => _getGenerator('mason/go_router_route_file'),
      RouterType.other => throw UnimplementedError(),
    };

    detail('generating directory to create this service');

    final target = DirectoryGeneratorTarget(Directory('lib'));
    detail('generating service using mason');
    final files = await generator.generate(target);

    info(
        'service generated successfully at ${File(files.first.path).absolute.uri}');
  }

  Future<MasonGenerator> _getGenerator(String path) async {
    detail('fetching $path mason from github');
    final brick = Brick.git(
      GitPath(
        'https://github.com/redfieldchristabel/butterfly',
        path: path,
        ref: 'develop',
      ),
    );
    return await MasonGenerator.fromBrick(brick);
  }
}

final masonService = MasonService();

class ModelGenParams {
  final String name;
  final String fileName;
  final Directory path;
  final bool serializable;

  ModelGenParams({
    required this.name,
    required this.fileName,
    required this.path,
    required this.serializable,
  });
}
