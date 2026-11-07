/// Unit tests for `rewriteField`, the pure wire-level rewrite a schema
/// migration applies to every stored document.
library;

import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

/// Encodes fields in ascending order, as canonical documents are stored.
Uint8List doc(void Function(WireWriter writer) write) {
  final writer = WireWriter();
  write(writer);
  return writer.toBytes();
}

/// The field numbers of [bytes], in stored order.
List<int> fieldNumbers(Uint8List bytes) {
  final reader = WireReader(bytes);
  final numbers = <int>[];
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    numbers.add(tag.field);
    reader.skip(tag.type);
  }
  return numbers;
}

void main() {
  test('moves and converts a value to the new field number', () {
    final old = doc(
      (w) => w
        ..writeString(1, 'Acme')
        ..writeString(4, '458'),
    );
    final out = rewriteField(
      old,
      from: 4,
      fromWire: MigrationWireType.text,
      to: 10,
      toWire: MigrationWireType.sint64,
      convert: (value) => int.parse(value! as String),
    );
    expect(fieldNumbers(out), [1, 10]);
    final reader = WireReader(out)..readTag();
    expect(reader.readString(), 'Acme');
    reader.readTag();
    expect(reader.readSint64(), 458);
  });

  test('absent old field: convert is not called and nothing is written', () {
    final old = doc((w) => w..writeString(1, 'Acme'));
    var called = false;
    final out = rewriteField(
      old,
      from: 7,
      fromWire: MigrationWireType.text,
      to: 8,
      toWire: MigrationWireType.sint64,
      convert: (value) {
        called = true;
        return value;
      },
    );
    expect(called, isFalse);
    // Same instance and same bytes: the document is untouched.
    expect(identical(out, old), isTrue);
    expect(out, old);
    expect(fieldNumbers(out), [1]);
  });

  test('a null conversion result drops the value', () {
    final old = doc(
      (w) => w
        ..writeString(2, 'gone')
        ..writeBool(3, true),
    );
    final out = rewriteField(
      old,
      from: 2,
      fromWire: MigrationWireType.text,
      to: 5,
      toWire: MigrationWireType.text,
      convert: (value) => null,
    );
    expect(fieldNumbers(out), [3]);
  });

  test('keeps other fields byte-for-byte and the canonical order', () {
    final old = doc(
      (w) => w
        ..writeString(1, 'keep')
        ..writeSint64(2, -4299)
        ..writeString(3, 'SGD')
        ..writeDouble(9, 0.5),
    );
    final out = rewriteField(
      old,
      from: 3,
      fromWire: MigrationWireType.text,
      to: 5,
      toWire: MigrationWireType.sint64,
      convert: (value) => 702,
    );
    expect(fieldNumbers(out), [1, 2, 5, 9]);
    final reader = WireReader(out);
    expect(reader.readTag().field, 1);
    expect(reader.readString(), 'keep');
    reader.readTag();
    expect(reader.readSint64(), -4299);
    reader.readTag();
    expect(reader.readSint64(), 702);
    reader.readTag();
    expect(reader.readDouble(), 0.5);
    // Fields 1 and 2 were re-serialized as their exact input bytes (tag 1 +
    // 5-byte string, tag 2 + 1-byte zigzag varint).
    expect(out.sublist(0, 6 + 3), old.sublist(0, 9));
  });

  test('inserts the new value before higher field numbers', () {
    // The new number 3 is fresh, but the rewrite stays correct for any
    // ordering the caller asks for.
    final old = doc(
      (w) => w
        ..writeString(1, 'a')
        ..writeString(5, 'b'),
    );
    final out = rewriteField(
      old,
      from: 5,
      fromWire: MigrationWireType.text,
      to: 3,
      toWire: MigrationWireType.text,
      convert: (value) => value,
    );
    expect(fieldNumbers(out), [1, 3]);
  });

  test('repeated old fields: the last occurrence wins', () {
    final old = doc(
      (w) => w
        ..writeString(2, 'first')
        ..writeString(2, 'second')
        ..writeBool(3, true),
    );
    final seen = <Object?>[];
    final out = rewriteField(
      old,
      from: 2,
      fromWire: MigrationWireType.text,
      to: 4,
      toWire: MigrationWireType.text,
      convert: (value) {
        seen.add(value);
        return 'converted';
      },
    );
    expect(seen, ['second']);
    expect(fieldNumbers(out), [3, 4]);
    final reader = WireReader(out);
    reader.readTag();
    expect(reader.readBool(), isTrue);
    reader.readTag();
    expect(reader.readString(), 'converted');
  });

  test('int64 extremes survive an int64 rewrite', () {
    const minInt = -9223372036854775808;
    const maxInt = 0x7FFFFFFFFFFFFFFF;
    final old = doc(
      (w) => w
        ..writeInt64(1, minInt)
        ..writeInt64(2, maxInt),
    );
    final out = rewriteField(
      old,
      from: 1,
      fromWire: MigrationWireType.int64,
      to: 7,
      toWire: MigrationWireType.int64,
      convert: (value) => value,
    );
    expect(fieldNumbers(out), [2, 7]);
    final reader = WireReader(out);
    reader.readTag();
    expect(reader.readInt64(), maxInt);
    reader.readTag();
    expect(reader.readInt64(), minInt);
  });

  test('sint64 keeps negative money values exact', () {
    final old = doc((w) => w..writeSint64(2, -4299));
    final out = rewriteField(
      old,
      from: 2,
      fromWire: MigrationWireType.sint64,
      to: 5,
      toWire: MigrationWireType.sint64,
      convert: (value) => value,
    );
    final reader = WireReader(out)..readTag();
    expect(reader.readSint64(), -4299);
  });

  test('bool, double, text and bytes kinds round-trip', () {
    Uint8List rewriteOne(
      int from,
      MigrationWireType wire,
      Object? value,
    ) => rewriteField(
      doc(
        (w) => switch (wire) {
          MigrationWireType.int64 => w.writeInt64(from, value! as int),
          MigrationWireType.sint64 => w.writeSint64(from, value! as int),
          MigrationWireType.boolean => w.writeBool(from, value! as bool),
          MigrationWireType.float64 => w.writeDouble(from, value! as double),
          MigrationWireType.text => w.writeString(from, value! as String),
          MigrationWireType.bytes => w.writeBytes(from, value! as List<int>),
          MigrationWireType.map => throw StateError('not used here'),
        },
      ),
      from: from,
      fromWire: wire,
      to: from + 10,
      toWire: wire,
      convert: (converted) => converted,
    );

    final reader = WireReader(rewriteOne(1, MigrationWireType.boolean, true))
      ..readTag();
    expect(reader.readBool(), isTrue);

    final doubleReader = WireReader(
      rewriteOne(1, MigrationWireType.float64, 4.125),
    )..readTag();
    expect(doubleReader.readDouble(), 4.125);

    final textReader = WireReader(rewriteOne(1, MigrationWireType.text, 'MYR'))
      ..readTag();
    expect(textReader.readString(), 'MYR');

    final bytesReader = WireReader(
      rewriteOne(1, MigrationWireType.bytes, [1, 2, 255]),
    )..readTag();
    expect(bytesReader.readBytes(), [1, 2, 255]);
  });

  test('the input document is never mutated', () {
    final old = doc(
      (w) => w
        ..writeString(1, 'before')
        ..writeString(2, 'x'),
    );
    final copy = Uint8List.fromList(old);
    rewriteField(
      old,
      from: 2,
      fromWire: MigrationWireType.text,
      to: 3,
      toWire: MigrationWireType.text,
      convert: (value) => value,
    );
    expect(old, copy);
  });

  test('rejects documents that are not in canonical order', () {
    // Hand-built bytes: fields 5, 2, 3 in that (descending) order, with
    // field 2 the one being rewritten. The rewrite re-serializes in input
    // order, so the writer refuses the non-canonical input.
    final raw = Uint8List.fromList([
      0x28, 0x01, // field 5, varint 1
      0x10, 0x01, // field 2, varint 1
      0x18, 0x01, // field 3, varint 1
    ]);
    expect(
      () => rewriteField(
        raw,
        from: 2,
        fromWire: MigrationWireType.int64,
        to: 4,
        toWire: MigrationWireType.int64,
        convert: (value) => value,
      ),
      throwsStateError,
    );
  });

  group('map fields', () {
    /// Builds a document with a map at field [number]: each (key, value)
    /// pair is written as one entry message, in the order given.
    Uint8List mapDoc(
      int number,
      List<(String, int)> entries,
    ) => doc(
      (w) {
        for (final (key, value) in entries) {
          w.writeMessage(number, (entry) {
            entry.writeString(1, key);
            entry.writeSint64(2, value);
          });
        }
      },
    );

    /// Reads the entries of the map at field [number] out of [bytes];
    /// [intKeys] picks how entry keys are decoded.
    Map<Object?, Object?> readMap(
      Uint8List bytes,
      int number, {
      bool intKeys = false,
    }) {
      final reader = WireReader(bytes);
      final map = <Object?, Object?>{};
      while (!reader.isAtEnd) {
        final tag = reader.readTag();
        if (tag.field != number) {
          reader.skip(tag.type);
          continue;
        }
        final entry = reader.readMessage();
        Object? key;
        Object? value;
        while (!entry.isAtEnd) {
          final entryTag = entry.readTag();
          switch (entryTag.field) {
            case 1:
              key = intKeys ? entry.readSint64() : entry.readString();
            case 2:
              value = entryTag.type == WireType.len
                  ? entry.readString()
                  : entry.readSint64();
            default:
              entry.skip(entryTag.type);
          }
        }
        map[key!] = value;
      }
      return map;
    }

    test('rewrites every entry, converting keys and values', () {
      const textToInt = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.sint64,
      );
      const intToText = MapWireType(
        key: MigrationWireType.sint64,
        value: MigrationWireType.text,
      );
      final out = rewriteField(
        mapDoc(3, [('rent', 700), ('groceries', 300)]),
        from: 3,
        fromWire: MigrationWireType.map,
        fromMap: textToInt,
        to: 8,
        toWire: MigrationWireType.map,
        toMap: intToText,
        convert: (value) => {
          for (final MapEntry(key: key, value: amount)
              in (value! as Map<Object?, Object?>).entries)
            (key! as String).length: (amount! as int).toString(),
        },
      );
      expect(readMap(out, 8, intKeys: true), {4: '700', 9: '300'});
    });

    test('writes entries sorted by key, whatever the input order', () {
      const mapWire = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.sint64,
      );
      final out = rewriteField(
        mapDoc(3, [('zebra', 1), ('apple', 2), ('mango', 3)]),
        from: 3,
        fromWire: MigrationWireType.map,
        fromMap: mapWire,
        to: 4,
        toWire: MigrationWireType.map,
        toMap: mapWire,
        convert: (value) => value,
      );
      // Entry order in the bytes: apple, mango, zebra.
      final reader = WireReader(out);
      final keys = <String>[];
      while (!reader.isAtEnd) {
        reader.readTag();
        final entry = reader.readMessage();
        entry.readTag();
        keys.add(entry.readString());
        entry.skip(WireType.varint); // the value at field 2
      }
      expect(keys, ['apple', 'mango', 'zebra']);
    });

    test('sorts int keys numerically, including negatives', () {
      const intKeys = MapWireType(
        key: MigrationWireType.sint64,
        value: MigrationWireType.sint64,
      );
      Uint8List intMapDoc(List<(int, int)> entries) => doc(
        (w) {
          for (final (key, value) in entries) {
            w.writeMessage(2, (entry) {
              entry.writeSint64(1, key);
              entry.writeSint64(2, value);
            });
          }
        },
      );
      final out = rewriteField(
        intMapDoc([(5, 1), (-7, 2), (0, 3)]),
        from: 2,
        fromWire: MigrationWireType.map,
        fromMap: intKeys,
        to: 3,
        toWire: MigrationWireType.map,
        toMap: intKeys,
        convert: (value) => value,
      );
      final reader = WireReader(out);
      final keys = <int>[];
      while (!reader.isAtEnd) {
        reader.readTag();
        final entry = reader.readMessage();
        entry.readTag();
        keys.add(entry.readSint64());
        entry.readTag();
        entry.readSint64();
      }
      expect(keys, [-7, 0, 5]);
    });

    test('the last occurrence of a duplicate key wins', () {
      const mapWire = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.sint64,
      );
      final seen = <Object?>[];
      final out = rewriteField(
        mapDoc(3, [('k', 1), ('k', 2)]),
        from: 3,
        fromWire: MigrationWireType.map,
        fromMap: mapWire,
        to: 4,
        toWire: MigrationWireType.map,
        toMap: mapWire,
        convert: (value) {
          seen.add(value);
          return value;
        },
      );
      expect(seen.single, {'k': 2});
      expect(readMap(out, 4), {'k': 2});
    });

    test('an empty converted map writes nothing', () {
      const mapWire = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.sint64,
      );
      final out = rewriteField(
        mapDoc(3, [('k', 1)]),
        from: 3,
        fromWire: MigrationWireType.map,
        fromMap: mapWire,
        to: 4,
        toWire: MigrationWireType.map,
        toMap: mapWire,
        convert: (value) => <String, int>{},
      );
      expect(fieldNumbers(out), isEmpty);
    });

    test('a null conversion result drops the whole map', () {
      const mapWire = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.sint64,
      );
      final out = rewriteField(
        doc(
          (w) => w
            ..writeString(1, 'keep')
            ..writeMessage(3, (entry) {
              entry.writeString(1, 'k');
              entry.writeSint64(2, 1);
            }),
        ),
        from: 3,
        fromWire: MigrationWireType.map,
        fromMap: mapWire,
        to: 4,
        toWire: MigrationWireType.map,
        toMap: mapWire,
        convert: (value) => null,
      );
      expect(fieldNumbers(out), [1]);
    });

    test('rewrites a scalar field into a map and back', () {
      const mapWire = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.text,
      );
      // String #2 -> Map<String,String> #5.
      final toMap = rewriteField(
        doc((w) => w..writeString(2, 'MYR=458')),
        from: 2,
        fromWire: MigrationWireType.text,
        to: 5,
        toWire: MigrationWireType.map,
        toMap: mapWire,
        convert: (value) => {'rate': value! as String},
      );
      final mapBack = rewriteField(
        toMap,
        from: 5,
        fromWire: MigrationWireType.map,
        fromMap: mapWire,
        to: 2,
        toWire: MigrationWireType.text,
        convert: (value) =>
            (value! as Map<Object?, Object?>).entries.single.value,
      );
      final reader = WireReader(mapBack)..readTag();
      expect(reader.readString(), 'MYR=458');
    });

    test('absent map field: convert is not called', () {
      const mapWire = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.sint64,
      );
      final old = doc((w) => w..writeString(1, 'Acme'));
      var called = false;
      final out = rewriteField(
        old,
        from: 3,
        fromWire: MigrationWireType.map,
        fromMap: mapWire,
        to: 4,
        toWire: MigrationWireType.map,
        toMap: mapWire,
        convert: (value) {
          called = true;
          return value;
        },
      );
      expect(called, isFalse);
      expect(identical(out, old), isTrue);
    });

    test('requires a MapWireType beside every map wire kind', () {
      expect(
        () => rewriteField(
          mapDoc(3, [('k', 1)]),
          from: 3,
          fromWire: MigrationWireType.map,
          to: 4,
          toWire: MigrationWireType.map,
          convert: (value) => value,
        ),
        throwsArgumentError,
      );
      expect(
        () => rewriteField(
          mapDoc(3, [('k', 1)]),
          from: 3,
          fromWire: MigrationWireType.text,
          fromMap: const MapWireType(
            key: MigrationWireType.text,
            value: MigrationWireType.sint64,
          ),
          to: 4,
          toWire: MigrationWireType.text,
          convert: (value) => value,
        ),
        throwsArgumentError,
      );
    });

    test('mixed key types from a broken conversion are rejected', () {
      const mapWire = MapWireType(
        key: MigrationWireType.text,
        value: MigrationWireType.sint64,
      );
      expect(
        () => rewriteField(
          mapDoc(3, [('k', 1)]),
          from: 3,
          fromWire: MigrationWireType.map,
          fromMap: mapWire,
          to: 4,
          toWire: MigrationWireType.map,
          toMap: mapWire,
          convert: (value) => {'a': 1, 2: 3},
        ),
        throwsArgumentError,
      );
    });
  });
}
