import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:test/test.dart';

void main() {
  group('ProjectConfiguration', () {
    test('constructs with all fields (goRouter, userModelName)', () {
      final config = ProjectConfiguration(
        useAuth: true,
        useCore: true,
        useRouter: true,
        routerType: RouterType.goRouter,
        userModelName: 'Customer',
      );

      expect(config.useAuth, isTrue);
      expect(config.useCore, isTrue);
      expect(config.useRouter, isTrue);
      expect(config.routerType, equals(RouterType.goRouter));
      expect(config.userModelName, equals('Customer'));
    });

    test('constructs with minimal required fields', () {
      final config = ProjectConfiguration(
        useAuth: true,
        useCore: false,
        useRouter: false,
        userModelName: 'User',
      );

      expect(config.useAuth, isTrue);
      expect(config.useCore, isFalse);
      expect(config.useRouter, isFalse);
      expect(config.routerType, isNull);
      expect(config.userModelName, equals('User'));
    });

    test('constructs with other router type', () {
      final config = ProjectConfiguration(
        useAuth: true,
        useCore: true,
        useRouter: true,
        routerType: RouterType.other,
        userModelName: 'Admin',
      );

      expect(config.routerType, equals(RouterType.other));
    });

    test('fails assertion when useAuth is true but userModelName is null', () {
      expect(
        () => ProjectConfiguration(
          useAuth: true,
          useCore: true,
          useRouter: false,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    group('JSON serialization (toJson)', () {
      test('produces all fields with goRouter', () {
        final config = ProjectConfiguration(
          useAuth: true,
          useCore: false,
          useRouter: true,
          routerType: RouterType.goRouter,
          userModelName: 'Employee',
        );

        final json = config.toJson();
        expect(json['useAuth'], isTrue);
        expect(json['useCore'], isFalse);
        expect(json['useRouter'], isTrue);
        expect(json['routerType'], equals('goRouter'));
        expect(json['userModelName'], equals('Employee'));
      });

      test('produces minimal fields', () {
        final config = ProjectConfiguration(
          useAuth: true,
          useCore: false,
          useRouter: false,
          userModelName: 'User',
        );

        final json = config.toJson();
        expect(json['useAuth'], isTrue);
        expect(json['useCore'], isFalse);
        expect(json['useRouter'], isFalse);
        // routerType key is always serialized even when null
        expect(json['routerType'], isNull);
        expect(json['userModelName'], equals('User'));
      });

      test('includes no unexpected keys', () {
        final config = ProjectConfiguration(
          useAuth: true,
          useCore: true,
          useRouter: false,
          userModelName: 'User',
        );

        expect(
          config.toJson().keys,
          unorderedEquals(
            ['useAuth', 'useCore', 'useRouter', 'routerType', 'userModelName'],
          ),
        );
      });
    });

    group('JSON deserialization (fromJson)', () {
      // NOTE: The hand-written fromJson factory reads 'version' from the map
      // but passes the SAME map to _$ProjectConfigurationFromJson, which
      // rejects unrecognized keys via $checkKeys. This means fromJson
      // cannot successfully parse ANY input in the current code — it is a
      // known bug in the source. These tests document the current behavior.

      test('fails with TypeError when version is missing (null cast)', () {
        expect(
          () => ProjectConfiguration.fromJson(<String, dynamic>{
            'useAuth': true,
            'useCore': true,
            'useRouter': false,
            'userModelName': 'User',
          }),
          throwsA(isA<TypeError>()),
        );
      });

      test('fails with CheckedFromJsonException when version is present', () {
        expect(
          () => ProjectConfiguration.fromJson(<String, dynamic>{
            'useAuth': true,
            'useCore': true,
            'useRouter': true,
            'routerType': 'goRouter',
            'userModelName': 'Manager',
            'version': '0.1.0',
          }),
          throwsA(isA<CheckedFromJsonException>()),
        );
      });

      test('fails on missing required keys (useAuth, useCore)', () {
        expect(
          () => ProjectConfiguration.fromJson(<String, dynamic>{
            'useRouter': true,
            'version': '0.1.0',
          }),
          throwsA(isA<CheckedFromJsonException>()),
        );
      });

      test('fails on unrecognized keys', () {
        expect(
          () => ProjectConfiguration.fromJson(<String, dynamic>{
            'useAuth': true,
            'useCore': true,
            'useRouter': false,
            'userModelName': 'User',
            'version': '0.1.0',
            'unknownField': 'should not be here',
          }),
          throwsA(isA<CheckedFromJsonException>()),
        );
      });
    });

    group('toString', () {
      test('includes configuration keys', () {
        final config = ProjectConfiguration(
          useAuth: true,
          useCore: true,
          useRouter: false,
          userModelName: 'Manager',
        );

        final str = config.toString();
        expect(str, contains('Configuration'));
        expect(str, contains('useAuth'));
        expect(str, contains('Manager'));
      });
    });
  });

  group('RouterType', () {
    test('has goRouter and other values', () {
      expect(
        RouterType.values,
        containsAll([RouterType.goRouter, RouterType.other]),
      );
    });

    test('goRouter serialises to "goRouter" in JSON', () {
      final config = ProjectConfiguration(
        useAuth: true,
        useCore: false,
        useRouter: true,
        routerType: RouterType.goRouter,
        userModelName: 'User',
      );
      expect(config.toJson()['routerType'], equals('goRouter'));
    });

    test('other serialises to "other" in JSON', () {
      final config = ProjectConfiguration(
        useAuth: true,
        useCore: false,
        useRouter: true,
        routerType: RouterType.other,
        userModelName: 'User',
      );
      expect(config.toJson()['routerType'], equals('other'));
    });
  });
}
