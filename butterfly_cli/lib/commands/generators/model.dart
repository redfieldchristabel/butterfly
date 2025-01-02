import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';

class ModelGeneratorCommand extends Command with ButterflyLogger {
  @override
  String get description => 'TODO: Add description';

  @override
  String get name => 'model';

  @override
  List<String> get aliases => ['m', 'mdl'];

  @override
  FutureOr? run() {
    ensureRoot();

    //   TODO: implement
    throw UnimplementedError();
  }
}
