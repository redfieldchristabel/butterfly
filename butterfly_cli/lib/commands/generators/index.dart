import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/generators/model.dart';
import 'package:butterfly_cli/commands/generators/version.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';

class GenerateCommand extends Command with ButterflyLogger {
  final IMasonService _masonService;
  final IPubspecService _pubspecService;

  GenerateCommand(this._masonService, this._pubspecService) {
    addSubcommand(VersionGeneratorCommand(_pubspecService));
    addSubcommand(ModelGeneratorCommand(_masonService));
  }

  @override
  String get description => 'Generate a new object like model, etc...';

  @override
  String get name => 'generate';

  @override
  List<String> get aliases => ['gen', 'g'];
}
