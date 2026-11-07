import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

void main() {
  test('matches the protobuf reference encoding', () {
    // From the protobuf encoding guide: field 1 = 150 is 08 96 01.
    final w = WireWriter()..writeInt64(1, 150);
    expect(w.toBytes(), [0x08, 0x96, 0x01]);

    final s = WireWriter()..writeString(2, 'testing');
    expect(s.toBytes(), [0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67]);
  });

  test('zigzag keeps small negatives small', () {
    final w = WireWriter()..writeSint64(1, -1);
    expect(w.toBytes(), [0x08, 0x01]);
    final plain = WireWriter()..writeInt64(1, -1);
    expect(plain.toBytes(), hasLength(11));
  });

  test('round-trips every supported type, including 64-bit extremes', () {
    const minInt = -9223372036854775808;
    const maxInt = 0x7FFFFFFFFFFFFFFF;
    final bytes =
        (WireWriter()
              ..writeInt64(1, minInt)
              ..writeInt64(2, maxInt)
              ..writeSint64(3, minInt)
              ..writeSint64(4, maxInt)
              ..writeSint64(5, -12345)
              ..writeBool(6, true)
              ..writeDouble(7, 3.14159)
              ..writeString(8, 'RM 12.50 \u2705')
              ..writeBytes(9, [1, 2, 3])
              ..writeMessage(
                10,
                (m) => m
                  ..writeString(1, 'nested')
                  ..writeSint64(2, -7),
              ))
            .toBytes();

    final r = WireReader(bytes);
    expect(r.readTag(), (field: 1, type: WireType.varint));
    expect(r.readInt64(), minInt);
    r.readTag();
    expect(r.readInt64(), maxInt);
    r.readTag();
    expect(r.readSint64(), minInt);
    r.readTag();
    expect(r.readSint64(), maxInt);
    r.readTag();
    expect(r.readSint64(), -12345);
    r.readTag();
    expect(r.readBool(), isTrue);
    expect(r.readTag(), (field: 7, type: WireType.i64));
    expect(r.readDouble(), 3.14159);
    expect(r.readTag(), (field: 8, type: WireType.len));
    expect(r.readString(), 'RM 12.50 \u2705');
    r.readTag();
    expect(r.readBytes(), [1, 2, 3]);
    r.readTag();
    final nested = r.readMessage();
    nested.readTag();
    expect(nested.readString(), 'nested');
    nested.readTag();
    expect(nested.readSint64(), -7);
    expect(nested.isAtEnd, isTrue);
    expect(r.isAtEnd, isTrue);
  });

  test('skips unknown fields of every wire type', () {
    final bytes =
        (WireWriter()
              ..writeInt64(1, 99)
              ..writeDouble(2, 1.5)
              ..writeString(3, 'gone')
              ..writeSint64(4, -2))
            .toBytes();
    final r = WireReader(bytes);
    for (var i = 0; i < 3; i++) {
      r.skip(r.readTag().type);
    }
    expect(r.readTag().field, 4);
    expect(r.readSint64(), -2);
  });

  test('enforces ascending field order but allows repeated fields', () {
    final w = WireWriter()
      ..writeString(1, 'a')
      ..writeString(1, 'b')
      ..writeInt64(3, 1);
    expect(() => w.writeInt64(2, 1), throwsStateError);
    expect(() => WireWriter().writeInt64(0, 1), throwsRangeError);
  });

  test('same input produces identical bytes', () {
    Uint8List encode() =>
        (WireWriter()
              ..writeString(1, 'staff')
              ..writeSint64(2, 500))
            .toBytes();
    expect(encode(), encode());
  });

  test('rejects truncated and overlong data', () {
    expect(
      () => WireReader(Uint8List.fromList([0x08]))
        ..readTag()
        ..readInt64(),
      throwsFormatException,
    );
    expect(
      () => WireReader(Uint8List.fromList([0x12, 0x05, 0x61]))
        ..readTag()
        ..readBytes(),
      throwsFormatException,
    );
    final overlong = Uint8List.fromList([...List.filled(10, 0xFF), 0x01]);
    expect(() => WireReader(overlong).readInt64(), throwsFormatException);
  });
}
