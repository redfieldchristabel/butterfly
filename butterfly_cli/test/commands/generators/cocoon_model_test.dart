import 'package:args/command_runner.dart';
import 'package:butterfly_cli/commands/generators/index.dart';
import 'package:butterfly_cli/commands/generators/model.dart';
import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/services/cocoon.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

/// A runner wiring the real [GenerateCommand] with a real [CocoonService]
/// over recording mocks, so the mason brick vars can be asserted.
CommandRunner<void> _runner({
  MockMasonService? masonService,
  Set<String>? dependencies,
}) {
  getIt.reset();
  getIt.registerSingleton<ILoggerService>(MockLoggerService());
  getIt.registerSingleton<IDirectoryService>(MockDirectoryService());

  final mason = masonService ?? MockMasonService();
  final pubspec = MockPubspecService(dependencies: dependencies);
  final process = MockProcessRunner();
  final cocoonService =
      CocoonService(getIt<ILoggerService>(), pubspec, mason, process);

  final runner = CommandRunner<void>('test', 'Test runner');
  runner.addCommand(GenerateCommand(mason, pubspec, cocoonService));
  return runner;
}

void main() {
  group('ModelGeneratorCommand --cocoon', () {
    test('has --cocoon and --collection arguments', () {
      final cmd =
          ModelGeneratorCommand(MockMasonService(), MockCocoonService());
      expect(cmd.argParser.options.containsKey('cocoon'), isTrue);
      expect(cmd.argParser.options.containsKey('collection'), isTrue);
    });

    test('--cocoon defaults to false and --collection to null', () {
      final runner = _runner();
      final results = runner.parse(['generate', 'model', 'Txn']);
      final modelResult = results.command!.command!;
      expect(modelResult['cocoon'], isFalse);
      expect(modelResult['collection'], isNull);
    });

    test('rejects --cocoon with --immutable', () {
      final runner = _runner();
      expect(
        () =>
            runner.run(['generate', 'model', 'Txn', '--cocoon', '--immutable']),
        throwsA(isA<UsageException>()),
      );
    });

    test('scaffolds the brick with name, file and default collection',
        () async {
      final mason = MockMasonService();
      final runner = _runner(masonService: mason);
      await runner.run(['generate', 'model', 'Txn', '--cocoon']);

      expect(mason.cocoonModels, hasLength(1));
      final params = mason.cocoonModels.single.params;
      expect(params.name, equals('Txn'));
      expect(params.fileName, equals('txn'));
      expect(params.collectionPath, equals('txns'));
      expect(mason.cocoonModels.single.overwrite, isTrue);
    });

    test('passes a {param} collection override through untouched', () async {
      final mason = MockMasonService();
      final runner = _runner(masonService: mason);
      await runner.run([
        'generate',
        'model',
        'Txn',
        '--cocoon',
        '--collection',
        'accounts/{accountId}/txns',
      ]);

      expect(mason.cocoonModels.single.params.collectionPath,
          equals('accounts/{accountId}/txns'));
    });

    test('still writes the scaffold when the dependencies are missing',
        () async {
      final mason = MockMasonService();
      final runner = _runner(masonService: mason, dependencies: {'cocoon'});

      await runner.run(['generate', 'model', 'Txn', '--cocoon']);

      expect(mason.cocoonModels, hasLength(1));
      expect(mason.cocoonModels.single.params.collectionPath, equals('txns'));
    });

    test('does not touch the plain model path when --cocoon is absent',
        () async {
      final mason = MockMasonService();
      final runner = _runner(masonService: mason);
      await runner.run(['generate', 'model', 'User', '-s']);

      expect(mason.cocoonModels, isEmpty);
      expect(mason.plainModels, hasLength(1));
    });
  });
}
