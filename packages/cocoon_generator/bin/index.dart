import 'dart:io';

import 'package:cocoon_generator/index.dart';

/// The `cocoon_generator:index` executable: see `runIndexAdd` for the
/// behaviour, exit codes and the shapes it edits.
Future<void> main(List<String> args) async {
  exitCode = await runIndexAdd(args: args);
}
