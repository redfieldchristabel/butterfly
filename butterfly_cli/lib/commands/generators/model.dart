import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/mason.dart';
import 'package:recase/recase.dart';

// TODO: support convert to serializable model instead of generating one
class ModelGeneratorCommand extends Command with ButterflyLogger {
  @override
  String get description => 'Generate a model with JsonSerializable';

  @override
  String get name => 'model';

  @override
  List<String> get aliases => ['m', 'mdl'];

  ModelGeneratorCommand() {
    argParser.addFlag('serializable',
        abbr: 's', help: 'Generate serializable version', defaultsTo: true);
    argParser.addOption('path',
        abbr: 'p',
        help: 'Path to generate this model,\n'
            'will start from "project_root/lib/models" directory.\n'
            'If provided, "auth" as param, the directory will be\n'
            '"project_root/lib/models/auth".');

    //   TODO: support immutable model
  }

  @override
  Future run() async {
    ensureRoot();

    var className = argResults!.rest.firstOrNull;
    final serializable = argResults!.flag('serializable');
    final path = argResults!.option('path');

    if (className == null) {
      throw UsageException(
          'Please provide a class name\n'
          'Example: flutter generate model User --serializable --path=auth',
          usage);
    }

    detail("Generate fileName base on $className");
    String fileName = className.snakeCase;
    if (path != null && className.startsWith(path.snakeCase)) {
      detail('path start with class name');
      detail('fileName will be ${className.substring(path.length)}');
      fileName = className.substring(path.length).trim();
    }

    // Handle cases like AuthUsers -> User
    final pathRecase = ReCase(path ?? '');
    final classNameRecase = ReCase(className);
    if (path != null &&
        classNameRecase.pascalCase.startsWith(pathRecase.pascalCase)) {
      fileName = classNameRecase.pascalCase
          .substring(pathRecase.pascalCase.length)
          .trim();
      if (fileName.isEmpty) {
        printUsage();
        throw ReadableException(
          title: 'Invalid class name',
          code: 66,
          message: 'Model name cannot be the same as the path',
          hint: 'Please provide a valid class name or remove the path',
        );
      }
    }

    final directory = Directory(
        '${Directory.current.path}/lib/models/${pathRecase.snakeCase}');
    // Check if the file already exists
    detail('Check if the file already exists');
    final generatedFile = File('${directory.path}/${fileName.snakeCase}.dart');
    detail('File not exist, creating.  ${generatedFile.path}');

    if (generatedFile.existsSync()) {
      info('File already exists at ${generatedFile.absolute.path}');
      final bool overWrite = logger.confirm('Overwrite?', defaultValue: true);

      if (!overWrite) {
        info('Skipping...');
        return;
      }
    }

    final params = ModelGenParams(
      name: className, // Keep the original class name
      path: directory,
      serializable: serializable,
      fileName: fileName.snakeCase, // Use the adjusted filename
    );

    await masonService.generateModel(params);
  }
}
