import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';

class CommitCommand extends Command with ButterflyLogger {
  @override
  String get description =>
      'Commit changes via conventional commits from ${Uri.parse('https://www.conventionalcommits.org/en/v1.0.0/')}';

  @override
  String get name => 'commit';

  @override
  run() async {
    final action = logger.chooseOne<ConventionalCommit>(
        'What is your commit type',
        choices: ConventionalCommit.values,
        display: (choice) => choice.name);

    final message = logger.prompt('What is your commit message?');

    final res =
        await Process.run('git', ['commit', '-m', '${action.name}: $message']);

    logger.info(res.stdout);
    logger.info(res.stderr);
  }
}

enum ConventionalCommit {
  fix,
  feat,
  docs,
  style,
  refactor,
  perf,
  test,
  build,
  ci,
  chore;
}
