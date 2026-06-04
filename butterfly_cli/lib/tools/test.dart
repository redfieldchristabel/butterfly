import 'package:butterfly_cli/tools/base.dart';
import 'package:dart_mcp/client.dart';

class TestTool extends BaseTool {
  @override
  Tool get definition => Tool(
        name: 'test',
        description:
            'A test tool to verify the butterfly MCP server is working',
        inputSchema: ObjectSchema(
          description: 'Parameters for the test tool',
          properties: {
            'message': Schema.string(
              description: 'An optional message to echo back',
            ),
          },
        ),
      );

  @override
  CallToolResult call(CallToolRequest request) {
    final message =
        request.arguments?['message']?.toString() ?? 'test tool called';
    return CallToolResult(content: [TextContent(text: message)]);
  }
}
