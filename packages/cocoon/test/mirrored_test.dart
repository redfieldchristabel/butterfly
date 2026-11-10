import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/executor.dart';
import 'package:cocoon/src/engine/sqlite_executor.dart';
import 'package:test/test.dart';

import 'support/models.dart';

Txn txn(int bookedOn, int amountMinor, {String category = 'misc'}) => Txn(
  bookedOn: bookedOn,
  amountMinor: amountMinor,
  rate: 1.5,
  currency: 'MYR',
  status: TxnStatus.posted,
  createdAt: DateTime.utc(2026, 1, 15, 10, 30),
  category: category,
);

/// `@Mirrored()` fields: a column without an index. Aggregates and group-by
/// read the column, filters still follow the index rule, and the column is
/// added (backfilled), dropped and bulk-written like any `f_` column. Every
/// case runs against a real SQLite database in a temp dir with Dart oracles.
void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({
    List<CollectionAdapter<Object?>>? collections,
    CocoonExecutor? executor,
  }) {
    final future = executor == null
        ? Cocoon.open(
            dbPath(),
            collections: collections ?? [accounts, txnsWithCategory, splits],
          )
        : Cocoon.openWith(
            executor,
            collections: collections ?? [accounts, txnsWithCategory, splits],
          );
    return future.then((opened) {
      openDbs.add(opened);
      return opened;
    });
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_mirrored_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  DocRef<Txn> txnRef(
    Cocoon db,
    CollectionAdapter<Txn> adapter,
    String accountId,
    String id,
  ) => db.collection(accounts).doc(accountId).collection(adapter).doc(id);

  Future<List<Map<String, Object?>>> tableColumns(Cocoon db) =>
      db.executor.getAll('PRAGMA table_info(txn)');

  /// The physical indexes on the txn table, by name.
  Future<Set<String>> indexNames(Cocoon db) async {
    final rows = await db.executor.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'txn'",
    );
    return {for (final row in rows) row['name']! as String};
  }

  group('aggregates over a mirrored-only field', () {
    final docs = [
      txn(20240101, 100, category: 'food'),
      txn(20240102, -250, category: 'food'),
      txn(20240103, 999, category: 'rent'),
      txn(20240104, 50, category: 'food'),
      txn(20240105, 7000, category: 'rent'),
    ];

    test('sum, average, min, max and groupBy match a Dart oracle', () async {
      final db = await openDatabase(collections: [accounts, txnsWithCategory]);
      for (var i = 0; i < docs.length; i++) {
        await txnRef(db, txnsWithCategory, 'a1', 't$i').set(docs[i]);
      }

      final food = docs.where((t) => t.category == 'food').toList();
      final snapshot =
          await db.collection(accounts).doc('a1').collection(txns).aggregate([
            count(),
            sum(txnAmountMinor),
            average(txnAmountMinor),
            minOf(txnAmountMinor),
            maxOf(txnAmountMinor),
          ]).get();
      expect(snapshot.count, docs.length);
      expect(
        snapshot.getSum(txnAmountMinor),
        docs.fold(0, (total, t) => total + t.amountMinor),
      );
      expect(snapshot.getAverage(txnAmountMinor), closeTo(1579.8, 1e-9));
      expect(snapshot.getMin(txnAmountMinor), -250);
      expect(snapshot.getMax(txnAmountMinor), 7000);

      // groupBy over the mirrored String field: one group per category.
      final categoryKey = key(txnCategory);
      final groups = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([categoryKey])
          .aggregate([count(), sum(txnAmountMinor)])
          .get();
      expect(groups, hasLength(2));
      final byCategory = {
        for (final group in groups)
          group.key(categoryKey): (
            count: group.count,
            sum: group.getSum(txnAmountMinor),
          ),
      };
      expect(byCategory['food'], (count: 3, sum: 100 - 250 + 50));
      expect(byCategory['rent'], (count: 2, sum: 999 + 7000));
      // Groups come ordered by key ascending; unused variable for the oracle
      // above keeps the analyzer honest about `food`.
      expect(food.length, 3);
    });

    test(
      'a filter on it follows the index rule and allowFullScan opts out',
      () async {
        final db = await openDatabase(
          collections: [accounts, txnsWithCategory],
        );
        for (var i = 0; i < docs.length; i++) {
          await txnRef(db, txnsWithCategory, 'a1', 't$i').set(docs[i]);
        }

        await expectLater(
          db
              .collection(accounts)
              .doc('a1')
              .collection(txnsWithCategory)
              .where(txnCategory.isEqualTo('food'))
              .get(),
          throwsA(
            isA<MissingIndexException>().having(
              (error) => error.suggestedIndex,
              'suggestedIndex',
              // The subcollection scope's param joins the suggestion.
              "Index(['accountId', 'category'])",
            ),
          ),
        );
        // Aggregating through the same filter refuses the same way.
        await expectLater(
          db
              .collection(accounts)
              .doc('a1')
              .collection(txnsWithCategory)
              .where(txnCategory.isEqualTo('food'))
              .aggregate([count()])
              .get(),
          throwsA(isA<MissingIndexException>()),
        );

        // The opt-out reads it anyway.
        final scanned = await db
            .collection(accounts)
            .doc('a1')
            .collection(txnsWithCategory)
            .where(txnCategory.isEqualTo('food'))
            .allowFullScan()
            .aggregate([count(), sum(txnAmountMinor)])
            .get();
        expect(scanned.count, 3);
        expect(scanned.getSum(txnAmountMinor), -100);
      },
    );
  });

  group('schema evolution', () {
    Future<void> seedWithoutMirroring() async {
      final db = await openDatabase(collections: [accounts, txns, splits]);
      for (var i = 0; i < 40; i++) {
        await txnRef(
          db,
          txns,
          'a1',
          't${i.toString().padLeft(2, '0')}',
        ).set(txn(20240101 + i, (i + 1) * 10));
      }
      await db.close();
      openDbs.clear();
    }

    test(
      'adding @Mirrored() to a populated collection backfills at open',
      () async {
        await seedWithoutMirroring();

        final db = await openDatabase(
          collections: [accounts, txnsWithCategory, splits],
        );
        // The column exists and no index covers it.
        final columns = await tableColumns(db);
        final category = columns.singleWhere(
          (column) => column['name'] == 'f_category',
        );
        expect(category['type'], 'TEXT');
        final indexes = await indexNames(db);
        final categoryIndexes = indexes
            .where((name) => name != 'cx_txn_scope')
            .toList();
        // The other declared indexes are there; none is on f_category.
        expect(categoryIndexes, isNotEmpty);
        for (final name in categoryIndexes) {
          final sql =
              (await db.executor.getOptional(
                    'SELECT sql FROM sqlite_master WHERE name = ?',
                    [name],
                  ))?['sql']
                  as String?;
          // A null sql is an auto-created index (the path UNIQUE one); it
          // cannot cover f_category either.
          expect(
            sql?.contains('f_category') ?? false,
            isFalse,
            reason: 'index $name covers the mirrored column',
          );
        }

        // The backfilled values match what the documents carry: one group
        // per category, sums straight off the column.
        final categoryKey = key(txnCategory);
        final groups = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([categoryKey])
            .aggregate([count(), sum(txnAmountMinor)])
            .get();
        final byCategory = {
          for (final group in groups)
            group.key(categoryKey): (
              count: group.count,
              sum: group.getSum(txnAmountMinor),
            ),
        };
        expect(byCategory['misc'], (
          count: 40,
          sum: [for (var i = 1; i <= 40; i++) i * 10].fold(0, (a, b) => a + b),
        ));
        expect(byCategory.length, 1);
      },
    );

    test(
      'a crash mid-backfill rolls the open back; the next open completes it',
      () async {
        await seedWithoutMirroring();

        // The first backfill batch update aborts the open transaction: the
        // process died mid-backfill. Nothing lands on disk.
        await expectLater(
          openDatabase(
            collections: [accounts, txnsWithCategory, splits],
            executor: FlakyExecutor(
              SqliteExecutor(SqliteDatabase(path: dbPath())),
              failBatchAt: 1,
            ),
          ),
          throwsStateError,
        );
        // The rolled-back file is exactly the old shape: no column yet, every
        // document intact.
        final before = await openDatabase(
          collections: [accounts, txns, splits],
        );
        expect(
          (await tableColumns(before)).map((column) => column['name']),
          isNot(contains('f_category')),
        );
        expect(
          (await before
                  .collection(accounts)
                  .doc('a1')
                  .collection(txns)
                  .orderBy(txnBookedOn)
                  .get())
              .docs
              .length,
          40,
        );
        await before.close();
        openDbs.clear();

        // The next open with the mirrored schema redoes the backfill in full.
        final db = await openDatabase(
          collections: [accounts, txnsWithCategory, splits],
        );
        final categoryKey = key(txnCategory);
        final groups = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([categoryKey])
            .aggregate([count(), sum(txnAmountMinor)])
            .get();
        expect(groups.single.key(categoryKey), 'misc');
        expect(
          groups.single.getSum(txnAmountMinor),
          [for (var i = 1; i <= 40; i++) i * 10].fold(0, (a, b) => a + b),
        );
      },
    );

    test('removing @Mirrored() drops the column and keeps the data', () async {
      // Build with the mirrored column, then reopen without it.
      final seeded = await openDatabase(
        collections: [accounts, txnsWithCategory, splits],
      );
      for (var i = 0; i < 10; i++) {
        await txnRef(
          seeded,
          txnsWithCategory,
          'a1',
          't$i',
        ).set(txn(20240101 + i, i * 100, category: 'c$i'));
      }
      final indexesBefore = await indexNames(seeded);
      await seeded.close();
      openDbs.clear();

      final db = await openDatabase(collections: [accounts, txns, splits]);
      expect(
        (await tableColumns(db)).map((column) => column['name']),
        isNot(contains('f_category')),
      );
      // The declared indexes survive the column drop (only the dropped
      // column's indexes go, and the mirrored column had none).
      expect(await indexNames(db), indexesBefore);
      final doc = await txnRef(db, txns, 'a1', 't3').get();
      expect(doc!.data.amountMinor, 300);
      expect(doc.data.category, 'c3'); // still in the blob, still decoded
    });
  });

  test('bulkWriter() fills mirrored columns', () async {
    final db = await openDatabase(collections: [accounts, txnsWithCategory]);
    final bulk = db.bulkWriter();
    for (var i = 0; i < 100; i++) {
      bulk.set(
        txnRef(db, txnsWithCategory, 'a1', 't${i.toString().padLeft(3, '0')}'),
        txn(20240101 + i, i + 1, category: i % 2 == 0 ? 'even' : 'odd'),
      );
    }
    await bulk.close();

    final categoryKey = key(txnCategory);
    final groups = await db
        .collection(accounts)
        .doc('a1')
        .collection(txns)
        .groupBy([categoryKey])
        .aggregate([count(), sum(txnAmountMinor)])
        .get();
    final byCategory = {
      for (final group in groups)
        group.key(categoryKey): (
          count: group.count,
          sum: group.getSum(txnAmountMinor),
        ),
    };
    expect(byCategory['even'], (
      count: 50,
      sum: [for (var i = 0; i < 100; i += 2) i + 1].fold(0, (a, b) => a + b),
    ));
    expect(byCategory['odd'], (
      count: 50,
      sum: [for (var i = 1; i < 100; i += 2) i + 1].fold(0, (a, b) => a + b),
    ));
  });
}

/// A real executor whose Nth `executeBatch` fails: a crash mid-backfill, so
/// the open transaction never commits.
final class FlakyExecutor implements CocoonExecutor {
  FlakyExecutor(this._inner, {required this.failBatchAt});

  final CocoonExecutor _inner;

  /// The 1-based executeBatch call that fails.
  final int failBatchAt;

  var _batches = 0;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) => _inner.getAll(sql, args);

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) => _inner.getOptional(sql, args);

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) =>
      _inner.execute(sql, args);

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) {
    _batches++;
    if (_batches == failBatchAt) {
      throw StateError('crashed mid-backfill (batch $_batches)');
    }
    return _inner.executeBatch(sql, parameterSets);
  }

  @override
  Future<T> writeTransaction<T>(Future<T> Function(CocoonTx tx) body) =>
      _inner.writeTransaction<T>((tx) => body(_FlakyTx(this, tx)));

  @override
  Future<T> readTransaction<T>(Future<T> Function(CocoonRead tx) body) =>
      _inner.readTransaction<T>(body);

  @override
  Future<void> close() => _inner.close();
}

final class _FlakyTx implements CocoonTx {
  _FlakyTx(this._flaky, this._inner);

  final FlakyExecutor _flaky;
  final CocoonTx _inner;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) => _inner.getAll(sql, args);

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) => _inner.getOptional(sql, args);

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) =>
      _inner.execute(sql, args);

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _flaky.executeBatch(sql, parameterSets);
}
