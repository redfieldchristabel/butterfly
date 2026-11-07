/// End-to-end builder tests: the real `cocoonBuilder` runs over in-memory
/// model files and the generated part file is asserted on. Field numbers must
/// come only from the lock, and models that disagree with the lock must fail
/// with the `cocoon migrate` instruction.
library;

import 'package:test/test.dart';

import 'support.dart';

const _head =
    "import 'dart:typed_data';\n\n"
    "import 'package:cocoon/cocoon.dart';\n\n"
    "part 'models.cocoon.dart';\n\n";

/// A finance-style model covering every scalar type plus a list.
const _kindsModel = '''
@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn {
  const Txn({
    required this.bookedOn,
    required this.amountMinor,
    required this.rate,
    required this.active,
    required this.currency,
    required this.bookedAt,
    required this.mood,
    this.blob,
    this.memo,
    this.tags = const ['a'],
  });

  final int bookedOn;
  final int amountMinor;
  final double rate;
  final bool active;
  final String currency;
  final DateTime bookedAt;
  final Mood mood;
  final Uint8List? blob;
  final String? memo;
  final List<String> tags;
}

enum Mood { glad, sad }
''';

final _kindsLock = lockText(
  collections: {
    'Txn': TestCollection(
      'accounts/{accountId}/txns',
      const {
        'bookedOn': 'int',
        'amountMinor': 'int',
        'rate': 'double',
        'active': 'bool',
        'currency': 'String',
        'bookedAt': 'DateTime',
        'mood': 'enum:Mood',
        'blob': 'Uint8List?',
        'memo': 'String?',
        'tags': 'List<String>',
      },
      indexes: const [
        ['accountId', '-bookedOn'],
      ],
    ),
  },
);

void main() {
  group('happy path', () {
    test(
      'generates the const instance named by the leaf collection id',
      () async {
        final run = await runCocoonBuilder(_head + _kindsModel, _kindsLock);
        expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
        expect(run.hasOutput, isTrue);
        expect(run.code, contains('const txns = TxnCollection._();'));
        expect(
          run.code,
          contains(
            'final class TxnCollection extends CollectionAdapter<Txn> {',
          ),
        );
        expect(run.code, contains('const TxnCollection._();'));
        expect(
          run.code,
          contains(
            "static final _pattern = CollectionPattern.parse('accounts/{accountId}/txns');",
          ),
        );
      },
    );

    test('encodes and decodes every scalar type with its lock number', () async {
      final run = await runCocoonBuilder(_head + _kindsModel, _kindsLock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      // int and DateTime are zigzag sint64 (DateTime in UTC microseconds).
      expect(run.code, contains('writer.writeSint64(1, value.bookedOn);'));
      expect(run.code, contains('writer.writeSint64(2, value.amountMinor);'));
      expect(run.code, contains('writer.writeDouble(3, value.rate);'));
      expect(run.code, contains('writer.writeBool(4, value.active);'));
      expect(run.code, contains('writer.writeString(5, value.currency);'));
      expect(
        run.code,
        contains(
          'writer.writeSint64(6, value.bookedAt.toUtc().microsecondsSinceEpoch);',
        ),
      );
      // Enums are stored by name; nulls are skipped.
      expect(run.code, contains('writer.writeString(7, value.mood.name);'));
      expect(run.code, contains('final \$blob = value.blob;'));
      expect(run.code, contains('writer.writeBytes(8, \$blob);'));
      // Lists are nested messages with 1-based element fields.
      expect(run.code, contains('writer.writeMessage(10, (nested) {'));
      expect(run.code, contains('nested.writeString(\$i, \$element);'));
      // Decode locals: ctor default first, then proto3 zero, then null.
      expect(run.code, contains('int \$bookedOn = 0;'));
      expect(run.code, contains('int \$amountMinor = 0;'));
      expect(run.code, contains('double \$rate = 0.0;'));
      expect(run.code, contains('bool \$active = false;'));
      expect(run.code, contains("String \$currency = '';"));
      expect(run.code, contains('DateTime \$bookedAt = DateTime.utc(1970);'));
      expect(run.code, contains('Mood \$mood = Mood.values.first;'));
      expect(run.code, contains('Uint8List? \$blob;'));
      expect(run.code, contains('String? \$memo;'));
      expect(run.code, contains("List<String> \$tags = const ['a'];"));
      // Unknown field numbers are skipped; the constructor rebuilds the value.
      expect(run.code, contains('reader.skip(tag.type);'));
      expect(run.code, contains('return Txn('));
    });

    test('emits toInspectorJson for the DevTools inspector', () async {
      final run = await runCocoonBuilder(_head + _kindsModel, _kindsLock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      // One JSON key per stored field, in lock-number order: scalars pass
      // through, dates become UTC ISO-8601, enums their name, binary fields
      // a placeholder, lists recurse, and nullable fields are skipped when
      // null.
      expect(
        run.code,
        contains('Map<String, Object?> toInspectorJson(Txn value) => {'),
      );
      expect(run.code, contains("'bookedOn': value.bookedOn,"));
      expect(run.code, contains("'rate': value.rate,"));
      expect(run.code, contains("'active': value.active,"));
      expect(
        run.code,
        contains("'bookedAt': value.bookedAt.toUtc().toIso8601String(),"),
      );
      expect(run.code, contains("'mood': value.mood.name,"));
      expect(run.code, contains("if (value.blob != null)"));
      expect(run.code, contains("'blob': '<\${value.blob!.length} bytes>',"));
      expect(run.code, contains("if (value.memo != null)"));
      expect(run.code, contains("'memo': value.memo!,"));
      expect(
        run.code,
        contains("[for (final \$element in value.tags) \$element],"),
      );
    });

    test('only indexed fields and params become columns and handles', () async {
      final run = await runCocoonBuilder(_head + _kindsModel, _kindsLock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(run.code, contains('get columns => [Txn\$.bookedOn];'));
      expect(run.code, contains("FieldColumn.integer<Txn, int>("));
      expect(run.code, contains("'bookedOn',"));
      // amountMinor is in no index: no column, no handle.
      expect(run.code, isNot(contains("'amountMinor',")));
      expect(run.code, isNot(contains('Txn\$.amountMinor')));
      // The path param gets a ParamColumn handle.
      expect(
        run.code,
        contains("ParamColumn(TxnCollection._pattern, 'accountId')"),
      );
      expect(
        run.code,
        contains("IndexDef.fromFields(const ['accountId', '-bookedOn']),"),
      );
    });

    test('constructor defaults survive decode of old documents', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({
    this.count = 7,
    this.title = 'hi',
    this.score = 1.5,
    this.on = true,
    this.tags = const ['x'],
    this.note,
  });

  final int count;
  final String title;
  final double score;
  final bool on;
  final List<String> tags;
  final String? note;
}
''';
      final lock = lockText(
        collections: {
          'Thing': TestCollection('things', const {
            'count': 'int',
            'title': 'String',
            'score': 'double',
            'on': 'bool',
            'tags': 'List<String>',
            'note': 'String?',
          }),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(run.code, contains('int \$count = 7;'));
      expect(run.code, contains("String \$title = 'hi';"));
      expect(run.code, contains('double \$score = 1.5;'));
      expect(run.code, contains('bool \$on = true;'));
      expect(run.code, contains("List<String> \$tags = const ['x'];"));
      expect(run.code, contains('String? \$note;'));
    });

    test('positional constructor parameters are called positionally', () async {
      const model = '''
@Collection('ledgers')
class Ledger {
  const Ledger(this.name, this.year);

  final String name;
  final int year;
}
''';
      final lock = lockText(
        collections: {
          'Ledger': TestCollection('ledgers', const {
            'name': 'String',
            'year': 'int',
          }),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(run.code, contains('return Ledger(\$name, \$year);'));
      expect(run.code, contains("String \$name = '';"));
      expect(run.code, contains('int \$year = 0;'));
    });

    test(
      'embedded classes encode as nested messages with their own codecs',
      () async {
        const model = '''
@Embedded()
class GeoPoint {
  const GeoPoint({required this.lat, required this.lon});

  final double lat;
  final double lon;
}

@Embedded()
class Address {
  const Address({required this.city, this.line2, this.geo});

  final String city;
  final String? line2;
  final GeoPoint? geo;
}

@Collection('accounts', indexes: [Index(['city'])])
class Account {
  const Account({required this.city, required this.address});

  final String city;
  final Address address;
}
''';
        final lock = lockText(
          version: 3,
          collections: {
            'Account': TestCollection(
              'accounts',
              const {'city': 'String', 'address': 'embedded:Address'},
              indexes: const [
                ['city'],
              ],
            ),
          },
          embedded: {
            'Address': const {
              'city': 'String',
              'line2': 'String?',
              'geo': 'embedded:GeoPoint?',
            },
            'GeoPoint': const {'lat': 'double', 'lon': 'double'},
          },
        );
        final run = await runCocoonBuilder(_head + model, lock);
        expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
        // Nested message write/read of the embedded field.
        expect(
          run.code,
          contains('Address\$.writeTo(writer, 2, value.address);'),
        );
        expect(run.code, contains('\$address = Address\$.readFrom(reader);'));
        // The embedded codec recurses into its own embedded field; nullable
        // fields go through a null check first.
        expect(run.code, contains('GeoPoint\$.writeTo(writer, 3, \$geo);'));
        // Zero values for old documents: defaults and nulls for nullable
        // fields, proto3 zeros otherwise.
        expect(
          run.code,
          contains("Address(city: '', line2: null, geo: null);"),
        );
        expect(run.code, contains('static GeoPoint zero() => GeoPoint('));
        // A non-nullable embedded field with no value decodes to zero().
        expect(run.code, contains('Address \$address = Address\$.zero();'));
        // The JSON view recurses: the collection's toInspectorJson calls the
        // embedded class's inspectorJson.
        expect(run.code, contains('Address\$.inspectorJson(value.address)'));
        expect(
          run.code,
          contains("static Map<String, Object?> inspectorJson(Address value)"),
        );
        expect(
          run.code,
          contains(
            "if (value.geo != null) 'geo': GeoPoint\$.inspectorJson(value.geo!),",
          ),
        );
      },
    );

    test('nullable columns and enum columns carry their options', () async {
      const model = '''
@Collection('people', indexes: [
  Index(['nickname', '-score']),
  Index(['mood'], unique: true),
])
class Person {
  const Person({required this.nickname, required this.score,
      required this.mood});

  final String? nickname;
  final double score;
  final Mood mood;
}

enum Mood { glad, sad }
''';
      final lock = lockText(
        collections: {
          'Person': TestCollection(
            'people',
            const {
              'nickname': 'String?',
              'score': 'double',
              'mood': 'enum:Mood',
            },
            indexes: const [
              ['nickname', '-score'],
              ['mood'],
            ],
          ),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(run.code, contains('FieldColumn.text<Person, String?>('));
      expect(run.code, contains('nullable: true'));
      expect(run.code, contains('FieldColumn.enumerated<Person, Mood>('));
      expect(run.code, contains('values: Mood.values'));
      expect(
        run.code,
        contains("IndexDef.fromFields(const ['mood'], unique: true),"),
      );
      expect(
        run.code,
        contains("IndexDef.fromFields(const ['nickname', '-score']),"),
      );
    });

    test('ignored fields are not stored and do not break the build', () async {
      const model = '''
@Collection('things', indexes: [Index(['name'])])
class Thing {
  const Thing({required this.name}) : stamp = 0;

  final String name;

  @Ignore()
  final int stamp;
}
''';
      final lock = lockText(
        collections: {
          'Thing': TestCollection(
            'things',
            const {'name': 'String'},
            indexes: const [
              ['name'],
            ],
          ),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(run.code, isNot(contains('stamp')));
    });

    test('the schema version constant comes from the lock', () async {
      final run = await runSchemaVersionBuilder(
        lockText(
          version: 12,
          collections: {
            'Thing': TestCollection('things', const {'name': 'String'}),
          },
        ),
      );
      expect(run.code, contains('const cocoonSchemaVersion = 12;'));
    });
  });

  group('failures', () {
    test('missing lock tells the developer to run migrate', () async {
      final run = await runCocoonBuilder(_head + _kindsModel, '');
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains(
          'Cocoon schema changed for Txn: run '
          '"dart run cocoon_generator:migrate"',
        ),
      );
      expect(run.errors.join('\n'), contains('cocoon.lock.json is missing'));
    });

    test('a model missing from the lock is a new collection', () async {
      final run = await runCocoonBuilder(_head + _kindsModel, lockText());
      expect(run.succeeded, isFalse);
      expect(run.errors.join('\n'), contains('Cocoon schema changed for Txn'));
      expect(run.errors.join('\n'), contains('new collection'));
    });

    test(
      'added fields fail with the migrate instruction and a summary',
      () async {
        final lock = lockText(
          collections: {
            'Txn': TestCollection('accounts/{accountId}/txns', const {
              'bookedOn': 'int',
            }),
          },
        );
        const model = '''
@Collection('accounts/{accountId}/txns')
class Txn {
  const Txn({required this.bookedOn, required this.extra});

  final int bookedOn;
  final String extra;
}
''';
        final run = await runCocoonBuilder(_head + model, lock);
        expect(run.succeeded, isFalse);
        expect(
          run.errors.join('\n'),
          contains(
            'Cocoon schema changed for Txn: run '
            '"dart run cocoon_generator:migrate" (added: extra).',
          ),
        );
      },
    );

    test('type changes fail and name both types', () async {
      final lock = lockText(
        collections: {
          'Txn': TestCollection('accounts/{accountId}/txns', const {
            'bookedOn': 'String',
          }),
        },
      );
      const model = '''
@Collection('accounts/{accountId}/txns')
class Txn {
  const Txn({required this.bookedOn});

  final int bookedOn;
}
''';
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains('type changed: bookedOn: String -> int'),
      );
    });

    test('path changes fail', () async {
      final lock = lockText(
        collections: {
          'Txn': TestCollection('ledgers/{ledgerId}/txns', const {
            'bookedOn': 'int',
          }),
        },
      );
      const model = '''
@Collection('accounts/{accountId}/txns')
class Txn {
  const Txn({required this.bookedOn});

  final int bookedOn;
}
''';
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isFalse);
      expect(run.errors.join('\n'), contains('path changed'));
    });

    test(
      'unsupported field types name the field and the supported types',
      () async {
        const model = '''
@Collection('things')
class Thing {
  const Thing({required this.data});

  final Map<String, int> data;
}
''';
        final lock = lockText(
          collections: {
            'Thing': TestCollection('things', const {'data': 'int'}),
          },
        );
        final run = await runCocoonBuilder(_head + model, lock);
        expect(run.succeeded, isFalse);
        final message = run.errors.join('\n');
        expect(message, contains('field "data" of Thing'));
        expect(message, contains('unsupported type'));
        expect(
          message,
          contains(
            'Cocoon stores int, double, bool, String, DateTime, Uint8List, '
            'enums, List<...> of those, and @Embedded classes',
          ),
        );
      },
    );

    test('a stored field without a constructor parameter fails', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing();

  final String name;
}
''';
      final lock = lockText(
        collections: {
          'Thing': TestCollection('things', const {'name': 'String'}),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains('Field "name" of Thing has no constructor parameter'),
      );
    });

    test('a constructor parameter without a stored field fails', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.name, required String suffix});

  final String name;
}
''';
      final lock = lockText(
        collections: {
          'Thing': TestCollection('things', const {'name': 'String'}),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains(
          'Constructor parameter "suffix" of Thing has no matching stored field',
        ),
      );
    });

    test('a missing part directive fails with the fix', () async {
      const model = '''
import 'package:cocoon/cocoon.dart';

@Collection('things')
class Thing {
  const Thing({required this.name});

  final String name;
}
''';
      final lock = lockText(
        collections: {
          'Thing': TestCollection('things', const {'name': 'String'}),
        },
      );
      final run = await runCocoonBuilder(model, lock);
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains("Add `part 'models.cocoon.dart';` to lib/models.dart"),
      );
    });

    test('generic models are rejected', () async {
      const model = '''
@Collection('things')
class Thing<T> {
  const Thing({required this.name});

  final String name;
}
''';
      final lock = lockText(
        collections: {
          'Thing': TestCollection('things', const {'name': 'String'}),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isFalse);
      expect(run.errors.join('\n'), contains('Class Thing is generic'));
    });

    test(
      'two models mapping to the same generated instance name fail',
      () async {
        const model = '''
@Collection('accounts/{accountId}/txns')
class Txn {
  const Txn({required this.bookedOn});

  final int bookedOn;
}

@Collection('ledgers/{ledgerId}/txns')
class LedgerTxn {
  const LedgerTxn({required this.bookedOn});

  final int bookedOn;
}
''';
        final lock = lockText(
          collections: {
            'Txn': TestCollection('accounts/{accountId}/txns', const {
              'bookedOn': 'int',
            }),
            'LedgerTxn': TestCollection('ledgers/{ledgerId}/txns', const {
              'bookedOn': 'int',
            }),
          },
        );
        final run = await runCocoonBuilder(_head + model, lock);
        expect(run.succeeded, isFalse);
        expect(
          run.errors.join('\n'),
          contains('both map to the generated top-level name "txns"'),
        );
      },
    );
  });

  group('the migration gate', () {
    const lock = '''
{
  "format": 1,
  "version": 2,
  "collections": {
    "Txn": {
      "path": "accounts/{accountId}/txns",
      "fields": {
        "bookedOn": {"number": 10, "type": "int"}
      },
      "reserved": [1],
      "indexes": []
    }
  }
}
''';

    test(
      'a migration file that still throws UnimplementedError fails',
      () async {
        final run = await runSchemaVersionBuilder(lock, {
          'a|lib/cocoon_migrations/m0002_txn_booked_on.dart': '''
// GENERATED CODE - DO NOT MODIFY BY HAND, except the conversion bodies.
//
// Cocoon schema migration to version 2. Implement every
// `upgrade...` function below, then run build_runner again: the build
// fails while any `UnimplementedError` remains.

import 'package:cocoon/cocoon.dart';

int upgradeTxnBookedOn(String old) =>
    throw UnimplementedError('Write the conversion');
''',
        });
        expect(run.succeeded, isFalse);
        expect(
          run.errors.join('\n'),
          contains('still contains an unimplemented conversion'),
        );
      },
    );

    test('an implemented migration passes even though the header mentions '
        'UnimplementedError', () async {
      final run = await runSchemaVersionBuilder(lock, {
        'a|lib/cocoon_migrations/m0002_txn_booked_on.dart': '''
// GENERATED CODE - DO NOT MODIFY BY HAND, except the conversion bodies.
//
// Cocoon schema migration to version 2. Implement every
// `upgrade...` function below, then run build_runner again: the build
// fails while any `UnimplementedError` remains.

import 'package:cocoon/cocoon.dart';

int upgradeTxnBookedOn(String old) => int.parse(old.replaceAll('-', ''));
''',
      });
      expect(run.succeeded, isTrue);
      expect(run.errors, isEmpty);
    });
  });
}
