/// Generates document ids.
///
/// [newDocId] produces time-ordered UUIDv7 ids: 48-bit Unix millisecond
/// timestamp, version 7, a 12-bit sequence counter and 62 random bits,
/// lowercase and hyphenated (`018f6a2c-9b7e-7abc-8def-0123456789ab`).
///
/// Ids generated in the same millisecond increase monotonically: the counter
/// starts at a random value and is bumped on every call; when it overflows
/// (more than 4096 ids in one millisecond) the generator waits for the next
/// millisecond. A system clock that jumps backwards is clamped to the last
/// timestamp, so ordering never regresses.
library;

import 'dart:math';

final Random _random = Random.secure();

int _lastMs = 0;
int _counter = 0;

/// A fresh, time-ordered document id.
String newDocId() {
  var ms = DateTime.now().millisecondsSinceEpoch;
  if (ms <= _lastMs) {
    // Same millisecond (or the clock went backwards): keep the last
    // timestamp and bump the sequence counter so ids stay ordered.
    ms = _lastMs;
    _counter++;
    if (_counter > 0xFFF) {
      // 4096 ids in one millisecond; wait for the clock to move on.
      do {
        ms = DateTime.now().millisecondsSinceEpoch;
      } while (ms <= _lastMs);
      _lastMs = ms;
      _counter = _random.nextInt(0x1000);
    }
  } else {
    _lastMs = ms;
    _counter = _random.nextInt(0x1000);
  }

  final buffer = StringBuffer();
  final timestamp = ms & 0xFFFFFFFFFFFF; // 48 bits
  buffer.write(timestamp.toRadixString(16).padLeft(12, '0'));
  buffer.write('7'); // version
  buffer.write(_counter.toRadixString(16).padLeft(3, '0'));
  final randomHigh = _random.nextInt(1 << 30); // 30 bits
  final randomLow = _random.nextInt(1 << 32); // 32 bits
  final random62 = (randomHigh << 32) | randomLow;
  // Variant `10` in the top two bits, then the remaining 62 random bits.
  final variantNibble = 0x8 | (random62 >>> 60);
  final rest = random62 & 0x0FFFFFFFFFFFFFFF; // 60 bits
  buffer.write(variantNibble.toRadixString(16));
  buffer.write(rest.toRadixString(16).padLeft(15, '0'));
  final hex = buffer.toString();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
