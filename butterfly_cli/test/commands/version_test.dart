import 'package:butterfly_cli/commands/version.dart';
import 'package:test/test.dart';

void main() {
  group('VersionCommand', () {
    test('has correct command name', () {
      final cmd = VersionCommand();
      expect(cmd.name, equals('version'));
    });

    test('has no aliases', () {
      final cmd = VersionCommand();
      expect(cmd.aliases, isEmpty);
    });

    test('description mentions version', () {
      final cmd = VersionCommand();
      expect(cmd.description, contains('version'));
    });

    test('adds no user-defined arguments', () {
      final cmd = VersionCommand();
      // Built-in options (like --help) exist; no user-defined ones
      final userOptions =
          cmd.argParser.options.keys.where((k) => k != 'help');
      expect(userOptions, isEmpty);
    });
  });
}
