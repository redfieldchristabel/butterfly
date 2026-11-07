import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

void main() {
  group('CollectionPattern', () {
    test('parses a nested pattern', () {
      final p = CollectionPattern.parse('accounts/{accountId}/txns');
      expect(p.collectionIds, ['accounts', 'txns']);
      expect(p.params, ['accountId']);
      expect(p.collectionId, 'txns');
      expect(p.isTopLevel, isFalse);
      expect(p.parent, CollectionPattern.parse('accounts'));
      expect(CollectionPattern.parse('accounts').parent, isNull);
    });

    test('rejects malformed patterns', () {
      for (final bad in [
        '',
        'accounts/{accountId}',
        'Accounts',
        'accounts/a1/txns',
        'accounts/{id}/txns/{id}/notes',
        'accounts//txns',
      ]) {
        expect(
          () => CollectionPattern.parse(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('resolves params into a concrete path', () {
      final path = CollectionPattern.parse(
        'accounts/{accountId}/txns',
      ).resolve({'accountId': 'a1'});
      expect(path.path, 'accounts/a1/txns');
      expect(path.collectionId, 'txns');
      expect(path.doc('t9').path, 'accounts/a1/txns/t9');
    });

    test('resolve rejects missing, unknown and invalid params', () {
      final p = CollectionPattern.parse('accounts/{accountId}/txns');
      expect(() => p.resolve({}), throwsArgumentError);
      expect(
        () => p.resolve({'accountId': 'a1', 'x': 'y'}),
        throwsArgumentError,
      );
      expect(() => p.resolve({'accountId': 'a/1'}), throwsArgumentError);
    });
  });

  group('DocPath', () {
    final account = CollectionPattern.parse('accounts').resolve({}).doc('a1');

    test('builds subcollections', () {
      expect(
        account.subcollection('txns').doc('t1').path,
        'accounts/a1/txns/t1',
      );
      expect(() => account.subcollection('Txns'), throwsArgumentError);
    });

    test('descendant range covers the subtree and nothing else', () {
      final range = account.descendants;
      bool inRange(String p) =>
          p.compareTo(range.from) >= 0 && p.compareTo(range.to) < 0;
      expect(inRange('accounts/a1/txns/t1'), isTrue);
      expect(inRange('accounts/a1/txns/t1/splits/s1'), isTrue);
      expect(inRange('accounts/a1'), isFalse);
      expect(inRange('accounts/a10/txns/t1'), isFalse);
      expect(inRange('accounts/a1-x/txns/t1'), isFalse);
    });

    test('rejects bad ids', () {
      final accounts = CollectionPattern.parse('accounts').resolve({});
      for (final bad in ['', '.', '..', 'a/b', 'x' * (maxDocIdLength + 1)]) {
        expect(() => accounts.doc(bad), throwsArgumentError, reason: bad);
      }
    });
  });
}
