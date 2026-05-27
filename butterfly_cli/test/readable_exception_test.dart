import 'package:butterfly_cli/readable_exception.dart';
import 'package:test/test.dart';

void main() {
  group('ReadableException', () {
    test('constructs with title, message, code and optional hint', () {
      final exception = ReadableException(
        title: 'Test Error',
        message: 'Something went wrong',
        code: 42,
        hint: 'Try again later',
      );

      expect(exception.title, equals('Test Error'));
      expect(exception.message, equals('Something went wrong'));
      expect(exception.code, equals(42));
      expect(exception.hint, equals('Try again later'));
    });

    test('constructs without hint', () {
      final exception = ReadableException(
        title: 'Minimal Error',
        message: 'No hint provided',
        code: 1,
      );

      expect(exception.title, equals('Minimal Error'));
      expect(exception.message, equals('No hint provided'));
      expect(exception.code, equals(1));
      expect(exception.hint, isNull);
    });

    test('supports various error codes', () {
      expect(
        ReadableException(title: 'A', message: 'B', code: 66).code,
        equals(66),
      );
      expect(
        ReadableException(title: 'A', message: 'B', code: 0).code,
        equals(0),
      );
      expect(
        ReadableException(title: 'A', message: 'B', code: -1).code,
        equals(-1),
      );
    });

    test('is an Exception', () {
      final exception = ReadableException(
        title: 'Ex',
        message: 'Msg',
        code: 1,
      );

      expect(exception, isA<Exception>());
    });

    test('toString returns default Object toString', () {
      final exception = ReadableException(
        title: 'ToString Test',
        message: 'Check string representation',
        code: 99,
      );

      // ReadableException doesn't override toString, so it uses Object's
      expect(exception.toString(), contains('ReadableException'));
    });
  });
}
