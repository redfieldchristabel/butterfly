import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';

class ModelGeneratorCommand extends Command with ButterflyLogger{
  @override
  String get description => 'TODO: Add description';

  @override
  String get name => 'model';

  @override
  List<String> get aliases => ['m', 'mld'];

  @override
  FutureOr? run() {
    ensureRoot();

    final version = pubspecService.version;
    final File file = File('lib/version.dart');

    detail('Generating version.dart');
    // TODO: find a wat to use expression builder to create a dart code
    final String context = "const String kVersion = '$version';";

    detail('Generate file version.dart');
    file.writeAsStringSync(context);
    info('Generate file version.dart at ${Uri.file(file.absolute.path)}');
  }

}