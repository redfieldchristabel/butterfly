import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/services/pubspec.dart';

class VersionGeneratorCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Generate version.dart in root\'s lib directory of projects';

  @override
  String get name => 'version';

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
