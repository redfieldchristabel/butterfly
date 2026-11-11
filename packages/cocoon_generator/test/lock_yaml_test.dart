/// Tests for the `cocoon.lock` YAML text: the emitter is byte-stable, the
/// `package:yaml` reader and the runtime's `SchemaLock.parse` agree with it,
/// and a lock's fingerprint does not depend on the file shape it came from.
library;

import 'dart:convert';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_generator/src/lock_yaml.dart';
import 'package:test/test.dart';

/// A lock with every shape the file format carries: descending index parts,
/// reserved numbers, mirrored fields, a recorded keep-zero, map and enum
/// field types and embedded classes.
SchemaLock richLock() => SchemaLock.fromJson(const {
  'format': 1,
  'version': 7,
  'collections': {
    'Txn': {
      'path': 'accounts/{accountId}/txns',
      'fields': {
        'bookedOn': {'number': 2, 'type': 'int'},
        'amountMinor': {'number': 3, 'type': 'int'},
        'currency': {'number': 4, 'type': 'String'},
        'status': {'number': 5, 'type': 'enum:TxnStatus'},
        'rate': {'number': 6, 'type': 'double?'},
        'meta': {'number': 10, 'type': 'Map<String,int>'},
      },
      'reserved': [1, 8],
      'indexes': [
        ['accountId', '-bookedOn'],
        ['status', 'bookedOn'],
      ],
      'mirrored': ['amountMinor'],
      'keepZero': ['currency'],
    },
  },
  'embedded': {
    'Badge': {
      'fields': {
        'code': {'number': 1, 'type': 'String'},
      },
      'reserved': [],
    },
  },
});

void main() {
  test('writing, reading and writing again is byte-identical', () {
    final lock = richLock();
    final first = lockYamlSource(lock);
    final second = lockYamlSource(parseLockYaml(first));
    expect(second, first);
    expect(first, endsWith('\n'));
    expect(first.startsWith('$lockYamlHeader\n'), isTrue, reason: first);
  });

  test('the emitted text parses back to the same lock (package:yaml)', () {
    final lock = richLock();
    final parsed = parseLockYaml(lockYamlSource(lock));
    expect(jsonEncode(parsed.toJson()), jsonEncode(lock.toJson()));
  });

  test('the emitted text parses back to the same lock (runtime reader)', () {
    // SchemaLock.parse accepts the YAML shape too: apps read the committed
    // file with it, so both readers must agree byte for byte.
    final lock = richLock();
    final text = lockYamlSource(lock);
    final runtime = SchemaLock.parse(text);
    final generator = parseLockYaml(text);
    expect(jsonEncode(runtime.toJson()), jsonEncode(generator.toJson()));
  });

  test('the same lock as JSON and as YAML carries the same fingerprint', () {
    // The engine fingerprints `jsonEncode(lock.toJson())`: a database opened
    // with the parsed YAML lock must hash equal to one opened with the same
    // lock from the legacy JSON file, so nothing re-migrates.
    final lock = richLock();
    final jsonText = lock.toSource();
    expect(
      jsonEncode(SchemaLock.parse(jsonText).toJson()),
      jsonEncode(parseLockYaml(lockYamlSource(lock)).toJson()),
    );
  });

  test('strings are quoted only where YAML needs it', () {
    final text = lockYamlSource(richLock());
    // Plain where possible: paths, types, descending index parts (both
    // readers resolve them back to the same strings).
    expect(text, contains('path: accounts/{accountId}/txns\n'));
    expect(text, contains('        - -bookedOn\n'));
    expect(text, contains('type: Map<String,int>\n'));
    expect(text, contains('type: enum:TxnStatus\n'));
    // Nothing in the lock body is quoted at all.
    final body = text.split('\n').skip(2).join('\n');
    expect(body, isNot(contains("'")));
    expect(body, isNot(contains('"')));
  });

  test('a field named like a YAML scalar survives the round trip', () {
    final lock = SchemaLock.fromJson(const {
      'format': 1,
      'version': 2,
      'collections': {
        'Flags': {
          'path': 'flags',
          'fields': {
            'no': {'number': 1, 'type': 'bool'},
            'true': {'number': 2, 'type': 'String'},
          },
          'reserved': [],
          'indexes': [],
        },
      },
    });
    final text = lockYamlSource(lock);
    final parsed = parseLockYaml(text);
    expect(parsed.collections['Flags']!.fields.map((f) => f.name), [
      'no',
      'true',
    ]);
    expect(SchemaLock.parse(text).toJson(), parsed.toJson());
  });
}
