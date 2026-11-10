import 'dart:async';

import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/tools/base.dart';
import 'package:dart_mcp/client.dart';

/// MCP tool running this project's `dart run cocoon_generator:migrate
/// --check` — the read-only form of `butterfly cocoon migrate`. Output is
/// captured (never inherited) because the MCP server's stdio carries the
/// protocol traffic.
class CocoonMigrateCheckTool extends BaseTool {
  @override
  Tool get definition => Tool(
        name: 'cocoon_migrate_check',
        description: 'Check whether this project\'s Cocoon models match '
            'cocoon.lock.json without writing anything (runs the project\'s '
            'own `dart run cocoon_generator:migrate --check`). Exit code 1 '
            'means the models changed and a real migrate is needed.',
        inputSchema: ObjectSchema(
          description: 'No parameters',
          properties: {},
        ),
      );

  @override
  FutureOr<CallToolResult> call(CallToolRequest request) async {
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

    final result = await getIt<IProcessRunner>()
        .runCaptured('dart', ['run', 'cocoon_generator:migrate', '--check']);

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
