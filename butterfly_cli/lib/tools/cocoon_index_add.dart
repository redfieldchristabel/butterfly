import 'dart:async';

import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/tools/base.dart';
import 'package:dart_mcp/client.dart';

/// MCP tool running this project's
/// `dart run cocoon_generator:index add <Model> <fields>` — the source edit a
/// Cocoon `MissingIndexException` names with its `Fix:` line. Unlike
/// migrate's prompts, `index add` asks nothing: it is a narrow source edit,
/// so an agent may run it directly. It never writes the lock or generates
/// code; the tool's output carries the two follow-up commands
/// (`cocoon_generator:migrate`, then `build_runner build -d`) for the caller
/// to run. Output is captured (never inherited) because the MCP server's
/// stdio carries the protocol traffic.
class CocoonIndexAddTool extends BaseTool {
  @override
  Tool get definition => Tool(
        name: 'cocoon_index_add',
        description: 'Declare an index on this project\'s Cocoon model by '
            'editing its source (runs the project\'s own '
            '`dart run cocoon_generator:index add <Model> <fields>`). One '
            'field becomes @Indexed() on it; composites and path params '
            'append Index([...]) to @Collection(indexes: [...]). Does not '
            'write the lock or generate code — afterwards run the project\'s '
            '`dart run cocoon_generator:migrate` and '
            '`dart run build_runner build -d`. Never run in CI.',
        inputSchema: ObjectSchema(
          description: 'Parameters of cocoon_generator:index add',
          properties: {
            'model': Schema.string(
              description: 'The @Collection class name (e.g. "Txn")',
            ),
            'fields': Schema.string(
              description: 'Comma list in index order, `-` prefixing a '
                  'descending part (e.g. "accountId,-bookedOn")',
            ),
          },
          required: ['model', 'fields'],
        ),
      );

  @override
  FutureOr<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? <String, Object?>{};
    final model = (args['model'] as String?)?.trim();
    final fields = (args['fields'] as String?)?.trim();

    if (model == null || model.isEmpty || fields == null || fields.isEmpty) {
      return CallToolResult(
        isError: true,
        content: [
          TextContent(text: 'Both "model" and "fields" are required.'),
        ],
      );
    }

    getIt<IDirectoryService>().ensureRootDirectory();
    final cocoonService = getIt<ICocoonService>();

    final hint = cocoonService.dependencyHint();
    if (hint != null) {
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: 'This project\'s pubspec.yaml is missing the Cocoon codegen '
                'tools.\n$hint',
          ),
        ],
      );
    }

    final result = await getIt<IProcessRunner>().runCaptured('dart', [
      'run',
      'cocoon_generator:index',
      'add',
      model,
      fields,
    ]);

    final text = StringBuffer()
      ..writeln('Exit code: ${result.exitCode}')
      ..write(result.stdout)
      ..write(result.stderr);

    return CallToolResult(
      isError: result.exitCode != 0,
      content: [TextContent(text: text.toString())],
    );
  }
}
