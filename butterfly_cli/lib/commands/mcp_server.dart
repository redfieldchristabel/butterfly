import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/services/mcp_server.dart';
import 'package:dart_mcp/stdio.dart';

class McpServerCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Start an stdio MCP server exposing butterfly project tools';

  @override
  String get name => 'mcp-server';

  @override
  List<String> get aliases => ['mcp', 'mcp-srv'];

  @override
  Future<void> run() async {
    final channel = stdioChannel(input: stdin, output: stdout);
    final server = McpServerService(channel);

    info('butterfly MCP server running on stdio');
    await server.done;
  }
}
