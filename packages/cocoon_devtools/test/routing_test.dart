import 'package:cocoon_devtools/src/routing.dart';
import 'package:flutter_test/flutter_test.dart';

/// The inspector's multi-isolate routing: composite ids survive splitting,
/// every isolate's database list merges under unique ids, and answers
/// without the inspector's shape are skipped.
void main() {
  test('splitDatabaseId splits on the last slash', () {
    final route = splitDatabaseId('isolates/12345/2');
    expect(route, isNotNull);
    expect(route!.$1, 'isolates/12345');
    expect(route.$2, '2');
  });

  test('splitDatabaseId rejects bare ids', () {
    expect(splitDatabaseId('7'), isNull);
    expect(splitDatabaseId('/leading'), isNull);
  });

  test('mergeDatabaseLists makes ids unique and builds routes', () {
    final merged = mergeDatabaseLists([
      (
        isolateId: 'isolates/111',
        json: {
          'databases': [
            {
              'id': '1',
              'path': '/tmp/app.db',
              'open': true,
              'collectionCount': 2,
            },
          ],
        },
      ),
      (
        isolateId: 'isolates/222',
        json: {
          'databases': [
            {
              'id': '1',
              'path': '/tmp/bg.db',
              'open': true,
              'collectionCount': 2,
            },
          ],
        },
      ),
    ]);
    final databases = merged.json['databases']! as List<Object?>;
    expect(databases, hasLength(2));
    final first = databases[0]! as Map<String, Object?>;
    final second = databases[1]! as Map<String, Object?>;
    expect(first['id'], 'isolates/111/1');
    expect(second['id'], 'isolates/222/1');
    expect(merged.routes['isolates/111/1'], ('isolates/111', '1'));
    expect(merged.routes['isolates/222/1'], ('isolates/222', '1'));
  });

  test('mergeDatabaseLists skips malformed answers', () {
    final merged = mergeDatabaseLists([
      (isolateId: 'isolates/1', json: {'error': 'not registered'}),
      (isolateId: 'isolates/2', json: <String, Object?>{}),
      (
        isolateId: 'isolates/3',
        json: {
          'databases': [
            'garbage',
            {'id': 3},
            {'id': '3', 'open': true},
          ],
        },
      ),
    ]);
    final databases = merged.json['databases']! as List<Object?>;
    expect(databases, hasLength(1));
    expect((databases.single! as Map<String, Object?>)['id'], 'isolates/3/3');
    expect(merged.routes, hasLength(1));
  });
}
