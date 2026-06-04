import 'package:dart_mcp/server.dart';

base class McpServerService extends MCPServer with ToolsSupport {
  McpServerService(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(
            name: 'An example dart server with tools support',
            version: '0.1.0',
          ),
          instructions: 'Just list and call the tools :D',
        ) {
    registerTool(testTool, _test);
  }

  final testTool = Tool(
      name: 'test',
      inputSchema: ObjectSchema(description: 'tootl to test this mcp server'));

  CallToolResult _test(CallToolRequest x) {
    return CallToolResult(content: [TextContent(text: 'test tool called')]);
  }
}
