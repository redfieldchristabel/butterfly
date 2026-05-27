import 'package:butterfly_cli/commands/commit.dart';
import 'package:test/test.dart';

void main() {
  group('ConventionalCommit', () {
    test('has all conventional commit types', () {
      expect(
        ConventionalCommit.values,
        unorderedEquals([
          ConventionalCommit.fix,
          ConventionalCommit.feat,
          ConventionalCommit.docs,
          ConventionalCommit.style,
          ConventionalCommit.refactor,
          ConventionalCommit.perf,
          ConventionalCommit.test,
          ConventionalCommit.build,
          ConventionalCommit.ci,
          ConventionalCommit.chore,
        ]),
      );
    });

    group('fromName', () {
      test('creates fix from "fix"', () {
        expect(ConventionalCommit.fromName('fix'), equals(ConventionalCommit.fix));
      });

      test('creates feat from "feat"', () {
        expect(ConventionalCommit.fromName('feat'), equals(ConventionalCommit.feat));
      });

      test('creates docs from "docs"', () {
        expect(ConventionalCommit.fromName('docs'), equals(ConventionalCommit.docs));
      });

      test('creates refactor from "refactor"', () {
        expect(
          ConventionalCommit.fromName('refactor'),
          equals(ConventionalCommit.refactor),
        );
      });

      test('creates test from "test"', () {
        expect(
          ConventionalCommit.fromName('test'),
          equals(ConventionalCommit.test),
        );
      });

      test('throws on unknown name', () {
        expect(
          () => ConventionalCommit.fromName('invalid'),
          throwsA(isA<StateError>()),
        );
      });

      test('is case-sensitive (lowercase only)', () {
        expect(
          () => ConventionalCommit.fromName('Fix'),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('name getter', () {
      test('returns lowercase name matching enum value', () {
        for (final value in ConventionalCommit.values) {
          expect(value.name, matches(RegExp(r'^[a-z]+$')));
        }
      });

      test('fix.name is "fix"', () {
        expect(ConventionalCommit.fix.name, equals('fix'));
      });

      test('feat.name is "feat"', () {
        expect(ConventionalCommit.feat.name, equals('feat'));
      });
    });
  });

  group('CommitCommand', () {
    test('has correct command name', () {
      final cmd = CommitCommand();
      expect(cmd.name, equals('commit'));
    });

    test('has aliases', () {
      final cmd = CommitCommand();
      expect(
        cmd.aliases,
        containsAll(['c', 'comit', 'commits', 'cm']),
      );
    });

    test('has a description that references conventional commits', () {
      final cmd = CommitCommand();
      expect(cmd.description, contains('conventional'));
      expect(cmd.description, contains('commit'));
    });

    test('has action and message arguments', () {
      final cmd = CommitCommand();
      expect(cmd.argParser.options.containsKey('action'), isTrue);
      expect(cmd.argParser.options.containsKey('message'), isTrue);
    });

    test('action argument allows all ConventionalCommit names', () {
      final cmd = CommitCommand();
      final actionArg = cmd.argParser.options['action'];
      expect(actionArg, isNotNull);

      // All enum values should be accepted
      for (final commit in ConventionalCommit.values) {
        expect(actionArg!.allowed, contains(commit.name));
      }
    });
  });
}
