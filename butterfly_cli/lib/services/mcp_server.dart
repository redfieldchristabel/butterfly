import 'package:dart_mcp/server.dart';

import '../tools/test.dart';

base class McpServerService extends MCPServer with ToolsSupport {
  McpServerService(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(
            name: 'Butterfly CLI MCP Server',
            version: '0.1.0',
          ),
          instructions: 'Tools for interacting with butterfly projects. '
              'Use `test` to verify the server is running and echo messages.',
        ) {
    final tools = [TestTool()];
    for (final t in tools) {
      registerTool(t.definition, t.call);
    }
  }
}
