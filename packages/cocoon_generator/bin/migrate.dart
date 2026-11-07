import 'dart:io';

import 'package:cocoon_generator/migrate.dart';

/// The `cocoon_generator:migrate` executable: see `runMigrate` for the
/// behaviour, exit codes and flags.
Future<void> main(List<String> args) async {
  exitCode = await runMigrate(args: args);
}
