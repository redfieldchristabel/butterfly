import 'dart:async';

import 'package:dart_mcp/client.dart';

abstract class BaseTool {
  Tool get definition;

  FutureOr<CallToolResult> call(CallToolRequest request);
}
