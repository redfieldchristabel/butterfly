import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

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

  /// A map field: one nested message per entry, key at field 1 and value at
  /// field 2. Decoding and encoding an entry needs the key/value encodings
  /// themselves, so a [MapWireType] rides alongside every [map] value in
  /// [rewriteField] and [FieldMigration].
  map,
}

/// The wire encodings of a map field's keys and values.
///
/// Required by [MigrationWireType.map]: the map field itself is a sequence of
/// entry messages, and only this class says how each entry's key (field 1)
/// and value (field 2) are encoded. Keys are text ([MigrationWireType.text],
/// `String` keys) or zigzag varints ([MigrationWireType.sint64], `int` keys);
/// values use the encoding of the value type, so nested lists and embedded
/// classes are [MigrationWireType.bytes].
@immutable
final class MapWireType {
  /// Builds the key/value encoding pair of one map field.
  const MapWireType({required this.key, required this.value});

  /// The encoding of every entry's key (field 1).
  final MigrationWireType key;

  /// The encoding of every entry's value (field 2).
  final MigrationWireType value;

  @override
  bool operator ==(Object other) =>
      other is MapWireType && other.key == key && other.value == value;

  @override
  int get hashCode => Object.hash(key, value);

  @override
  String toString() => 'MapWireType(key: $key, value: $value)';
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
  /// Starts an empty canonical document buffer.
  WireWriter();

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
  /// Reads the canonical wire document from the start of the given bytes.
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
/// Map fields ([fromWire] or [toWire] is [MigrationWireType.map]) are
/// repeated: every occurrence of field [from] is one entry, decoded with the
/// key/value encodings of [fromMap] into a `Map<Object?, Object?>` that
/// [convert] receives (duplicate keys: the last occurrence wins). The map
/// [convert] returns is written back sorted by key, one entry message per
/// entry with the key at field 1 and the value at field 2, encoded per
/// [toMap]. An empty returned map writes nothing, exactly like encoding an
/// empty map. A `Map<Object?, Object?>` from [convert] is fine to hand back
/// as any `Map<K, V>`; Dart's covariant generics accept it.
///
/// When field [from] is absent the document is returned unchanged — the
/// same instance, with [convert] not called and field [to] not written. A
/// `null` result of [convert] drops the value instead of writing it.
///
/// [fromMap] is required exactly when [fromWire] is [MigrationWireType.map],
/// and [toMap] exactly when [toWire] is. Throws an [ArgumentError] when that
/// is violated and a [TypeError] when a converted value does not fit
/// [toWire] (for example a [String] for [MigrationWireType.int64]).
Uint8List rewriteField(
  Uint8List doc, {
  required int from,
  required MigrationWireType fromWire,
  required int to,
  required MigrationWireType toWire,
  required Object? Function(Object? value) convert,
  MapWireType? fromMap,
  MapWireType? toMap,
}) {
  _requireMapArgs(fromWire, fromMap, 'fromWire', 'fromMap');
  _requireMapArgs(toWire, toMap, 'toWire', 'toMap');
  final reader = WireReader(doc);
  final kept = <(int, WireType, Uint8List)>[];
  // A singular field occurs once; a map field occurs once per entry.
  final oldRaws = <Uint8List>[];
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    final raw = reader._readRawValue(tag.type);
    if (tag.field == from) {
      oldRaws.add(raw);
    } else {
      kept.add((tag.field, tag.type, raw));
    }
  }
  if (oldRaws.isEmpty) {
    return doc;
  }
  final converted = convert(
    fromWire == MigrationWireType.map
        ? _decodeMapValue(oldRaws, fromMap!)
        : _decodeWireValue(oldRaws.last, fromWire),
  );

  final writer = WireWriter();
  var inserted = converted == null;
  for (final (field, type, raw) in kept) {
    if (!inserted && field >= to) {
      _writeWireValue(writer, to, toWire, converted!, toMap);
      inserted = true;
    }
    writer._writeRaw(field, type, raw);
  }
  if (!inserted) {
    _writeWireValue(writer, to, toWire, converted!, toMap);
  }
  return writer.toBytes();
}

/// Writes one field value into a canonical document: every occurrence of
/// field [field] is removed and [value], encoded as [wire], is inserted at
/// the field's canonical ascending position. Every other field is
/// re-serialized byte-for-byte and the result is a new list — [doc] itself
/// is never modified.
///
/// This is the write side of a backfill migration ([BackfillMigration]):
/// unlike [rewriteField], the field does not need to exist — an absent field
/// is simply added, which is how documents written before the field existed
/// gain their value.
///
/// [map] is required exactly when [wire] is [MigrationWireType.map]. Throws
/// an [ArgumentError] when [value] is null: a backfill always writes a
/// value (dropping one is [rewriteField]'s job) — the field is non-nullable
/// by construction.
Uint8List writeField(
  Uint8List doc, {
  required int field,
  required MigrationWireType wire,
  required Object? value,
  MapWireType? map,
}) {
  _requireMapArgs(wire, map, 'wire', 'map');
  if (value == null) {
    throw ArgumentError.value(
      value,
      'value',
      'Must not be null: writeField writes a value (rewriteField drops one)',
    );
  }
  final reader = WireReader(doc);
  final kept = <(int, WireType, Uint8List)>[];
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    final raw = reader._readRawValue(tag.type);
    if (tag.field != field) {
      kept.add((tag.field, tag.type, raw));
    }
  }
  final writer = WireWriter();
  var inserted = false;
  for (final (number, type, raw) in kept) {
    if (!inserted && number >= field) {
      _writeWireValue(writer, field, wire, value, map);
      inserted = true;
    }
    writer._writeRaw(number, type, raw);
  }
  if (!inserted) {
    _writeWireValue(writer, field, wire, value, map);
  }
  return writer.toBytes();
}

/// Validates the [MigrationWireType.map] / [MapWireType] pairing of a
/// [rewriteField] side.
void _requireMapArgs(
  MigrationWireType wire,
  MapWireType? map,
  String wireName,
  String mapName,
) {
  if (wire == MigrationWireType.map && map == null) {
    throw ArgumentError(
      '$mapName is required when $wireName is MigrationWireType.map',
    );
  }
  if (wire != MigrationWireType.map && map != null) {
    throw ArgumentError(
      '$mapName is only allowed when $wireName is MigrationWireType.map',
    );
  }
}

/// Decodes a map field's entry messages into a `Map<Object?, Object?>`:
/// each raw value is one entry message, key at field 1 and value at field 2.
/// The last occurrence of a key wins, and an entry missing its key or value
/// decodes that part to the wire's zero value, matching protobuf map
/// semantics.
Map<Object?, Object?> _decodeMapValue(
  List<Uint8List> entries,
  MapWireType wire,
) {
  final map = <Object?, Object?>{};
  for (final raw in entries) {
    final reader = WireReader(raw);
    Object? key;
    Object? value;
    var hasKey = false;
    var hasValue = false;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          key = _decodeWireValue(reader._readRawValue(tag.type), wire.key);
          hasKey = true;
        case 2:
          value = _decodeWireValue(reader._readRawValue(tag.type), wire.value);
          hasValue = true;
        default:
          reader.skip(tag.type);
      }
    }
    map[hasKey ? key : _wireZero(wire.key)] = hasValue
        ? value
        : _wireZero(wire.value);
  }
  return map;
}

/// The zero value of one [MigrationWireType], for map entries that lack
/// their key or value part.
Object _wireZero(MigrationWireType kind) => switch (kind) {
  MigrationWireType.int64 || MigrationWireType.sint64 => 0,
  MigrationWireType.boolean => false,
  MigrationWireType.float64 => 0.0,
  MigrationWireType.text => '',
  MigrationWireType.bytes => Uint8List(0),
  MigrationWireType.map => throw ArgumentError(
    'Nested map values are not supported',
  ),
};

/// Writes [map] at [field] as one entry message per entry, sorted by key
/// (`String.compareTo` / int order), key at field 1 and value at field 2,
/// encoded per [wire] — the canonical form every equal map encodes to.
void _writeMapValue(
  WireWriter writer,
  int field,
  MapWireType wire,
  Map<Object?, Object?> map,
) {
  final keys = map.keys.toList()..sort(_compareMapKeys);
  for (final key in keys) {
    writer.writeMessage(field, (entry) {
      _writeWireValue(entry, 1, wire.key, key, null);
      _writeWireValue(entry, 2, wire.value, map[key], null);
    });
  }
}

/// Sorts map keys: all `String`s by [String.compareTo], all `int`s
/// numerically. Anything else is a broken conversion result.
int _compareMapKeys(Object? a, Object? b) {
  if (a is String && b is String) {
    return a.compareTo(b);
  }
  if (a is int && b is int) {
    return a.compareTo(b);
  }
  throw ArgumentError(
    'Map keys must all be Strings or all be ints, '
    'got ${a.runtimeType} and ${b.runtimeType}',
  );
}

/// Decodes one raw wire value as [kind].
///
/// The raw bytes of a `len` value are its payload (the length prefix was
/// consumed when the document was parsed), so text and bytes decode
/// directly; varint and fixed values decode from their exact bytes. Map
/// fields never decode through here — [rewriteField] handles them with the
/// key/value encodings of their [MapWireType].
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
    MigrationWireType.map => throw StateError(
      'A map value decodes through its MapWireType, not as one raw value',
    ),
  };
}

/// Encodes [value] at [field] as [kind].
void _writeWireValue(
  WireWriter writer,
  int field,
  MigrationWireType kind,
  Object? value,
  MapWireType? map,
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
    case MigrationWireType.map:
      _writeMapValue(writer, field, map!, value! as Map<Object?, Object?>);
  }
}
