import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

void main() {
  final fp = queryFingerprint('txns|accountId=a1|-bookedOn,-id');

  test('fingerprint is stable, 16 hex chars, and query-sensitive', () {
    expect(fp, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(queryFingerprint('txns|accountId=a1|-bookedOn,-id'), fp);
    expect(queryFingerprint('txns|accountId=a2|-bookedOn,-id'), isNot(fp));
    // FNV-1a 64 reference value for the empty string.
    expect(queryFingerprint(''), 'cbf29ce484222325');
  });

  test('round-trips keys and is url-safe', () {
    final cursor = CursorCodec.encode(fp, [20261107, 2.5, 'tx_01JC', true]);
    expect(cursor, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(CursorCodec.decode(cursor, expectedFingerprint: fp), [
      20261107,
      2.5,
      'tx_01JC',
      true,
    ]);
  });

  test('rejects cursors from another query', () {
    final cursor = CursorCodec.encode(fp, [1, 'a']);
    expect(
      () => CursorCodec.decode(
        cursor,
        expectedFingerprint: queryFingerprint('other'),
      ),
      throwsA(isA<CursorMismatchException>()),
    );
  });

  test('rejects garbage and unsupported values', () {
    expect(
      () => CursorCodec.decode('not a cursor!', expectedFingerprint: fp),
      throwsA(isA<InvalidCursorException>()),
    );
    expect(() => CursorCodec.encode(fp, [double.nan]), throwsArgumentError);
    expect(() => CursorCodec.encode(fp, [DateTime(2026)]), throwsArgumentError);
  });
}
