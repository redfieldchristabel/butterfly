import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/cocoon.dart';
import 'package:test/test.dart';

import '../helpers/mocks.dart';

CocoonService _service({
  Set<String>? dependencies,
  MockMasonService? masonService,
  MockProcessRunner? processRunner,
}) {
  final logger = MockLoggerService();
  final pubspec = MockPubspecService(dependencies: dependencies);
  final mason = masonService ?? MockMasonService();
  final process = processRunner ?? MockProcessRunner();
  return CocoonService(logger, pubspec, mason, process);
}

void main() {
  group('CocoonService.defaultCollectionPath', () {
    test('pluralizes the snake_case of the name (Txn -> txns)', () {
      expect(_service().defaultCollectionPath('Txn'), equals('txns'));
    });

    test('multi-word names (BankAccount -> bank_accounts)', () {
      expect(_service().defaultCollectionPath('BankAccount'),
          equals('bank_accounts'));
    });

    test('sibilant endings take -es (Address, Box)', () {
      expect(_service().defaultCollectionPath('Address'), equals('addresses'));
      expect(_service().defaultCollectionPath('Box'), equals('boxes'));
    });

    test('consonant + y takes -ies (Category -> categories)', () {
      expect(
          _service().defaultCollectionPath('Category'), equals('categories'));
    });

    test('vowel + y keeps -s (Day -> days)', () {
      expect(_service().defaultCollectionPath('Day'), equals('days'));
    });
  });

  group('CocoonService.dependencyHint', () {
    test('null when cocoon, cocoon_generator and build_runner are present', () {
      expect(_service().dependencyHint(), isNull);
    });

    test('offers both pub add lines when everything is missing', () {
      final hint = _service(dependencies: {}).dependencyHint();
      expect(hint, contains('dart pub add cocoon'));
      expect(
          hint, contains('dart pub add --dev cocoon_generator build_runner'));
    });

    test('offers only the dev line when cocoon itself is a dependency', () {
      final hint = _service(dependencies: {'cocoon'}).dependencyHint();
      expect(
          hint, contains('dart pub add --dev cocoon_generator build_runner'));
      expect(hint, isNot(contains('dart pub add cocoon')));
    });

    test('offers only the cocoon line when the dev tools are present', () {
      final hint = _service(dependencies: {'cocoon_generator', 'build_runner'})
          .dependencyHint();
      expect(hint, equals('dart pub add cocoon'));
    });
  });

  group('CocoonService.ensureDependencies', () {
    test('does nothing when the tools are present', () {
      expect(() => _service().ensureDependencies(), returnsNormally);
    });

    test('throws a ReadableException carrying the pub add lines', () {
      expect(
        () => _service(dependencies: {}).ensureDependencies(),
        throwsA(isA<ReadableException>().having(
            (e) => e.hint,
            'hint',
            allOf(contains('dart pub add cocoon'),
                contains('dart pub add --dev cocoon_generator build_runner')))),
      );
    });
  });

  group('CocoonService.scaffoldModel', () {
    test('scaffolds the brick with the default collection path', () async {
      final mason = MockMasonService();
      await _service(masonService: mason)
          .scaffoldModel(className: 'Txn', overwrite: true);

      expect(mason.cocoonModels, hasLength(1));
      final params = mason.cocoonModels.single.params;
      expect(params.name, equals('Txn'));
      expect(params.fileName, equals('txn'));
      expect(params.collectionPath, equals('txns'));
    });

    test('passes --collection overrides through as-is', () async {
      final mason = MockMasonService();
      await _service(masonService: mason).scaffoldModel(
        className: 'Txn',
        collection: 'accounts/{accountId}/txns',
        overwrite: true,
      );

      expect(mason.cocoonModels.single.params.collectionPath,
          equals('accounts/{accountId}/txns'));
    });

    test('derives the file name like generate model (AuthUser + auth)',
        () async {
      final mason = MockMasonService();
      await _service(masonService: mason)
          .scaffoldModel(className: 'AuthUser', path: 'auth');

      expect(mason.cocoonModels.single.params.fileName, equals('user'));
    });

    test('rejects a class name identical to the path', () async {
      expect(
        () => _service().scaffoldModel(className: 'Auth', path: 'auth'),
        throwsA(isA<ReadableException>()),
      );
    });
  });

  group('CocoonService.migrate', () {
    test('runs the project migrate command with the args verbatim', () async {
      final process = MockProcessRunner();
      await _service(processRunner: process)
          .migrate(['--check', '--rename', 'Txn.bookedOn=day', '--yes']);

      expect(process.calls, hasLength(1));
      final call = process.calls.single;
      expect(call.executable, equals('dart'));
      expect(
          call.arguments,
          equals([
            'run',
            'cocoon_generator:migrate',
            '--check',
            '--rename',
            'Txn.bookedOn=day',
            '--yes',
          ]));
      expect(call.inheritedStdio, isTrue);
    });

    test('returns the migrate exit code unchanged', () async {
      final process = MockProcessRunner()..nextExitCode = 2;
      expect(await _service(processRunner: process).migrate(['--check']), 2);
    });

    test('throws before running anything when dependencies are missing',
        () async {
      final process = MockProcessRunner();
      expect(
        () => _service(dependencies: {}, processRunner: process).migrate(),
        throwsA(isA<ReadableException>()),
      );
      expect(process.calls, isEmpty);
    });
  });

  group('CocoonService.build', () {
    test('runs build_runner build -d with inherited stdio', () async {
      final process = MockProcessRunner();
      await _service(processRunner: process).build();

      final call = process.calls.single;
      expect(call.executable, equals('dart'));
      expect(call.arguments, equals(['run', 'build_runner', 'build', '-d']));
      expect(call.inheritedStdio, isTrue);
    });

    test('returns the build exit code unchanged', () async {
      final process = MockProcessRunner()..nextExitCode = 1;
      expect(await _service(processRunner: process).build(), 1);
    });
  });
}
