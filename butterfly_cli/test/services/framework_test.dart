import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:test/test.dart';

import '../helpers/mocks.dart';

void main() {
  group('FrameworkService', () {
    ILoggerService createLogger() => MockLoggerService();

    test('implements IDirectoryService', () {
      final service = FrameworkService(createLogger());
      expect(service, isA<IDirectoryService>());
    });

    test('starts with directoryIsRoot false', () {
      final service = FrameworkService(createLogger());
      expect(service.directoryIsRoot, isFalse);
    });

    test('directoryIsRoot can be set to true', () {
      final service = FrameworkService(createLogger());
      service.directoryIsRoot = true;
      expect(service.directoryIsRoot, isTrue);
    });

    test('directoryIsRoot can be set back to false', () {
      final service = FrameworkService(createLogger());
      service.directoryIsRoot = true;
      service.directoryIsRoot = false;
      expect(service.directoryIsRoot, isFalse);
    });

    test('changeWorkingDirectory resets directoryIsRoot', () {
      final service = FrameworkService(createLogger());
      service.directoryIsRoot = true;
      service.changeWorkingDirectory('lib');
      expect(service.directoryIsRoot, isFalse);
    });
  });
}
