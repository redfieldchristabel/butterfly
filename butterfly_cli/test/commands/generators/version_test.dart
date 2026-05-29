import 'package:butterfly_cli/commands/generators/version.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

void main() {
  group('VersionGeneratorCommand', () {
    test('has correct command name', () {
      final cmd = VersionGeneratorCommand(MockPubspecService());
      expect(cmd.name, equals('version'));
    });

    test('has correct description', () {
      final cmd = VersionGeneratorCommand(MockPubspecService());
      expect(cmd.description, contains('version.dart'));
    });
  });
}
