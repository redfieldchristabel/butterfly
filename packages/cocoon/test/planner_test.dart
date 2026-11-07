import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/query.dart';
import 'package:cocoon/src/engine/schema_sql.dart';
import 'package:test/test.dart';

import 'support/models.dart';

/// Unit tests for the pure index-checking planner: no database involved.
void main() {
  final registry = SchemaRegistry.build([accounts, txns, splits]);
  final entry = registry.byPattern(txns.pattern)!;

  IndexPlan? serve({
    required Set<String> equalityNames,
    String? rangeName,
    required List<QueryOrder> orders,
  }) => indexServingQuery(
    indexes: entry.indexPlans,
    equalityNames: equalityNames,
    rangeName: rangeName,
    hasUserOrder: orders.isNotEmpty,
    // The planner appends the id tiebreaker with the last key's
    // direction, exactly like planQuery does — unless the caller is
    // already ordering by id (only possible in these unit tests).
    orders: orders.any((order) => order.name == 'id')
        ? orders
        : [
            ...orders,
            QueryOrder(
              'id',
              descending: orders.isEmpty ? false : orders.last.descending,
            ),
          ],
  );

  group('implicit scope index', () {
    test('serves a scoped query with default order', () {
      final index = serve(equalityNames: {'accountId'}, orders: const []);
      expect(index, isNotNull);
      expect(index!.name, 'cx_txn_scope');
    });

    test('serves a scoped query ordered by id', () {
      final index = serve(
        equalityNames: {'accountId'},
        orders: const [QueryOrder('id')],
      );
      expect(index, isNotNull);
    });

    test('rejects a collection-group scan with nothing to anchor on', () {
      expect(serve(equalityNames: const {}, orders: const []), isNull);
    });

    test('rejects an order-by that skips the param', () {
      expect(
        serve(equalityNames: const {}, orders: const [QueryOrder('bookedOn')]),
        isNull,
      );
    });
  });

  group('declared index (accountId, -bookedOn, id)', () {
    test('serves eq param + desc order', () {
      final index = serve(
        equalityNames: {'accountId'},
        orders: const [QueryOrder('bookedOn', descending: true)],
      );
      expect(index, isNotNull);
      expect(index!.name, isNot('cx_txn_scope'));
      expect(index.parts.map((p) => p.name).toList(), [
        'accountId',
        'bookedOn',
        'id',
      ]);
    });

    test('serves the reversed scan (asc order on a desc index)', () {
      final index = serve(
        equalityNames: {'accountId'},
        orders: const [QueryOrder('bookedOn')],
      );
      expect(index, isNotNull);
    });

    test('serves a range on the first order key', () {
      final index = serve(
        equalityNames: {'accountId'},
        rangeName: 'bookedOn',
        orders: const [QueryOrder('bookedOn', descending: true)],
      );
      expect(index, isNotNull);
    });

    test('rejects a range on a later key', () {
      expect(
        serve(
          equalityNames: {'accountId'},
          rangeName: 'bookedOn',
          orders: const [QueryOrder('currency')],
        ),
        isNull,
      );
    });

    test('rejects an equality name missing from the index', () {
      expect(
        serve(
          equalityNames: {'accountId', 'currency'},
          orders: const [QueryOrder('bookedOn', descending: true)],
        ),
        isNull,
      );
    });

    test('rejects a prefix the query does not constrain', () {
      expect(
        serve(
          equalityNames: {'currency'},
          orders: const [QueryOrder('bookedOn', descending: true)],
        ),
        isNull,
      );
    });
  });

  group('declared index (status, bookedOn, id)', () {
    test('serves eq + range on the same index', () {
      final index = serve(
        equalityNames: {'status'},
        rangeName: 'bookedOn',
        orders: const [QueryOrder('bookedOn')],
      );
      expect(index, isNotNull);
    });

    test('serves eq + eq only when both names match the index prefix', () {
      // The (status, bookedOn, id) index needs its second part constrained;
      // eq {status, currency} does not cover it.
      expect(
        serve(equalityNames: {'status', 'currency'}, orders: const []),
        isNull,
      );
      expect(
        serve(equalityNames: {'status', 'bookedOn'}, orders: const []),
        isNotNull,
      );
    });

    test('serves eq + order on the second part', () {
      final index = serve(
        equalityNames: {'status'},
        orders: const [QueryOrder('bookedOn')],
      );
      expect(index, isNotNull);
    });
  });

  group('range without sort keys', () {
    test('takes the index slot after the equality prefix', () {
      final index = serve(
        equalityNames: {'accountId'},
        rangeName: 'bookedOn',
        orders: const [],
      );
      // (accountId, -bookedOn, id): prefix (accountId), range on bookedOn —
      // but the tail must then be [bookedOn, id] positionally, which holds.
      expect(index, isNotNull);
    });

    test('serves a range on a single-field index with no equality', () {
      final index = serve(
        rangeName: 'memo',
        equalityNames: const {},
        orders: const [],
      );
      expect(index, isNotNull);
    });

    test('rejects two range names outright', () {
      expect(
        serve(rangeName: 'bookedOn', equalityNames: {'memo'}, orders: const []),
        isNull,
      );
    });
  });

  test('directions must all match or all reverse', () {
    // Mixed-direction order (bookedOn asc, id desc) is never produced by the
    // builder (id follows the last key), but the checker must still be
    // strict about arbitrary order lists.
    expect(
      indexServingQuery(
        indexes: entry.indexPlans,
        equalityNames: {'accountId'},
        rangeName: null,
        hasUserOrder: true,
        orders: const [
          QueryOrder('bookedOn'),
          QueryOrder('id', descending: true),
        ],
      ),
      isNull,
    );
  });

  group('suggested index declaration', () {
    test('spells the Index([...]) for the canonical txn query', () {
      final suggestion = suggestedIndexDdl(
        equalityNamesInOrder: ['accountId'],
        rangeName: null,
        hasUserOrder: true,
        orders: const [QueryOrder('bookedOn', descending: true)],
      );
      expect(suggestion, "Index(['accountId', '-bookedOn'])");
    });

    test('includes a range slot when there are no sort keys', () {
      final suggestion = suggestedIndexDdl(
        equalityNamesInOrder: const [],
        rangeName: 'bookedOn',
        hasUserOrder: false,
        orders: const [],
      );
      expect(suggestion, "Index(['bookedOn'])");
    });

    test('is null for a query with nothing to index', () {
      expect(
        suggestedIndexDdl(
          equalityNamesInOrder: const [],
          rangeName: null,
          hasUserOrder: false,
          orders: const [],
        ),
        isNull,
      );
    });
  });

  group('MissingIndexException message', () {
    test('names the collection and the Index to add', () {
      final scope = txns.pattern.resolve({'accountId': 'a1'});
      expect(
        () => planQuery(
          entry: entry,
          scopePath: scope,
          filters: [txnCurrency.isEqualTo('USD')],
          orders: const [],
          limit: 10,
          cursor: null,
          fullScan: false,
        ),
        throwsA(
          isA<MissingIndexException>()
              .having(
                (e) => e.message,
                'message',
                contains("Add Index(['accountId', 'currency'])"),
              )
              .having(
                (e) => e.suggestedIndex,
                'suggestedIndex',
                "Index(['accountId', 'currency'])",
              ),
        ),
      );
    });

    test('reports multiple range filters without suggesting an index', () {
      final scope = txns.pattern.resolve({'accountId': 'a1'});
      expect(
        () => planQuery(
          entry: entry,
          scopePath: scope,
          filters: [
            txnBookedOn.isGreaterThan(1),
            txnAmountMinor.isGreaterThan(0),
          ],
          orders: const [],
          limit: 10,
          cursor: null,
          fullScan: false,
        ),
        throwsA(
          isA<MissingIndexException>().having(
            (e) => e.message,
            'message',
            contains('at most one range filter'),
          ),
        ),
      );
    });

    test('points at allowFullScan for a bare collection-group scan', () {
      expect(
        () => planQuery(
          entry: entry,
          scopePath: null,
          filters: const [],
          orders: const [],
          limit: 10,
          cursor: null,
          fullScan: false,
        ),
        throwsA(
          isA<MissingIndexException>()
              .having((e) => e.message, 'message', contains('.allowFullScan()'))
              .having((e) => e.suggestedIndex, 'suggestedIndex', isNull),
        ),
      );
    });
  });

  test('the planned SQL for the canonical scoped query', () {
    final scope = txns.pattern.resolve({'accountId': 'a1'});
    final plan = planQuery(
      entry: entry,
      scopePath: scope,
      filters: [txnBookedOn.isGreaterThanOrEqualTo(20260101)],
      orders: const [QueryOrder('bookedOn', descending: true)],
      limit: 50,
      cursor: null,
      fullScan: false,
    );
    expect(
      plan.sql,
      'SELECT path, id, data, p_account_id, f_booked_on FROM txn '
      'WHERE p_account_id = ? AND f_booked_on >= ? '
      'ORDER BY f_booked_on DESC, id DESC LIMIT ?',
    );
    expect(plan.args, ['a1', 20260101, 51]);
    expect(plan.cursorColumns, ['f_booked_on']);
    expect(plan.fingerprint, matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('the count SQL shares the filters but drops order and keyset', () {
    // A collection-group query: no parent params, so the declared
    // (status, bookedOn, id) index serves it.
    final plan = planQuery(
      entry: entry,
      scopePath: null,
      filters: [txnStatus.isEqualTo(TxnStatus.posted)],
      orders: const [QueryOrder('bookedOn', descending: true)],
      limit: 5,
      cursor: null,
      fullScan: false,
    );
    expect(plan.countSql, 'SELECT count(*) AS c FROM txn WHERE f_status = ?');
    expect(plan.countArgs, ['posted']);

    // A valid cursor changes the page SQL but never the count SQL.
    final cursor = CursorCodec.encode(plan.fingerprint, [20260101, 'tx1']);
    final paged = planQuery(
      entry: entry,
      scopePath: null,
      filters: [txnStatus.isEqualTo(TxnStatus.posted)],
      orders: const [QueryOrder('bookedOn', descending: true)],
      limit: 5,
      cursor: cursor,
      fullScan: false,
    );
    expect(paged.countSql, plan.countSql);
    expect(paged.countArgs, plan.countArgs);
    expect(paged.fingerprint, plan.fingerprint);
    expect(paged.sql, contains('AND (f_booked_on, id) < (?, ?)'));
  });

  test('a range filter without sort keys takes the extra index slot', () {
    final scope = txns.pattern.resolve({'accountId': 'a1'});
    final plan = planQuery(
      entry: entry,
      scopePath: scope,
      filters: [txnBookedOn.isGreaterThan(20260101)],
      orders: const [],
      limit: null,
      cursor: null,
      fullScan: false,
    );
    expect(
      plan.sql,
      'SELECT path, id, data, p_account_id FROM txn '
      'WHERE p_account_id = ? AND f_booked_on > ? '
      'ORDER BY id ASC',
    );
  });
}
