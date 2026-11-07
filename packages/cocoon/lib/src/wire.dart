import 'dart:convert';
import 'dart:typed_data';

/// Highest field number the protobuf wire format allows.
const maxFieldNumber = 536870911;

/// Protobuf wire types Cocoon writes and reads.
enum WireType {
  varint(0),
  i64(1),
  len(2),
  i32(5);

  const WireType(this.id);

  /// The 3-bit id stored in a field tag.
  final int id;

  /// The wire type for [id], throwing a [FormatException] for unknown ids.
  static WireType fromId(int id) => switch (id) {
    0 => varint,
    1 => i64,
    2 => len,
    5 => i32,
    _ => throw FormatException('Unsupported wire type $id'),
  };
}

/// The exact wire encoding of one field value involved in a schema
/// migration.
///
/// The protobuf wire type alone cannot decode a value: `int64`, `sint64` and
/// `bool` are all varints but decode differently. A [FieldMigration]
/// therefore pins the encoding of both sides of the rewrite.
enum MigrationWireType {
  /// Plain two's-complement varint, as [WireWriter.writeInt64] writes it.
  int64,

  /// Zigzag varint, as [WireWriter.writeSint64] writes it. The code
  /// generator encodes `int` and `DateTime` fields this way.
  sint64,

  /// Varint `0`/`1`, as [WireWriter.writeBool] writes it.
  boolean,

  /// Little-endian IEEE 754 double, as [WireWriter.writeDouble] writes it.
  float64,

  /// UTF-8 text, as [WireWriter.writeString] writes it. Enums are stored as
  /// their name, so they migrate as [text] too.
  text,

  /// Length-delimited bytes, as [WireWriter.writeBytes] writes it. Nested
  /// messages (lists and `@Embedded` values) are [bytes] as well.
  bytes,
}

/// Writes the protobuf binary wire format in canonical form.
///
/// Canonical means the same document always produces the same bytes, which
/// is what lets a journal chain hash encoded documents directly:
///
/// * fields must be written in ascending field-number order (repeating the
///   same number for repeated fields is allowed); anything else throws;
/// * unknown fields are never carried over;
/// * the caller decides presence: write non-null values, skip nulls.
///
/// Integers are Dart's native 64-bit `int`, so this codec targets native
/// platforms. Web support needs a separate 64-bit integer path.
class WireWriter {
  Uint8List _buffer = Uint8List(64);
  int _length = 0;
  int _lastField = 0;

  /// Number of bytes written so far.
  int get length => _length;

  /// Writes a signed 64-bit integer as a plain varint (protobuf `int64`).
  ///
  /// Negative values always take 10 bytes; prefer [writeSint64] for fields
  /// that are often negative, such as money amounts.
  void writeInt64(int field, int value) {
    _tag(field, WireType.varint);
    _varint(value);
  }

  /// Writes a zigzag-encoded signed 64-bit integer (protobuf `sint64`).
  void writeSint64(int field, int value) {
    _tag(field, WireType.varint);
    _varint((value << 1) ^ (value >> 63));
  }

  /// Writes a boolean as a varint `0` or `1`.
  void writeBool(int field, bool value) {
    _tag(field, WireType.varint);
    _varint(value ? 1 : 0);
  }

  /// Writes a little-endian IEEE 754 double (protobuf `double`).
  void writeDouble(int field, double value) {
    _tag(field, WireType.i64);
    _ensure(8);
    ByteData.sublistView(
      _buffer,
      _length,
      _length + 8,
    ).setFloat64(0, value, Endian.little);
    _length += 8;
  }

  /// Writes a UTF-8 string.
  void writeString(int field, String value) =>
      writeBytes(field, utf8.encode(value));

  /// Writes length-delimited raw bytes.
  void writeBytes(int field, List<int> value) {
    _tag(field, WireType.len);
    _varint(value.length);
    _ensure(value.length);
    _buffer.setRange(_length, _length + value.length, value);
    _length += value.length;
  }

  /// Writes a nested message built by [build] into its own canonical writer.
  void writeMessage(int field, void Function(WireWriter writer) build) {
    final nested = WireWriter();
    build(nested);
    writeBytes(field, nested.toBytes());
  }

  /// A copy of the bytes written so far.
  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _length));

  void _tag(int field, WireType type) {
    if (field < 1 || field > maxFieldNumber) {
      throw RangeError.range(field, 1, maxFieldNumber, 'field');
    }
    if (field < _lastField) {
      throw StateError(
        'Canonical encoding writes fields in ascending order: '
        'got field $field after field $_lastField',
      );
    }
    _lastField = field;
    _varint((field << 3) | type.id);
  }

  /// Writes one field whose value is already encoded: the exact [raw] bytes
  /// (without the length prefix of `len` values) under a fresh tag.
  void _writeRaw(int field, WireType type, List<int> raw) {
    _tag(field, type);
    if (type == WireType.len) {
      _varint(raw.length);
    }
    _ensure(raw.length);
    _buffer.setRange(_length, _length + raw.length, raw);
    _length += raw.length;
  }

  void _varint(int value) {
    var v = value;
    _ensure(10);
    while ((v & ~0x7F) != 0) {
      _buffer[_length++] = (v & 0x7F) | 0x80;
      v = v >>> 7;
    }
    _buffer[_length++] = v;
  }

  void _ensure(int extra) {
    final needed = _length + extra;
    if (needed <= _buffer.length) return;
    var size = _buffer.length * 2;
    while (size < needed) {
      size *= 2;
    }
    final grown = Uint8List(size)..setRange(0, _length, _buffer);
    _buffer = grown;
  }
}

/// Reads the protobuf binary wire format.
///
/// Typical decode loop:
///
/// ```dart
/// while (!reader.isAtEnd) {
///   final tag = reader.readTag();
///   switch (tag.field) {
///     case 1: name = reader.readString();
///     default: reader.skip(tag.type);
///   }
/// }
/// ```
class WireReader {
  WireReader(this._bytes);

  final Uint8List _bytes;
  int _position = 0;

  /// Whether every byte has been consumed.
  bool get isAtEnd => _position >= _bytes.length;

  /// Reads the next field tag.
  ({int field, WireType type}) readTag() {
    final tag = _varint();
    final field = tag >>> 3;
    if (field < 1 || field > maxFieldNumber) {
      throw FormatException('Invalid field number $field');
    }
    return (field: field, type: WireType.fromId(tag & 0x7));
  }

  /// Reads a protobuf `int64` varint.
  int readInt64() => _varint();

  /// Reads a zigzag-encoded protobuf `sint64`.
  int readSint64() {
    final n = _varint();
    return (n >>> 1) ^ -(n & 1);
  }

  /// Reads a varint boolean.
  bool readBool() => _varint() != 0;

  /// Reads a little-endian double.
  double readDouble() {
    _need(8);
    final value = ByteData.sublistView(
      _bytes,
      _position,
      _position + 8,
    ).getFloat64(0, Endian.little);
    _position += 8;
    return value;
  }

  /// Reads length-delimited bytes as a view into the source buffer.
  Uint8List readBytes() {
    final length = _varint();
    if (length < 0) throw FormatException('Negative length $length');
    _need(length);
    final value = Uint8List.sublistView(_bytes, _position, _position + length);
    _position += length;
    return value;
  }

  /// Reads a UTF-8 string.
  String readString() => utf8.decode(readBytes());

  /// Reads a nested message and returns a reader over it.
  WireReader readMessage() => WireReader(readBytes());

  /// Skips a field value of [type], used for numbers this model doesn't know.
  void skip(WireType type) {
    switch (type) {
      case WireType.varint:
        _varint();
      case WireType.i64:
        _need(8);
        _position += 8;
      case WireType.len:
        readBytes();
      case WireType.i32:
        _need(4);
        _position += 4;
    }
  }

  /// Returns the raw, undecoded bytes of one value of [type], positioned
  /// right after the tag: the exact bytes a schema migration re-serializes
  /// for fields it leaves untouched.
  Uint8List _readRawValue(WireType type) => switch (type) {
    WireType.varint => () {
      final start = _position;
      while (true) {
        _need(1);
        if ((_bytes[_position++] & 0x80) == 0) {
          break;
        }
      }
      return Uint8List.sublistView(_bytes, start, _position);
    }(),
    WireType.i64 => _fixedRaw(8),
    WireType.len => readBytes(),
    WireType.i32 => _fixedRaw(4),
  };

  Uint8List _fixedRaw(int count) {
    _need(count);
    final value = Uint8List.sublistView(_bytes, _position, _position + count);
    _position += count;
    return value;
  }

  int _varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      _need(1);
      final byte = _bytes[_position++];
      if (shift == 63 && (byte & 0x7E) != 0) {
        throw const FormatException('Varint overflows 64 bits');
      }
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('Varint is too long');
    }
  }

  void _need(int count) {
    if (_position + count > _bytes.length) {
      throw FormatException(
        'Unexpected end of data: need $count bytes at offset $_position, '
        'have ${_bytes.length - _position}',
      );
    }
  }
}

/// Rewrites one canonical document for a schema migration: field [from]'s
/// value moves to field [to], transformed by [convert].
///
/// Reads the last occurrence of field [from] (a singular field occurs at
/// most once), decodes it as [fromWire], hands the value to [convert],
/// removes every [from] occurrence and writes the converted value at [to]
/// encoded as [toWire]. Every other field is re-serialized byte-for-byte, in
/// the same canonical ascending order, and the result is a new list — [doc]
/// itself is never modified.
///
/// When field [from] is absent the document is returned unchanged — the
/// same instance, with [convert] not called and field [to] not written. A
/// `null` result of [convert] drops the value instead of writing it.
///
/// Throws a [TypeError] when a converted value does not fit [toWire] (for
/// example a [String] for [MigrationWireType.int64]).
Uint8List rewriteField(
  Uint8List doc, {
  required int from,
  required MigrationWireType fromWire,
  required int to,
  required MigrationWireType toWire,
  required Object? Function(Object? value) convert,
}) {
  final reader = WireReader(doc);
  final kept = <(int, WireType, Uint8List)>[];
  Uint8List? oldRaw;
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    final raw = reader._readRawValue(tag.type);
    if (tag.field == from) {
      oldRaw = raw;
    } else {
      kept.add((tag.field, tag.type, raw));
    }
  }
  if (oldRaw == null) {
    return doc;
  }
  final converted = convert(_decodeWireValue(oldRaw, fromWire));

  final writer = WireWriter();
  var inserted = converted == null;
  for (final (field, type, raw) in kept) {
    if (!inserted && field >= to) {
      _writeWireValue(writer, to, toWire, converted!);
      inserted = true;
    }
    writer._writeRaw(field, type, raw);
  }
  if (!inserted) {
    _writeWireValue(writer, to, toWire, converted!);
  }
  return writer.toBytes();
}

/// Decodes one raw wire value as [kind].
///
/// The raw bytes of a `len` value are its payload (the length prefix was
/// consumed when the document was parsed), so text and bytes decode
/// directly; varint and fixed values decode from their exact bytes.
Object? _decodeWireValue(Uint8List raw, MigrationWireType kind) {
  return switch (kind) {
    MigrationWireType.int64 => WireReader(raw).readInt64(),
    MigrationWireType.sint64 => WireReader(raw).readSint64(),
    MigrationWireType.boolean => WireReader(raw).readBool(),
    MigrationWireType.float64 => WireReader(raw).readDouble(),
    MigrationWireType.text => utf8.decode(raw),
    // Copy: the view points into the source document, and the conversion
    // may outlive it.
    MigrationWireType.bytes => Uint8List.fromList(raw),
  };
}

/// Encodes [value] at [field] as [kind].
void _writeWireValue(
  WireWriter writer,
  int field,
  MigrationWireType kind,
  Object? value,
) {
  switch (kind) {
    case MigrationWireType.int64:
      writer.writeInt64(field, value! as int);
    case MigrationWireType.sint64:
      writer.writeSint64(field, value! as int);
    case MigrationWireType.boolean:
      writer.writeBool(field, value! as bool);
    case MigrationWireType.float64:
      writer.writeDouble(field, value! as double);
    case MigrationWireType.text:
      writer.writeString(field, value! as String);
    case MigrationWireType.bytes:
      writer.writeBytes(field, value! as List<int>);
  }
}
