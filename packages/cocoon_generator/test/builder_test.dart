/// End-to-end builder tests: the real `cocoonBuilder` runs over in-memory
/// model files and the generated part file is asserted on. Field numbers must
/// come only from the lock, and models that disagree with the lock must fail
/// with the `cocoon migrate` instruction.
library;

import 'package:cocoon_generator/src/lock_yaml.dart';
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

    test('a mirrored field gets a column and a handle but no index', () async {
      const model = '''
@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', '-bookedOn']),
])
class Txn {
  const Txn({required this.bookedOn, required this.amountMinor, required this.rate});

  final int bookedOn;
  @Mirrored()
  final int amountMinor;
  final double rate;
}
''';
      final lock = lockText(
        collections: {
          'Txn': TestCollection(
            'accounts/{accountId}/txns',
            const {'bookedOn': 'int', 'amountMinor': 'int', 'rate': 'double'},
            indexes: const [
              ['accountId', '-bookedOn'],
            ],
            mirrored: const ['amountMinor'],
          ),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      // Mirrored fields emit the same column factory as indexed ones, in
      // handle order: index fields first, then the mirrored-only one.
      expect(run.code, contains('FieldColumn.integer<Txn, int>('));
      expect(run.code, contains("'amountMinor',"));
      expect(run.code, contains('Txn\$.amountMinor'));
      expect(
        run.code.indexOf('Txn\$.bookedOn'),
        lessThan(run.code.indexOf('Txn\$.amountMinor')),
      );
      // And no index: only the declared one is emitted.
      expect(
        run.code,
        contains("IndexDef.fromFields(const ['accountId', '-bookedOn']),"),
      );
      expect(
        run.code,
        isNot(contains("IndexDef.fromFields(const ['amountMinor'])")),
      );
    });

    test('mirrored and indexed is one column, not two', () async {
      const model = '''
@Collection('accounts/{accountId}/txns', indexes: [
  Index(['accountId', 'amountMinor']),
])
class Txn {
  const Txn({required this.bookedOn, required this.amountMinor});

  final int bookedOn;
  @Mirrored()
  final int amountMinor;
}
''';
      final lock = lockText(
        collections: {
          'Txn': TestCollection(
            'accounts/{accountId}/txns',
            const {'bookedOn': 'int', 'amountMinor': 'int'},
            indexes: const [
              ['accountId', 'amountMinor'],
            ],
            mirrored: const ['amountMinor'],
          ),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      // One column (the index's), one handle: the mirrored flag adds
      // nothing the index did not already provide.
      expect(run.code, contains("'amountMinor',"));
      expect(run.code, contains('Txn\$.amountMinor'));
      expect("'amountMinor',".allMatches(run.code), hasLength(1));
    });

    test('a mirrored nullable column carries its nullability', () async {
      const model = '''
@Collection('notes')
class Note {
  const Note({this.tag});
  @Mirrored()
  final String? tag;
}
''';
      final lock = lockText(
        collections: {
          'Note': TestCollection(
            'notes',
            const {'tag': 'String?'},
            mirrored: const ['tag'],
          ),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(run.code, contains('FieldColumn.text<Note, String?>('));
      expect(run.code, contains("'tag',"));
      expect(run.code, contains('nullable: true'));
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
      // The header names the file the lock lives in.
      expect(
        run.code,
        contains('// Generated by cocoon_generator from `cocoon.lock`.\n'),
      );
      expect(run.code, contains('/// committed `cocoon.lock`.\n'));
    });

    test('map fields encode as sorted entry messages and decode into '
        'accumulators', () async {
      const model = '''
@Collection('txns')
class Txn {
  const Txn({required this.meta, this.extra, this.byDay = const {}});
  final Map<String, String> meta;
  final Map<String, List<int>>? extra;
  final Map<int, bool> byDay;
}
''';
      final lock = lockText(
        collections: {
          'Txn': TestCollection('txns', const {
            'meta': 'Map<String,String>',
            'extra': 'Map<String,List<int>>?',
            'byDay': 'Map<int,bool>',
          }),
        },
      );
      final run = await runCocoonBuilder(_head + model, lock);
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      // Encode: entries sorted by key, key at field 1, value at field 2,
      // so equal maps always give equal bytes.
      expect(
        run.code,
        contains('final \$metaEntries = value.meta.entries.toList()'),
      );
      expect(
        run.code,
        contains("..sort((\$a, \$b) => \$a.key.compareTo(\$b.key));"),
      );
      expect(run.code, contains('writer.writeMessage(1, (entry) {'));
      expect(run.code, contains("entry.writeString(1, \$metaEntry.key);"));
      expect(run.code, contains("entry.writeString(2, \$metaEntry.value);"));
      // Nullable maps go through the null check first.
      expect(run.code, contains('final \$extra = value.extra;'));
      expect(run.code, contains('if (\$extra != null) {'));
      // List values nest one level deeper inside the entry message.
      expect(run.code, contains('entry.writeMessage(2, (nested) {'));
      expect(run.code, contains('nested.writeSint64(\$i, \$element);'));
      // int keys are zigzag varints, bools varints.
      expect(run.code, contains("entry.writeSint64(1, \$byDayEntry.key);"));
      expect(run.code, contains('entry.writeBool(2, \$byDayEntry.value);'));
      // Decode: one accumulator per map field, entries parsed key/value.
      expect(
        run.code,
        contains(
          'final Map<String, String> \$metaEntries = <String, String>{};',
        ),
      );
      expect(
        run.code,
        contains(
          'final Map<String, List<int>> \$extraEntries = <String, List<int>>{};',
        ),
      );
      expect(run.code, contains('\$metaKey = \$metaReader.readString();'));
      expect(run.code, contains('\$byDayKey = \$byDayReader.readSint64();'));
      expect(run.code, contains('\$metaEntries[\$metaKey] = \$metaValue;'));
      // The field locals resolve after the decode loop: constructor
      // default, else null when nullable, else the accumulated map. The
      // fragments are matched wrap-tolerantly: dart format may split a
      // long conditional across lines.
      expect(run.code, contains('Map<String, String> \$meta = \$metaEntries;'));
      expect(
        run.code,
        matches(
          RegExp(r'\$extraEntries\.isEmpty\s*\?\s*null\s*:\s*\$extraEntries'),
        ),
      );
      expect(
        run.code,
        matches(
          RegExp(
            r'\$byDayEntries\.isEmpty\s*\?\s*const \{\}\s*:\s*\$byDayEntries',
          ),
        ),
      );
      // toInspectorJson: a JSON object; String keys are JSON keys as they
      // are, int keys become their decimal string form.
      expect(
        run.code,
        contains(
          "for (final \$entry in value.meta.entries) \$entry.key: \$entry.value",
        ),
      );
      expect(
        run.code,
        contains(
          "for (final \$entry in value.byDay.entries) '\${\$entry.key}'",
        ),
      );
    });

    test(
      'map values of every supported kind encode through the entry',
      () async {
        const model = '''
@Embedded()
class Line {
  const Line({required this.text});
  final String text;
}

enum Kind { a, b }

@Collection('records')
class Record {
  const Record({
    required this.counts,
    required this.rates,
    required this.flags,
    required this.days,
    required this.blobs,
    required this.kinds,
    required this.lines,
  });
  final Map<String, int> counts;
  final Map<String, double> rates;
  final Map<String, bool> flags;
  final Map<String, DateTime> days;
  final Map<String, Uint8List> blobs;
  final Map<String, Kind> kinds;
  final Map<int, Line> lines;
}
''';
        final lock = lockText(
          version: 1,
          collections: {
            'Record': TestCollection('records', const {
              'counts': 'Map<String,int>',
              'rates': 'Map<String,double>',
              'flags': 'Map<String,bool>',
              'days': 'Map<String,DateTime>',
              'blobs': 'Map<String,Uint8List>',
              'kinds': 'Map<String,enum:Kind>',
              'lines': 'Map<int,embedded:Line>',
            }),
          },
          embedded: {
            'Line': const {'text': 'String'},
          },
        );
        final run = await runCocoonBuilder(_head + model, lock);
        expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
        expect(
          run.code,
          contains('entry.writeSint64(2, \$countsEntry.value);'),
        );
        expect(run.code, contains('entry.writeDouble(2, \$ratesEntry.value);'));
        expect(run.code, contains('entry.writeBool(2, \$flagsEntry.value);'));
        expect(
          run.code,
          contains('entry.writeSint64(2, \$daysEntry.value.toUtc()'),
        );
        expect(run.code, contains('entry.writeBytes(2, \$blobsEntry.value);'));
        expect(
          run.code,
          contains('entry.writeString(2, \$kindsEntry.value.name);'),
        );
        expect(
          run.code,
          contains('Line\$.writeTo(entry, 2, \$linesEntry.value);'),
        );
        // The embedded zero value fills in when an entry lacks its value.
        expect(run.code, contains('var \$linesValue = Line\$.zero();'));
      },
    );
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
      expect(run.errors.join('\n'), contains('cocoon.lock is missing'));
    });

    test('the legacy cocoon.lock.json still builds', () async {
      final legacyJson = parseLockYaml(
        lockText(
          collections: {
            'Txn': TestCollection('accounts/{accountId}/txns', const {
              'bookedOn': 'int',
            }),
          },
        ),
      ).toSource();
      const model = '''
@Collection('accounts/{accountId}/txns')
class Txn {
  const Txn({required this.bookedOn});

  final int bookedOn;
}
''';
      final run = await runCocoonBuilder(_head + model, '', {
        'a|$legacyLockFileName': legacyJson,
      });
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      // The part file header proves the JSON lock was read and parsed.
      expect(
        run.code,
        contains(
          'generated by cocoon_generator from `cocoon.lock` (schema version 1)',
        ),
      );
    });

    test('both lock files present refuse the build', () async {
      final yamlLock = lockText(
        collections: {
          'Txn': TestCollection('accounts/{accountId}/txns', const {
            'bookedOn': 'int',
          }),
        },
      );
      final jsonLock = parseLockYaml(yamlLock).toSource();
      const model = '''
@Collection('accounts/{accountId}/txns')
class Txn {
  const Txn({required this.bookedOn});

  final int bookedOn;
}
''';
      final run = await runCocoonBuilder(_head + model, yamlLock, {
        'a|$legacyLockFileName': jsonLock,
      });
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains('Both cocoon.lock and cocoon.lock.json exist'),
      );

      // The schema-version builder is planned per lock input; with both
      // present build_runner refuses the colliding output before the
      // builder runs — either way the build fails.
      await expectLater(
        runSchemaVersionBuilder(yamlLock, {'a|$legacyLockFileName': jsonLock}),
        throwsA(
          predicate(
            (Object error) => error.toString().contains('outputs collide'),
          ),
        ),
      );
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

  final Object data;
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
            'enums, List<...> and Map<String|int, ...> of those, and '
            '@Embedded classes',
          ),
        );
      },
    );

    test('map keys must be String or int', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.data});
  final Map<double, int> data;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection('things', const {'data': 'int'}),
          },
        ),
      );
      expect(run.succeeded, isFalse);
      final message = run.errors.join('\n');
      expect(message, contains('field "data" of Thing'));
      expect(message, contains('map keys must be String or int'));
    });

    test('map values may not be nullable', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.data});
  final Map<String, int?> data;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection('things', const {'data': 'int'}),
          },
        ),
      );
      expect(run.succeeded, isFalse);
      final message = run.errors.join('\n');
      expect(message, contains('field "data" of Thing'));
      expect(message, contains('map values may not be nullable'));
    });

    test('a Map value inside a Map is rejected', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.data});
  final Map<String, Map<String, int>> data;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection('things', const {'data': 'int'}),
          },
        ),
      );
      expect(run.succeeded, isFalse);
      final message = run.errors.join('\n');
      expect(message, contains('field "data" of Thing'));
      expect(message, contains('a Map value inside a Map is not supported'));
    });

    test('a Map inside a List inside a Map is rejected', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.data});
  final Map<String, List<Map<String, int>>> data;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection('things', const {'data': 'int'}),
          },
        ),
      );
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains('a Map value inside a Map is not supported'),
      );
    });

    test('nested lists are a build error naming the field', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.grid});
  final List<List<int>> grid;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection('things', const {'grid': 'int'}),
          },
        ),
      );
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains('field "grid" of Thing: nested lists'),
      );
    });

    test(
      'mirroring a list field fails naming the field and the types',
      () async {
        const model = '''
@Collection('things')
class Thing {
  const Thing({required this.tags});
  @Mirrored()
  final List<String> tags;
}
''';
        final run = await runCocoonBuilder(
          _head + model,
          lockText(
            collections: {
              'Thing': TestCollection(
                'things',
                const {'tags': 'List<String>'},
                mirrored: const ['tags'],
              ),
            },
          ),
        );
        expect(run.succeeded, isFalse);
        final message = run.errors.join('\n');
        expect(message, contains('Field "tags" of Thing cannot be mirrored'));
        expect(message, contains('List<String> has no column'));
        expect(message, contains('Only int, double, bool, String, DateTime,'));
      },
    );

    test('a @Mirrored field inside an @Embedded class fails', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.address});
  final Address address;
}

@Embedded()
class Address {
  const Address({required this.city});
  @Mirrored()
  final String city;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection('things', const {
              'address': 'embedded:Address',
            }),
          },
          embedded: {
            'Address': const {'city': 'String'},
          },
        ),
      );
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains(
          'Field "city" of Address cannot be @Mirrored: the annotation is '
          'only allowed on @Collection model fields',
        ),
      );
    });

    test('indexing a map field fails naming the field', () async {
      const model = '''
@Collection('things', indexes: [Index(['meta'])])
class Thing {
  const Thing({required this.meta});
  final Map<String, int> meta;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection(
              'things',
              const {'meta': 'Map<String,int>'},
              indexes: const [
                ['meta'],
              ],
            ),
          },
        ),
      );
      expect(run.succeeded, isFalse);
      final message = run.errors.join('\n');
      expect(message, contains('Field "meta" of Thing cannot be indexed'));
      expect(message, contains('Map fields are stored inside the document'));
    });

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

  group('@Indexed() on a field', () {
    // The same one-field index declared the two ways: on the class and on
    // the field. The lock cannot tell them apart — the canonical form is
    // the identity, so moving the declaration bumps nothing.
    const classIndexedModel = '''
@Collection('txns', indexes: [Index(['amountMinor'])])
class Txn {
  const Txn({required this.amountMinor});
  final int amountMinor;
}
''';
    const fieldIndexedModel = '''
@Collection('txns')
class Txn {
  const Txn({required this.amountMinor});
  @Indexed()
  final int amountMinor;
}
''';
    final amountMinorLock = lockText(
      collections: {
        'Txn': TestCollection(
          'txns',
          const {'amountMinor': 'int'},
          indexes: const [
            ['amountMinor'],
          ],
        ),
      },
    );

    test('emits the same canonical index as the class-level form', () async {
      final fromField = await runCocoonBuilder(
        _head + fieldIndexedModel,
        amountMinorLock,
      );
      final fromClass = await runCocoonBuilder(
        _head + classIndexedModel,
        amountMinorLock,
      );
      expect(fromField.succeeded, isTrue, reason: fromField.errors.join('\n'));
      expect(fromClass.succeeded, isTrue, reason: fromClass.errors.join('\n'));
      const declaration = "IndexDef.fromFields(const ['amountMinor'])";
      expect(fromField.code, contains(declaration));
      expect(fromClass.code, contains(declaration));
      // Exactly one index either way — the declaration moved, nothing was
      // added.
      expect(declaration.allMatches(fromField.code), hasLength(1));
      expect(declaration.allMatches(fromClass.code), hasLength(1));
    });

    test('descending and unique flags reach the IndexDef', () async {
      const model = '''
@Collection('txns')
class Txn {
  const Txn({required this.amountMinor, required this.currency});
  @Indexed(descending: true)
  final int amountMinor;
  @Indexed(unique: true)
  final String currency;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Txn': TestCollection(
              'txns',
              const {'amountMinor': 'int', 'currency': 'String'},
              indexes: const [
                ['-amountMinor'],
                ['currency'],
              ],
            ),
          },
        ),
      );
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(run.code, contains("IndexDef.fromFields(const ['-amountMinor'])"));
      expect(
        run.code,
        contains("IndexDef.fromFields(const ['currency'], unique: true)"),
      );
    });

    test('an index declared both ways is one index', () async {
      const model = '''
@Collection('txns', indexes: [Index(['currency'])])
class Txn {
  const Txn({required this.currency});
  @Indexed()
  final String currency;
}
''';
      // The lock declares the index once; the build only passes while the
      // merge keeps it at one.
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Txn': TestCollection(
              'txns',
              const {'currency': 'String'},
              indexes: const [
                ['currency'],
              ],
            ),
          },
        ),
      );
      expect(run.succeeded, isTrue, reason: run.errors.join('\n'));
      expect(
        "IndexDef.fromFields(const ['currency'])".allMatches(run.code),
        hasLength(1),
      );
    });

    test(
      'indexing an unsupported field type fails like @Mirrored does',
      () async {
        const model = '''
@Collection('things')
class Thing {
  const Thing({required this.tags});
  @Indexed()
  final List<String> tags;
}
''';
        final run = await runCocoonBuilder(
          _head + model,
          lockText(
            collections: {
              'Thing': TestCollection(
                'things',
                const {'tags': 'List<String>'},
                indexes: const [
                  ['tags'],
                ],
              ),
            },
          ),
        );
        expect(run.succeeded, isFalse);
        final message = run.errors.join('\n');
        expect(message, contains('Field "tags" of Thing cannot be indexed'));
        expect(message, contains('List<String> has no column'));
        expect(message, contains('Only int, double, bool, String, DateTime,'));
      },
    );

    test('a @Indexed field inside an @Embedded class fails', () async {
      const model = '''
@Collection('things')
class Thing {
  const Thing({required this.address});
  final Address address;
}

@Embedded()
class Address {
  const Address({required this.city});
  @Indexed()
  final String city;
}
''';
      final run = await runCocoonBuilder(
        _head + model,
        lockText(
          collections: {
            'Thing': TestCollection('things', const {
              'address': 'embedded:Address',
            }),
          },
          embedded: {
            'Address': const {'city': 'String'},
          },
        ),
      );
      expect(run.succeeded, isFalse);
      expect(
        run.errors.join('\n'),
        contains(
          'Field "city" of Address cannot be @Indexed: the annotation is '
          'only allowed on @Collection model fields',
        ),
      );
    });
  });
}
