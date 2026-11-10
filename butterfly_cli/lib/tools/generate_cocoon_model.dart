import 'dart:async';

import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/services/mason.dart';
import 'package:butterfly_cli/tools/base.dart';
import 'package:dart_mcp/client.dart';

/// MCP tool scaffolding a Cocoon `@Collection` model, mirroring
/// `butterfly generate model <Name> --cocoon`. Only the template file is
/// written; the project's own build_runner generates the adapters.
class GenerateCocoonModelTool extends BaseTool {
  @override
  Tool get definition => Tool(
        name: 'generate_cocoon_model',
        description:
            'Scaffold a Cocoon @Collection model class. Writes the starter '
            'file only; the project\'s own build_runner (cocoon_generator) '
            'generates the adapters. Unlike interactive CLI runs, refuses to '
            'overwrite an existing target file.',
        inputSchema: ObjectSchema(
          description: 'Parameters for generating a Cocoon model',
          properties: {
            'name': Schema.string(
              description: 'The class name for the model (e.g. "Txn")',
            ),
            'path': Schema.string(
              description:
                  'Subdirectory under lib/models/ (e.g. "auth" puts the file at lib/models/auth/)',
            ),
            'collection': Schema.string(
              description:
                  'Cocoon collection path, e.g. "accounts/{accountId}/txns" ({param} segments kept as-is). Defaults to the plural snake_case of the name (Txn -> txns)',
            ),
          },
          required: ['name'],
        ),
      );

  @override
  FutureOr<CallToolResult> call(CallToolRequest request) {
    final args = request.arguments ?? <String, Object?>{};
    final className = (args['name'] as String?)?.trim();

    if (className == null || className.isEmpty) {
      return CallToolResult(
        isError: true,
        content: [TextContent(text: 'Missing required argument: "name"')],
      );
    }

    final pathArg = args['path'] as String?;
    final collection = args['collection'] as String?;

    getIt<IDirectoryService>().ensureRootDirectory();
    final cocoonService = getIt<ICocoonService>();

    final hint = cocoonService.dependencyHint();
    return cocoonService
        .scaffoldModel(
      className: className,
      path: pathArg,
      collection: collection,
    )
        .then((written) {
      final text = StringBuffer()
        ..writeln('Cocoon model generated at ${written.absolute.path}');
      if (hint != null) {
        text
          ..writeln(
              'Missing Cocoon codegen dependencies — add them before running build_runner:')
          ..writeln(hint);
      }
      text
        ..writeln('Next steps:')
        ..writeln('  dart run build_runner build -d')
        ..writeln('  butterfly cocoon migrate');
      return CallToolResult(content: [TextContent(text: text.toString())]);
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
