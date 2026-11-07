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
}
