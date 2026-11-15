/// The internal `_cocoon_prefs` store behind `db.prefs` and `db.single`:
/// device-local primitives (and the one row behind every single-model key)
/// in protobuf wire format, pinned per row by an INTEGER kind.
///
/// This file owns the codec and the DML. The facade objects
/// (`CocoonPrefs`, `Single`, the transaction and batch views) live in
/// `prefs.dart`; the SQLite statement lives here or in `schema_sql.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../wire.dart';
import 'executor.dart';
import 'naming.dart';

/// Thrown when a pref key is read as the wrong kind: the stored row holds
/// one kind (a primitive, or a single-model row written by another adapter)
/// and the requested read expects another. Cocoon never returns garbage for
/// a wrong-kind read.
///
/// ```dart
/// await db.prefs.setString('theme', 'dark');
/// await db.prefs.getInt('theme'); // throws PrefsTypeException
/// ```
final class PrefsTypeException implements Exception {
  /// Builds the exception for a key whose stored kind cannot serve the
  /// requested read.
  PrefsTypeException({
    required this.key,
    required this.storedKind,
    required this.requestedKind,
  });

  /// The pref key that was read.
  final String key;

  /// Description of the kind the row actually holds.
  final String storedKind;

  /// Description of the kind the read expected.
  final String requestedKind;

  @override
  String toString() =>
      'PrefsTypeException: key "$key" holds $storedKind but was read as '
      '$requestedKind';
}

/// One raw pref row: the INTEGER kind and the wire value.
///
/// A record, so raw rows cross isolate boundaries without conversion in
/// every isolate mode.
@internal
typedef PrefRow = ({int kind, Uint8List bytes});

/// One committed pref mutation crossing an isolate boundary or waiting for
/// a transaction's commit: [key] with its new [row], or a null [row] for a
/// removal.
@internal
typedef PrefWriteOp = ({String key, PrefRow? row});

/// Primitive kinds pinned per row. Small constants, biased away from the
/// biased FNV-1a values [prefsModelKind] produces for single-model keys.
const int prefsKindString = 1;
const int prefsKindInt = 2;
const int prefsKindBool = 3;
const int prefsKindDouble = 4;
const int prefsKindBytes = 5;

/// Bias for single-model keys ([prefsModelKind]): every model kind is at
/// least 2^62, so no model kind can ever equal a primitive constant and
/// primitive constants can never read a model row.
const int _prefsKindModelBias = 0x4000000000000000;

/// Mask for the FNV-1a part of a single-model kind.
const int _prefsKindModelMask = 0x0000FFFFFFFFFFFF;

/// Description of an INTEGER kind for error messages. Single-model kinds
/// are hashed, so they are described by their fingerprint, never by a name
/// Cocoon cannot know.
String prefsKindName(int kind) => switch (kind) {
  prefsKindString => 'string',
  prefsKindInt => 'int',
  prefsKindBool => 'bool',
  prefsKindDouble => 'double',
  prefsKindBytes => 'bytes',
  _ =>
    'a single model row (type fingerprint '
        '0x${(kind - _prefsKindModelBias).toRadixString(16)})',
};

/// The INTEGER `kind` value behind a single-model key: a biased FNV-1a
/// fingerprint of the adapter's table identity.
///
/// Two `single` handles for the same key but different adapters detect the
/// mismatch through this hash: the row was written by whichever adapter's
/// identity produced the stored kind. Collisions between two distinct
/// identities sharing one key are possible (FNV-1a is not cryptographic)
/// but measure ~2^-48 per pair; the price of keeping the row
/// self-contained (`key`, `kind`, `value` only — the adapter's exact
/// `encode` bytes ride unmodified in `value`, so model evolution behaves
/// exactly like a collection document).
@internal
int prefsModelKind(String identity) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode('cocoon-single:$identity')) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return _prefsKindModelBias + (hash & _prefsKindModelMask);
}

/// Validates a pref key: non-empty, at most 256 UTF-8 bytes. Values have no
/// limit beyond SQLite itself — prefs are documented for small values.
@internal
void checkPrefKey(String key) {
  if (key.isEmpty) {
    throw ArgumentError.value(key, 'key', 'Pref keys must not be empty');
  }
  if (utf8.encode(key).length > 256) {
    throw ArgumentError.value(
      key,
      'key',
      'Pref keys are at most 256 UTF-8 bytes, '
          'got ${utf8.encode(key).length}',
    );
  }
}

// -- Wire codec: one one-field document per pref value -----------------------

Uint8List _encodePrefValue(void Function(WireWriter writer) build) {
  final writer = WireWriter();
  build(writer);
  return writer.toBytes();
}

/// Encodes a string pref (wire: UTF-8 text).
@internal
Uint8List encodePrefString(String value) =>
    _encodePrefValue((writer) => writer.writeString(1, value));

/// Encodes an int pref (wire: zigzag `sint64`, like money amounts).
@internal
Uint8List encodePrefInt(int value) =>
    _encodePrefValue((writer) => writer.writeSint64(1, value));

/// Encodes a bool pref (wire: varint `0`/`1`).
@internal
Uint8List encodePrefBool(bool value) =>
    _encodePrefValue((writer) => writer.writeBool(1, value));

/// Encodes a double pref (wire: little-endian IEEE 754 `double`).
@internal
Uint8List encodePrefDouble(double value) =>
    _encodePrefValue((writer) => writer.writeDouble(1, value));

/// Encodes a bytes pref (wire: length-delimited raw bytes).
@internal
Uint8List encodePrefBytes(Uint8List value) =>
    _encodePrefValue((writer) => writer.writeBytes(1, value));

/// The one field tag of a pref value's document.
({int field, WireType type}) _prefTag(WireReader reader) {
  final tag = reader.readTag();
  if (tag.field != 1) {
    throw const FormatException('A pref value is a one-field document');
  }
  return tag;
}

/// Decodes a string pref.
@internal
String decodePrefString(Uint8List bytes) {
  final reader = WireReader(bytes);
  final tag = _prefTag(reader);
  if (tag.type != WireType.len) {
    throw const FormatException('A string pref value is length-delimited');
  }
  return reader.readString();
}

/// Decodes an int pref.
@internal
int decodePrefInt(Uint8List bytes) {
  final reader = WireReader(bytes);
  final tag = _prefTag(reader);
  if (tag.type != WireType.varint) {
    throw const FormatException('An int pref value is a varint');
  }
  return reader.readSint64();
}

/// Decodes a bool pref.
@internal
bool decodePrefBool(Uint8List bytes) {
  final reader = WireReader(bytes);
  final tag = _prefTag(reader);
  if (tag.type != WireType.varint) {
    throw const FormatException('A bool pref value is a varint');
  }
  return reader.readBool();
}

/// Decodes a double pref.
@internal
double decodePrefDouble(Uint8List bytes) {
  final reader = WireReader(bytes);
  final tag = _prefTag(reader);
  if (tag.type != WireType.i64) {
    throw const FormatException('A double pref value is a 64-bit double');
  }
  return reader.readDouble();
}

/// Decodes a bytes pref.
@internal
Uint8List decodePrefBytes(Uint8List bytes) {
  final reader = WireReader(bytes);
  final tag = _prefTag(reader);
  if (tag.type != WireType.len) {
    throw const FormatException('A bytes pref value is length-delimited');
  }
  return Uint8List.fromList(reader.readBytes());
}

// -- DML ---------------------------------------------------------------------

/// The point-lookup statement behind every raw pref read.
@internal
const String prefGetSql =
    'SELECT kind, value FROM $prefsTableName WHERE key = ?';

/// The upsert statement behind every raw pref write.
@internal
const String prefUpsertSql =
    'INSERT INTO $prefsTableName (key, kind, value) VALUES (?, ?, ?) '
    'ON CONFLICT(key) DO UPDATE SET kind = excluded.kind, '
    'value = excluded.value';

/// The delete statement behind `db.prefs.clear()`: returns the keys that
/// actually existed, so watches on absent keys never emit.
@internal
const String prefClearSql = 'DELETE FROM $prefsTableName RETURNING key';

/// The bulk read behind `db.prefs.preload()` and `preloadPrefs: true`.
@internal
const String prefLoadAllSql = 'SELECT key, kind, value FROM $prefsTableName';

/// Reads one raw pref row through [reader], or `null` when absent.
@internal
Future<PrefRow?> readPref(CocoonRead reader, String key) async {
  final row = await reader.getOptional(prefGetSql, [key]);
  if (row == null) {
    return null;
  }
  return (kind: row['kind']! as int, bytes: row['value']! as Uint8List);
}

/// Upserts one raw pref row through [tx].
@internal
Future<void> writePref(CocoonTx tx, String key, PrefRow row) =>
    tx.execute(prefUpsertSql, [key, row.kind, row.bytes]);

/// Deletes one raw pref row through [tx], returning whether a row existed
/// (watches on absent keys never emit). One round trip via RETURNING.
@internal
Future<bool> deletePref(CocoonTx tx, String key) async {
  final rows = await tx.getAll(
    'DELETE FROM $prefsTableName WHERE key = ? RETURNING key',
    [key],
  );
  return rows.isNotEmpty;
}

/// Deletes every raw pref row through [tx], returning the keys that existed
/// (so watches on absent keys never emit).
@internal
Future<List<String>> clearPrefs(CocoonTx tx) async {
  final rows = await tx.getAll(prefClearSql);
  return [for (final row in rows) row['key']! as String];
}

/// Reads every raw pref row through [reader] (the preload bulk read).
@internal
Future<Map<String, PrefRow>> readAllPrefs(CocoonRead reader) async {
  final rows = await reader.getAll(prefLoadAllSql);
  return {
    for (final row in rows)
      row['key']! as String: (
        kind: row['kind']! as int,
        bytes: row['value']! as Uint8List,
      ),
  };
}
