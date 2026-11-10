import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:butterfly_cli/interfaces/interfaces.dart';

/// Runs real processes. `runInherited` shares the CLI's terminal so
/// interactive child menus work; `runCaptured` buffers the output for
/// callers that must not share stdio (the MCP server).
class ProcessRunner implements IProcessRunner {
  @override
  Future<int> runInherited(String executable, List<String> arguments) async {
    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }

  @override
  Future<CapturedProcess> runCaptured(
      String executable, List<String> arguments) async {
    final process = await Process.start(executable, arguments);
    final stdout = await process.stdout.transform(utf8.decoder).join();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    return CapturedProcess(exitCode, stdout, stderr);
  }
}
