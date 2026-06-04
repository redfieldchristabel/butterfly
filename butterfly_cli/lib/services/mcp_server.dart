import 'package:dart_mcp/server.dart';

import '../tools/generate_model.dart';
import '../tools/init.dart';
import '../tools/test.dart';

base class McpServerService extends MCPServer with ToolsSupport {
  McpServerService(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(
            name: 'Butterfly CLI MCP Server',
            version: '0.1.0',
          ),
          instructions:
              'Tools for generating butterfly project components.',
        ) {
    final tools = [
      TestTool(),
      InitTool(),
      GenerateModelTool(),
    ];
    for (final t in tools) {
      registerTool(t.definition, t.call);
    }
  }
}
