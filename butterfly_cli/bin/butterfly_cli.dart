import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/init.dart';

void main(List<String> arguments) {
  var runner =
      CommandRunner('butterfly_cli', 'A CLI tool for butterfly project');

  runner.addCommand(InitCommand());

  runner.run(arguments);
}
