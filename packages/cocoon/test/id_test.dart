import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

void main() {
  test('ids are lowercase hyphenated UUIDv7', () {
    final id = newDocId();
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });

  test('ids are time-ordered: strictly increasing within and across '
      'milliseconds (including counter overflow)', () {
    // Enough ids to cross a millisecond boundary and exhaust the 12-bit
    // counter at least once.
    const count = 9000;
    var previous = newDocId();
    for (var i = 0; i < count; i++) {
      final id = newDocId();
      expect(id.compareTo(previous), greaterThan(0), reason: 'at #$i: $id');
      previous = id;
    }
  });

  test('ids embed the current time roughly where the spec puts it', () {
    final before = DateTime.now().millisecondsSinceEpoch;
    final id = newDocId();
    final after = DateTime.now().millisecondsSinceEpoch;
    final hex = id.replaceAll('-', '').substring(0, 12);
    final ms = int.parse(hex, radix: 16);
    expect(ms, inInclusiveRange(before, after));
  });
}
