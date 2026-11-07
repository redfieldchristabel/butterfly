import 'dart:convert';

/// Thrown when a cursor string is malformed or from an unsupported version.
class InvalidCursorException implements Exception {
  const InvalidCursorException(this.message);

  final String message;

  @override
  String toString() => 'InvalidCursorException: $message';
}

/// Thrown when a cursor is used with a different query than the one that
/// produced it.
class CursorMismatchException implements Exception {
  const CursorMismatchException({required this.expected, required this.actual});

  final String expected;
  final String actual;

  @override
  String toString() =>
      'CursorMismatchException: cursor belongs to query $actual, not $expected';
}

/// A short, stable fingerprint of a query's canonical description
/// (collection, filters, order), stored in cursors so a cursor from one query
/// can't silently page another.
///
/// FNV-1a 64-bit over the UTF-8 bytes, as 16 hex characters. Not a security
/// measure: cursors never leave the device.
String queryFingerprint(String canonicalQuery) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(canonicalQuery)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  final high = (hash >>> 32).toRadixString(16).padLeft(8, '0');
  final low = (hash & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '$high$low';
}

/// Encodes and decodes opaque keyset-pagination cursors.
///
/// A cursor carries the sort-key values of the last row of a page (the
/// document id last, as the tiebreaker) plus the fingerprint of the query.
/// The next page is `WHERE (k1, ..., id) > (?, ..., ?)` in the index order.
///
/// Sort keys are never null by design, so only `int`, `double`, `String` and
/// `bool` values are accepted.
abstract final class CursorCodec {
  /// The cursor format version.
  static const version = 1;

  /// Encodes [values] for the query identified by [fingerprint].
  static String encode(String fingerprint, List<Object> values) {
    for (final value in values) {
      final ok = switch (value) {
        int() || String() || bool() => true,
        double() => value.isFinite,
        _ => false,
      };
      if (!ok) {
        throw ArgumentError.value(
          value,
          'values',
          'Cursor values must be int, finite double, String or bool',
        );
      }
    }
    final json = jsonEncode({'v': version, 'q': fingerprint, 'k': values});
    return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  }

  /// Decodes [cursor], checking it was produced by [expectedFingerprint].
  static List<Object> decode(
    String cursor, {
    required String expectedFingerprint,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
      );
    } on FormatException {
      throw const InvalidCursorException('Cursor is not valid base64url JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const InvalidCursorException('Cursor payload is not an object');
    }
    final v = decoded['v'];
    if (v != version) {
      throw InvalidCursorException('Unsupported cursor version $v');
    }
    final q = decoded['q'];
    final k = decoded['k'];
    if (q is! String || k is! List<Object?>) {
      throw const InvalidCursorException('Cursor payload is incomplete');
    }
    if (q != expectedFingerprint) {
      throw CursorMismatchException(expected: expectedFingerprint, actual: q);
    }
    if (k.any((e) => e == null)) {
      throw const InvalidCursorException('Cursor contains a null sort key');
    }
    return List<Object>.unmodifiable(k.cast<Object>());
  }
}
