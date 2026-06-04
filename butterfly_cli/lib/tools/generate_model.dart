import 'dart:async';
import 'dart:io';

import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/model_gen_params.dart';
import 'package:butterfly_cli/services/mason.dart';
import 'package:butterfly_cli/tools/base.dart';
import 'package:dart_mcp/client.dart';
import 'package:recase/recase.dart';

class GenerateModelTool extends BaseTool {
  @override
  Tool get definition => Tool(
        name: 'generate_model',
        description: 'Generate a Dart model class with JsonSerializable support',
        inputSchema: ObjectSchema(
          description: 'Parameters for generating a model',
          properties: {
            'name': Schema.string(
              description:
                  'The class name for the model (e.g. "User", "AuthUser")',
            ),
            'serializable': Schema.bool(
              description:
                  'Generate with JsonSerializable annotation (default: true)',
            ),
            'immutable': Schema.bool(
              description:
                  'Generate immutable model using built_value package (default: false)',
            ),
            'path': Schema.string(
              description:
                  'Subdirectory under lib/models/ (e.g. "auth" puts the file at lib/models/auth/)',
            ),
          },
          required: ['name'],
        ),
      );

  @override
  FutureOr<CallToolResult> call(CallToolRequest request) {
    final args = request.arguments ?? <String, Object?>{};
    final className = args['name'] as String?;

    if (className == null || className.trim().isEmpty) {
      return CallToolResult(
        isError: true,
        content: [TextContent(text: 'Missing required argument: "name"')],
      );
    }

    final serializable = args['serializable'] as bool? ?? true;
    final immutable = args['immutable'] as bool? ?? false;
    final pathArg = args['path'] as String?;

    getIt<IDirectoryService>().ensureRootDirectory();

    final masonService = getIt<IMasonService>();

    String fileName = className.trim().snakeCase;
    if (pathArg != null && className.startsWith(pathArg.snakeCase)) {
      fileName = className.substring(pathArg.length).trim();
    }

    final pathRecase = ReCase(pathArg ?? '');
    final classNameRecase = ReCase(className.trim());
    if (pathArg != null &&
        classNameRecase.pascalCase.startsWith(pathRecase.pascalCase)) {
      fileName = classNameRecase.pascalCase
          .substring(pathRecase.pascalCase.length)
          .trim();
      if (fileName.isEmpty) {
        return CallToolResult(
          isError: true,
          content: [
            TextContent(
              text:
                  'Invalid class name: model name cannot be the same as the path.\n'
                  'Provide a class name that is different from the path (e.g. '
                  'name="AuthUser" with path="auth").',
            ),
          ],
        );
      }
    }

    final directory = Directory(
      '${Directory.current.path}/lib/models/${pathRecase.snakeCase}',
    );

    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final params = ModelGenParams(
      name: className.trim(),
      path: directory,
      serializable: serializable,
      fileName: fileName.snakeCase,
    );

    final generatedFile =
        File('${directory.path}/${fileName.snakeCase}.dart');

    final future = immutable
        ? masonService.generateImmutableModel(params)
        : masonService.generateModel(params);

    return future.then((_) {
      return CallToolResult(
        content: [TextContent(text: 'Model generated at ${generatedFile.absolute.path}')],
      );
    }).catchError((error) {
      if (error is FileAlreadyExistsException) {
        return CallToolResult(
          isError: true,
          content: [TextContent(text: error.toString())],
        );
      }
      throw error;
    });
  }
}
