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
  List<String> get aliases => ['c', 'comit', 'commits', 'cm'];

  @override
  run() async {
    final action = logger.chooseOne<ConventionalCommit>(
        'What is your commit type',
        choices: ConventionalCommit.values,
        display: (choice) => choice.name);

    final message = logger.prompt('What is your commit message?');

    detail('Run git status to see if any staged changes');
    final statusRes = await Process.run('git', ['status']);
    if (statusRes.stdout.contains('no changes added to commit')) {
      final stageAll = logger.confirm(
          'No changes to commit, commit all changes instead?',
          defaultValue: true);
      if (stageAll) {
        detail('Run git add -A to stage all changes');
        await Process.run('git', ['add', '.']);
      } else {
        info('No changes to commit, exiting');
        exit(2);
      }
    }

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
