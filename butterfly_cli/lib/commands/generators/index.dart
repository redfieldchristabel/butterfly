import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/generators/version.dart';

class GenerateCommand extends Command {
  @override
  String get description => 'Generate a new object like model, etc...';

  @override
  String get name => 'generate';

  @override
  // TODO: implement aliases
  List<String> get aliases => ['gen', 'g'];

  GenerateCommand() {
    addSubcommand(VersionGeneratorCommand());
  }
}
