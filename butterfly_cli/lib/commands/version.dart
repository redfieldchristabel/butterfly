import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/version.dart';

class VersionCommand extends Command with ButterflyLogger {
  @override
  String get description => 'Prints the current version of butterfly_cli';

  @override
  String get name => 'version';

  @override
  FutureOr? run() {
    logger.info(kVersion);
  }
}
