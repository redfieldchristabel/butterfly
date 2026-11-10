import 'dart:async';

/// The outcome of a process run whose output was captured.
class CapturedProcess {
  final int exitCode;
  final String stdout;
  final String stderr;

  const CapturedProcess(this.exitCode, this.stdout, this.stderr);
}

/// Runs external processes for the CLI.
///
/// Abstracted so commands can be tested without spawning real processes.
abstract class IProcessRunner {
  /// Runs [executable] with [arguments], inheriting the CLI's stdio so
  /// interactive menus (prompts, arrow-key pickers) render and respond
  /// exactly as when the tool is run directly. Returns the process's exit
  /// code.
  Future<int> runInherited(String executable, List<String> arguments);

  /// Runs [executable] with [arguments], capturing stdout and stderr
  /// instead of inheriting them (needed when the CLI's own stdio carries
  /// protocol traffic, e.g. the MCP server). Returns the exit code and the
  /// captured output.
  Future<CapturedProcess> runCaptured(
      String executable, List<String> arguments);
}
