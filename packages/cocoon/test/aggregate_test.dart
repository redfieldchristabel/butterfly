import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/sqlite_executor.dart';
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/spy_executor.dart';

Txn txnOf(
  int amountMinor, {
  int bookedOn = 20240115,
  double rate = 1.5,
  TxnStatus status = TxnStatus.posted,
  String currency = 'MYR',
  DateTime? createdAt,
  String? memo,
}) => Txn(
  bookedOn: bookedOn,
  amountMinor: amountMinor,
  rate: rate,
  currency: currency,
  status: status,
  createdAt: createdAt ?? DateTime.utc(2026, 1, 15, 10, 30),
  memo: memo,
);

/// Aggregates (Firestore-style count/sum/average, plus Cocoon's min/max),
/// the groupBy extension, and their watches — every case against a real
/// SQLite database in a temp dir, with Dart-computed oracles.
void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({List<CollectionAdapter<Object?>>? collections}) {
    return Cocoon.open(
      dbPath(),
      collections: collections ?? [accounts, txns, splits],
    ).then((opened) {
      openDbs.add(opened);
      return opened;
    });
  }

  Future<(Cocoon, SpyExecutor)> openSpied() async {
    final spy = SpyExecutor(SqliteExecutor(SqliteDatabase(path: dbPath())));
    final opened = await Cocoon.openWith(
      spy,
      collections: [accounts, txns, splits],
    );
    openDbs.add(opened);
    return (opened, spy);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_aggregate_test');
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  DocRef<Txn> txnRef(Cocoon db, String accountId, String id) =>
      db.collection(accounts).doc(accountId).collection(txns).doc(id);

  Future<void> seed(
    Cocoon db,
    String accountId,
    Iterable<Txn> txns, {
    String prefix = 't',
  }) async {
    var i = 0;
    for (final txn in txns) {
      await txnRef(
        db,
        accountId,
        '$prefix${i.toString().padLeft(3, '0')}',
      ).set(txn);
      i++;
    }
  }

  /// The exact SQL semantics of `bucket(field, width: w)`:
  /// floor(value / width) * width, with integer floor division.
  int intBucketOf(int value, int width) =>
      value - (((value % width) + width) % width);

  /// Lets broadcast-stream deliveries and SQLite round trips land.
  Future<void> settle([int ms = 25]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('aggregate (Firestore-style)', () {
    test('count, sum and average match a Dart oracle on random data', () async {
      final db = await openDatabase();
      final rng = Random(7);
      final docs = <Txn>[];
      for (var i = 0; i < 300; i++) {
        docs.add(
          Txn(
            bookedOn: 20240100 + (i % 12) * 100 + (i % 28) + 1,
            amountMinor: rng.nextInt(20001) - 10000,
            rate: rng.nextDouble() * 10,
            currency: ['MYR', 'USD', 'SGD'][rng.nextInt(3)],
            status: TxnStatus.values[rng.nextInt(3)],
            createdAt: DateTime.utc(
              2024,
              1,
              1,
            ).add(Duration(minutes: rng.nextInt(525600))),
            memo: rng.nextInt(4) == 0 ? null : 'm$i',
          ),
        );
      }
      await seed(db, 'a1', docs);

      int sumOf(Iterable<Txn> rows) =>
          rows.fold(0, (total, txn) => total + txn.amountMinor);
      final all = docs;
      final myr = docs.where((txn) => txn.currency == 'MYR').toList();
      final posted2024Q1 = docs
          .where(
            (txn) => txn.status == TxnStatus.posted && txn.bookedOn <= 20240331,
          )
          .toList();

      // The whole collection, unfiltered (an equality-only shape served by
      // the scope index once the id order is declared).
      final snapshot = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .aggregate([
            count(),
            sum(txnAmountMinor),
            average(txnRate),
            sum(txnRate),
          ])
          .get();
      expect(snapshot.count, all.length);
      expect(snapshot.getSum(txnAmountMinor), sumOf(all));
      expect(
        snapshot.getAverage(txnRate),
        closeTo(
          all.fold<double>(0, (total, txn) => total + txn.rate) / all.length,
          1e-6,
        ),
      );
      // A double field sums to double, an int field to int.
      expect(snapshot.getSum(txnAmountMinor), isA<int>());
      expect(snapshot.getSum(txnRate), isA<double>());
      expect(snapshot.getAverage(txnRate), isA<double?>());

      // Equality filter.
      final myrSnapshot = await db
          .collectionGroup(txns)
          .where(txnCurrency.isEqualTo('MYR'))
          .aggregate([count(), sum(txnAmountMinor)])
          .get();
      expect(myrSnapshot.count, myr.length);
      expect(myrSnapshot.getSum(txnAmountMinor), sumOf(myr));

      // Equality + range filter (the (status, bookedOn) index serves it).
      final filtered = await db
          .collectionGroup(txns)
          .where(txnStatus.isEqualTo(TxnStatus.posted))
          .where(txnBookedOn.isLessThanOrEqualTo(20240331))
          .orderBy(txnBookedOn)
          .aggregate([count(), sum(txnAmountMinor)])
          .get();
      expect(filtered.count, posted2024Q1.length);
      expect(filtered.getSum(txnAmountMinor), sumOf(posted2024Q1));
    });

    test(
      'empty result: count 0, sum 0, average null, min and max null',
      () async {
        final db = await openDatabase();
        final snapshot = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .orderBy(txnBookedOn)
            .aggregate([
              count(),
              sum(txnAmountMinor),
              average(txnAmountMinor),
              minOf(txnAmountMinor),
              maxOf(txnAmountMinor),
            ])
            .get();
        expect(snapshot.count, 0);
        expect(snapshot.getSum(txnAmountMinor), 0);
        expect(snapshot.getAverage(txnAmountMinor), isNull);
        expect(snapshot.getMin(txnAmountMinor), isNull);
        expect(snapshot.getMax(txnAmountMinor), isNull);
      },
    );

    test('the index rule is the query rule: MissingIndexException names the '
        'Index, allowFullScan opts out', () async {
      final db = await openDatabase();
      // currency + status equality with a bookedOn range: no declared index
      // serves this shape.
      Future<Object> run() => db
          .collectionGroup(txns)
          .where(txnCurrency.isEqualTo('MYR'))
          .where(txnStatus.isEqualTo(TxnStatus.posted))
          .where(txnBookedOn.isGreaterThanOrEqualTo(20240101))
          .aggregate([count()])
          .get();
      await expectLater(
        run(),
        throwsA(
          isA<MissingIndexException>()
              .having(
                (error) => error.suggestedIndex,
                'suggestedIndex',
                "Index(['currency', 'status', 'bookedOn'])",
              )
              .having(
                (error) => error.toString(),
                'toString',
                contains("Index(['currency', 'status', 'bookedOn'])"),
              ),
        ),
      );

      // The same shape with allowFullScan computes the right value.
      await seed(db, 'a1', [txnOf(500, bookedOn: 20240105)]);
      final snapshot = await db
          .collectionGroup(txns)
          .where(txnCurrency.isEqualTo('MYR'))
          .where(txnStatus.isEqualTo(TxnStatus.posted))
          .where(txnBookedOn.isGreaterThanOrEqualTo(20240101))
          .allowFullScan()
          .aggregate([count(), sum(txnAmountMinor)])
          .get();
      expect(snapshot.count, 1);
      expect(snapshot.getSum(txnAmountMinor), 500);
    });

    test(
      'orderBy + limit aggregate the first N documents in that order',
      () async {
        final db = await openDatabase();
        final docs = <Txn>[];
        for (var i = 0; i < 50; i++) {
          docs.add(
            Txn(
              bookedOn: 20240100 + i, // unique: no ties to break
              amountMinor: (i + 1) * 10,
              rate: 1,
              currency: 'MYR',
              status: TxnStatus.posted,
              createdAt: DateTime.utc(2024),
            ),
          );
        }
        await seed(db, 'a1', docs);

        final snapshot = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .orderBy(txnBookedOn, descending: true)
            .limit(10)
            .aggregate([count(), sum(txnAmountMinor)])
            .get();
        // The 10 latest bookedOn values are i = 49..40.
        expect(snapshot.count, 10);
        expect(
          snapshot.getSum(txnAmountMinor),
          [
            for (var i = 40; i <= 49; i++) (i + 1) * 10,
          ].fold(0, (a, b) => a + b),
        );

        // Without a limit the whole set aggregates regardless of the order.
        final whole = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .orderBy(txnBookedOn, descending: true)
            .aggregate([count(), sum(txnAmountMinor)])
            .get();
        expect(whole.count, 50);
        expect(
          whole.getSum(txnAmountMinor),
          [for (var i = 0; i < 50; i++) (i + 1) * 10].fold(0, (a, b) => a + b),
        );
      },
    );

    test(
      'a field without an f_ column throws, naming the declaration',
      () async {
        final db = await openDatabase();
        final phantom = FieldColumn.integer<Txn, int>(
          'phantom',
          read: (_) => 0,
        );
        await expectLater(
          db.collection(accounts).doc('a1').collection(txns).aggregate([
            sum(phantom),
          ]).get(),
          throwsA(
            isA<UnmirroredFieldException>()
                .having(
                  (error) => error.suggestedDeclaration,
                  'suggestedDeclaration',
                  "@Mirrored() on the field, or Index(['phantom']) on its "
                      '@Collection declaration',
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('not mirrored into a column'),
                ),
          ),
        );
      },
    );

    test(
      'more than five aggregations are refused, none is refused too',
      () async {
        final db = await openDatabase();
        final query = db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .orderBy(txnBookedOn);
        expect(
          () => query.aggregate([
            count(),
            sum(txnAmountMinor),
            average(txnAmountMinor),
            minOf(txnAmountMinor),
            maxOf(txnAmountMinor),
            sum(txnRate),
          ]),
          throwsArgumentError,
        );
        expect(() => query.aggregate(const []), throwsArgumentError);
        // Five is fine.
        await query.aggregate([
          count(),
          sum(txnAmountMinor),
          average(txnAmountMinor),
          minOf(txnAmountMinor),
          maxOf(txnAmountMinor),
        ]).get();
      },
    );

    test('getters for functions that were not requested throw', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [txnOf(100)]);
      final snapshot = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .aggregate([count(), sum(txnAmountMinor)])
          .get();
      expect(
        () => snapshot.getAverage(txnAmountMinor),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('did not request average(amountMinor)'),
          ),
        ),
      );
      expect(() => snapshot.getMin(txnAmountMinor), throwsArgumentError);
      expect(() => snapshot.getMax(txnAmountMinor), throwsArgumentError);
    });

    test(
      'an integer sum past 2^63 overflows with a typed error, not garbage',
      () async {
        final db = await openDatabase();
        const max = 9223372036854775807;
        await seed(db, 'a1', [txnOf(max), txnOf(max)]);
        await expectLater(
          db.collection(accounts).doc('a1').collection(txns).aggregate([
            sum(txnAmountMinor),
          ]).get(),
          throwsA(
            isA<AggregateOverflowException>().having(
              (error) => error.message,
              'message',
              contains('64-bit integer'),
            ),
          ),
        );
      },
    );

    test('count() stays identical to aggregate([count()])', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [txnOf(100), txnOf(200), txnOf(300)]);
      final query = db
          .collectionGroup(txns)
          .where(txnStatus.isEqualTo(TxnStatus.posted))
          .orderBy(txnBookedOn);
      expect(await query.count(), 3);
      expect((await query.aggregate([count()]).get()).count, 3);
      // And the numbers agree across both paths after more writes.
      await seed(db, 'a1', [
        txnOf(400, status: TxnStatus.pending),
      ], prefix: 'u');
      expect(await query.count(), 3);
      expect((await query.aggregate([count()]).get()).count, 3);
    });

    test(
      'whole-result min/max work (a Cocoon extension), typed per field',
      () async {
        final db = await openDatabase();
        await seed(db, 'a1', [
          txnOf(-500, createdAt: DateTime.utc(2026, 1, 5), currency: 'SGD'),
          txnOf(900, createdAt: DateTime.utc(2026, 3, 5), currency: 'MYR'),
          txnOf(100, createdAt: DateTime.utc(2026, 2, 5), currency: 'MYR'),
        ]);
        final snapshot = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .orderBy(txnBookedOn, descending: true)
            .aggregate([
              minOf(txnAmountMinor),
              maxOf(txnAmountMinor),
              minOf(txnCreatedAt),
              maxOf(txnCreatedAt),
              maxOf(txnCurrency),
            ])
            .get();
        expect(snapshot.getMin(txnAmountMinor), -500);
        expect(snapshot.getMax(txnAmountMinor), 900);
        expect(snapshot.getMin(txnCreatedAt), DateTime.utc(2026, 1, 5));
        expect(snapshot.getMax(txnCreatedAt), DateTime.utc(2026, 3, 5));
        expect(snapshot.getMax(txnCurrency), 'SGD');
      },
    );

    test('one read statement per get(); no documents decoded', () async {
      final (db, spy) = await openSpied();
      await seed(db, 'a1', [txnOf(100), txnOf(200), txnOf(300)]);
      spy.statements.clear();

      await db.collection(accounts).doc('a1').collection(txns).aggregate([
        count(),
        sum(txnAmountMinor),
      ]).get();
      expect(spy.statements, hasLength(1));
      expect(spy.statements.single, contains('count(*)'));
      expect(spy.statements.single, contains('SUM('));

      spy.statements.clear();
      await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([key(txnCurrency)])
          .aggregate([sum(txnAmountMinor)])
          .get();
      expect(spy.statements, hasLength(1));
      expect(spy.statements.single, contains('GROUP BY'));
    });
  });

  group('groupBy (Cocoon extension)', () {
    test('key(): groups by the field value, typed, null group first', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [
        txnOf(100, memo: 'm1'),
        txnOf(200, memo: 'm1'),
        txnOf(300, memo: 'm2'),
        txnOf(400, memo: null),
        txnOf(500, memo: null),
      ]);
      final memoKey = key(txnMemo);
      final groups = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([memoKey])
          .aggregate([sum(txnAmountMinor), count()])
          .get();

      expect(
        [for (final group in groups) group.key(memoKey)],
        [null, 'm1', 'm2'], // null keys sort first
      );
      expect(groups[0].count, 2);
      expect(groups[0].getSum(txnAmountMinor), 900);
      expect(groups[1].count, 2);
      expect(groups[1].getSum(txnAmountMinor), 300);
      expect(groups[2].count, 1);
      expect(groups[2].getSum(txnAmountMinor), 300);

      // A key the query did not group by throws.
      expect(() => groups[0].key(key(txnCurrency)), throwsArgumentError);
    });

    test('key(): DateTime and enum fields come back converted', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [
        txnOf(100, status: TxnStatus.posted, createdAt: DateTime.utc(2026, 5)),
        txnOf(
          200,
          status: TxnStatus.posted,
          createdAt: DateTime.utc(2026, 5, 9),
        ),
        txnOf(300, status: TxnStatus.pending, createdAt: DateTime.utc(2026, 6)),
      ]);
      final statusKey = key(txnStatus);
      final dayKey = key(txnCreatedAt);
      final groups = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([statusKey, dayKey])
          .aggregate([count()])
          .get();
      expect(groups, hasLength(3));
      expect(groups[0].key(statusKey), TxnStatus.pending);
      expect(groups[0].key(dayKey), DateTime.utc(2026, 6));
      expect(groups[1].key(statusKey), TxnStatus.posted);
      expect(groups[1].key(dayKey), DateTime.utc(2026, 5));
      expect(groups[2].key(dayKey), DateTime.utc(2026, 5, 9));
    });

    test(
      'bucket(): yyyymmdd ints to months, negative amounts floor down',
      () async {
        final db = await openDatabase();
        await seed(db, 'a1', [
          txnOf(100, bookedOn: 20240115),
          txnOf(200, bookedOn: 20240131),
          txnOf(300, bookedOn: 20240201),
          // Negative amounts: floor(value / width) * width.
          txnOf(-15000, bookedOn: 20240301),
          txnOf(-5000, bookedOn: 20240302),
          txnOf(12000, bookedOn: 20240303),
        ]);
        final monthKey = bucket(txnBookedOn, width: 100);
        final bands = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([monthKey])
            .aggregate([sum(txnAmountMinor), count()])
            .get();

        expect(
          [for (final group in bands) group.key(monthKey)],
          [20240100, 20240200, 20240300],
        );
        expect(bands[0].getSum(txnAmountMinor), 300);
        expect(bands[1].getSum(txnAmountMinor), 300);

        final amountKey = bucket(txnAmountMinor, width: 10000);
        final march = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .where(txnBookedOn.isGreaterThanOrEqualTo(20240301))
            .orderBy(txnBookedOn)
            .groupBy([amountKey])
            .aggregate([count(), sum(txnAmountMinor)])
            .get();
        expect(
          [for (final group in march) group.key(amountKey)],
          [-20000, -10000, 10000],
        );
        expect(march[0].count, 1);
        expect(march[0].getSum(txnAmountMinor), -15000);
        expect(march[1].count, 1);
        expect(march[1].getSum(txnAmountMinor), -5000);
        expect(march[2].getSum(txnAmountMinor), 12000);
        // The SQL bucket matches the Dart floor definition.
        expect(march[0].key(amountKey), intBucketOf(-15000, 10000));
      },
    );

    test('bucket(): double fields bucket at fractional widths', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [
        txnOf(1, rate: 1.5),
        txnOf(2, rate: 2.5),
        txnOf(3, rate: 7.9),
      ]);
      final bandKey = bucket(txnRate, width: 2.5);
      final groups = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([bandKey])
          .aggregate([count()])
          .get();
      expect([for (final group in groups) group.key(bandKey)], [0.0, 2.5, 7.5]);
    });

    test('bucket(): a fractional width on an int field is rejected', () async {
      final db = await openDatabase();
      await expectLater(
        db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([bucket(txnBookedOn, width: 100.5)])
            .aggregate([count()])
            .get(),
        throwsArgumentError,
      );
      // A non-positive width too.
      await expectLater(
        db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([bucket(txnBookedOn, width: 0)])
            .aggregate([count()])
            .get(),
        throwsArgumentError,
      );
    });

    test('month/day/year at +08:00 move a 23:30 UTC instant into the next '
        'local day and month', () async {
      final db = await openDatabase();
      final offset = Duration(hours: 8);
      await seed(db, 'a1', [
        // 2026-01-31 23:30 UTC == 2026-02-01 07:30 in +08:00.
        txnOf(1, createdAt: DateTime.utc(2026, 1, 31, 23, 30)),
        // 2026-02-01 00:30 UTC == 2026-02-01 08:30 local: same local day.
        txnOf(2, createdAt: DateTime.utc(2026, 2, 1, 0, 30)),
        // 2026-01-31 15:30 UTC == 2026-01-31 23:30 local: the previous day.
        txnOf(3, createdAt: DateTime.utc(2026, 1, 31, 15, 30)),
        // 1969-12-31 20:30 UTC == 1970-01-01 04:30 local: pre-epoch instants
        // stay exact (the SQL uses integer floor division, not floats).
        txnOf(4, createdAt: DateTime.utc(1969, 12, 31, 20, 30)),
      ]);
      final monthKey = month(txnCreatedAt, utcOffset: offset);
      final dayKey = day(txnCreatedAt, utcOffset: offset);
      final yearKey = year(txnCreatedAt, utcOffset: offset);

      final months = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([monthKey])
          .aggregate([count()])
          .get();
      expect(
        [for (final group in months) group.key(monthKey)],
        [197001, 202601, 202602],
      );
      expect(months[0].count, 1);
      expect(months[1].count, 1);
      expect(months[2].count, 2);

      final days = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([dayKey])
          .aggregate([count()])
          .get();
      expect(
        [for (final group in days) group.key(dayKey)],
        [19700101, 20260131, 20260201],
      );
      expect(days[0].count, 1);
      expect(days[1].count, 1);
      expect(days[2].count, 2); // the 23:30 UTC txn lands on Feb 1 local

      final years = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([yearKey])
          .aggregate([count()])
          .get();
      expect([for (final group in years) group.key(yearKey)], [1970, 2026]);
      expect(years[0].count, 1); // 1969-12-31 20:30Z = 1970-01-01 04:30 +08
      expect(years[1].count, 3);
    });

    test(
      'multi-key: up to four keys, ordered ascending by every key',
      () async {
        final db = await openDatabase();
        final rng = Random(11);
        final docs = <Txn>[];
        for (var i = 0; i < 200; i++) {
          docs.add(
            Txn(
              bookedOn: 20240100 + rng.nextInt(300),
              amountMinor: rng.nextInt(1000),
              rate: 1,
              currency: ['MYR', 'USD'][rng.nextInt(2)],
              status: TxnStatus.values[rng.nextInt(2)],
              createdAt: DateTime.utc(2024),
              memo: rng.nextBool() ? 'a' : 'b',
            ),
          );
        }
        await seed(db, 'a1', docs);

        final currencyKey = key(txnCurrency);
        final statusKey = key(txnStatus);
        final monthKey = bucket(txnBookedOn, width: 100);
        final memoKey = key(txnMemo);
        final groups = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([currencyKey, statusKey, monthKey, memoKey])
            .aggregate([sum(txnAmountMinor), count()])
            .get();

        // Dart oracle: group and sort by (currency, status, month, memo).
        final oracle = <String, int>{};
        for (final txn in docs) {
          final key = [
            txn.currency,
            txn.status.name,
            intBucketOf(txn.bookedOn, 100),
            txn.memo,
          ].join('|');
          oracle[key] = (oracle[key] ?? 0) + txn.amountMinor;
        }
        final expectedKeys = oracle.keys.toList()..sort();
        expect(groups, hasLength(oracle.length));
        for (var i = 0; i < groups.length; i++) {
          final group = groups[i];
          expect(group.key(currencyKey), expectedKeys[i].split('|')[0]);
          expect(group.key(statusKey).name, expectedKeys[i].split('|')[1]);
          expect(group.key(monthKey), int.parse(expectedKeys[i].split('|')[2]));
          expect(group.key(memoKey), expectedKeys[i].split('|')[3]);
          expect(group.getSum(txnAmountMinor), oracle[expectedKeys[i]]);
        }
      },
    );

    test(
      'paramKey: a collection group aggregates one group per parent',
      () async {
        final db = await openDatabase();
        await seed(db, 'a1', [txnOf(100), txnOf(200)]);
        await seed(db, 'a2', [txnOf(300)]);
        await seed(db, 'a3', [txnOf(400, status: TxnStatus.pending)]);

        final GroupKeySpec<Txn, String> accountKey = paramKey(txnAccountId);
        final groups = await db
            .collectionGroup(txns)
            .where(txnStatus.isEqualTo(TxnStatus.posted))
            .orderBy(txnBookedOn)
            .groupBy([accountKey])
            .aggregate([sum(txnAmountMinor), count()])
            .get();
        expect(
          [for (final group in groups) group.key(accountKey)],
          ['a1', 'a2'],
        );
        expect(groups[0].getSum(txnAmountMinor), 300);
        expect(groups[0].count, 2);
        expect(groups[1].getSum(txnAmountMinor), 300);

        // A param of another pattern is refused.
        await expectLater(
          db
              .collectionGroup(txns)
              .query()
              .allowFullScan()
              .groupBy([paramKey<Txn>(txnTxnId)])
              .aggregate([count()])
              .get(),
          throwsArgumentError,
        );
      },
    );

    test('group limit caps the groups in key order', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [
        txnOf(100, memo: 'm1'),
        txnOf(200, memo: 'm2'),
        txnOf(300, memo: 'm3'),
        txnOf(400, memo: null),
      ]);
      final memoKey = key(txnMemo);
      final groups = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([memoKey])
          .limit(3)
          .aggregate([count()])
          .get();
      expect(
        [for (final group in groups) group.key(memoKey)],
        [null, 'm1', 'm2'],
      );
    });

    test('min/max per group, converted back to the field types', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [
        txnOf(
          -500,
          currency: 'MYR',
          createdAt: DateTime.utc(2026, 1, 5),
          rate: 2.5,
        ),
        txnOf(
          900,
          currency: 'MYR',
          createdAt: DateTime.utc(2026, 3, 5),
          rate: 0.5,
        ),
        txnOf(
          100,
          currency: 'SGD',
          createdAt: DateTime.utc(2026, 2, 5),
          rate: 4.0,
        ),
      ]);
      final currencyKey = key(txnCurrency);
      final groups = await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .groupBy([currencyKey])
          .aggregate([
            minOf(txnAmountMinor),
            maxOf(txnAmountMinor),
            minOf(txnCreatedAt),
            maxOf(txnRate),
            average(txnRate),
          ])
          .get();
      final myr = groups.firstWhere((g) => g.key(currencyKey) == 'MYR');
      expect(myr.getMin(txnAmountMinor), -500);
      expect(myr.getMax(txnAmountMinor), 900);
      expect(myr.getMin(txnCreatedAt), DateTime.utc(2026, 1, 5));
      expect(myr.getMax(txnRate), 2.5);
      expect(myr.getAverage(txnRate), closeTo(1.5, 1e-9));
      final sgd = groups.firstWhere((g) => g.key(currencyKey) == 'SGD');
      expect(sgd.getMin(txnAmountMinor), 100);
      expect(sgd.getAverage(txnRate), 4.0);
    });

    test(
      'sums inside a group skip nulls; an all-null MIN/MAX is null',
      () async {
        final db = await openDatabase();
        await seed(db, 'a1', [
          // `memo` is the adapter's one nullable field: the null group holds
          // the memo-less txns, and its MIN(memo)/MAX(memo) have no values.
          txnOf(100, memo: null),
          txnOf(200, memo: 'x'),
        ]);
        final memoKey = key(txnMemo);
        final groups = await db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([memoKey])
            .aggregate([count(), minOf(txnAmountMinor), maxOf(txnMemo)])
            .get();
        final nullGroup = groups.first;
        expect(nullGroup.key(memoKey), isNull);
        expect(nullGroup.count, 1);
        expect(nullGroup.getMin(txnAmountMinor), 100);
        expect(nullGroup.getMax(txnMemo), isNull); // all-null MIN/MAX -> null
        final xGroup = groups[1];
        expect(xGroup.count, 1);
        expect(xGroup.getMax(txnMemo), 'x');
      },
    );
  });

  group('aggregate watches', () {
    test('emits on listen, on relevant commits, not on other tables, and '
        'not again while the values are equal', () async {
      final db = await openDatabase();
      await seed(db, 'a1', [txnOf(100), txnOf(200)]);
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme', active: true));

      final emissions = <AggregateQuerySnapshot<Txn>>[];
      final sub = db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .aggregate([count(), sum(txnAmountMinor)])
          .watch()
          .listen(emissions.add);
      await settle();
      expect(emissions, hasLength(1));
      expect(emissions.first.count, 2);
      expect(emissions.first.getSum(txnAmountMinor), 300);

      // A commit that touches txns: re-emits with new values.
      await seed(db, 'a1', [txnOf(300)], prefix: 'u');
      await settle();
      expect(emissions, hasLength(2));
      expect(emissions.last.count, 3);
      expect(emissions.last.getSum(txnAmountMinor), 600);

      // A rewrite that changes no aggregate (memo is not aggregated) does
      // not emit again.
      await txnRef(db, 'a1', 't000').set(txnOf(100).copyWith(memo: 'edited'));
      // (t000 still holds amountMinor 100.)
      await settle();
      expect(emissions, hasLength(2));

      // A commit to another collection never re-runs it.
      await db
          .collection(accounts)
          .doc('a1')
          .set(const Account(name: 'Acme 2', active: true));
      await settle();
      expect(emissions, hasLength(2));

      // A delete re-emits.
      await txnRef(db, 'a1', 'u000').delete();
      await settle();
      expect(emissions, hasLength(3));
      expect(emissions.last.count, 2);
      expect(emissions.last.getSum(txnAmountMinor), 300);

      await sub.cancel();
    });

    test(
      'scoped aggregate watches ignore commits outside their scope',
      () async {
        final db = await openDatabase();
        await seed(db, 'a1', [txnOf(100)]);
        await seed(db, 'a2', [txnOf(500)]);

        final emissions = <AggregateQuerySnapshot<Txn>>[];
        final sub = db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .aggregate([count()])
            .watch()
            .listen(emissions.add);
        await settle();
        expect(emissions.single.count, 1);

        await seed(db, 'a2', [txnOf(700)], prefix: 'u');
        await settle();
        expect(emissions, hasLength(1), reason: 'a2 is outside the scope');

        await seed(db, 'a1', [txnOf(200)], prefix: 'u');
        await settle();
        expect(emissions, hasLength(2));
        expect(emissions.last.count, 2);

        await sub.cancel();
      },
    );

    test(
      'groupBy watches re-emit when the groups change, dedup otherwise',
      () async {
        final db = await openDatabase();
        await seed(db, 'a1', [txnOf(100, currency: 'MYR')]);

        final currencyKey = key(txnCurrency);
        final emissions = <List<AggregateGroup<Txn>>>[];
        final sub = db
            .collection(accounts)
            .doc('a1')
            .collection(txns)
            .groupBy([currencyKey])
            .aggregate([sum(txnAmountMinor), count()])
            .watch()
            .listen(emissions.add);
        await settle();
        expect(emissions, hasLength(1));
        expect(emissions.first, hasLength(1));
        expect(emissions.first.single.getSum(txnAmountMinor), 100);

        // Same key, same values: a rewrite emits nothing.
        await txnRef(
          db,
          'a1',
          't000',
        ).set(txnOf(100, currency: 'MYR').copyWith(memo: 'x'));
        await settle();
        expect(emissions, hasLength(1));

        // A new group appears.
        await seed(db, 'a1', [txnOf(50, currency: 'SGD')], prefix: 'u');
        await settle();
        expect(emissions, hasLength(2));
        expect(emissions.last, hasLength(2));
        expect(
          [for (final group in emissions.last) group.key(currencyKey)],
          ['MYR', 'SGD'],
        );

        await sub.cancel();
      },
    );

    test('an aggregate whose serving index is deferred waits for the '
        'writer, then runs', () async {
      final db = await openDatabase();
      final bulk = db.bulkWriter(BulkWriterOptions(chunkSize: 1));
      bulk.set(txnRef(db, 'a1', 't1'), txnOf(100));
      bulk.set(txnRef(db, 'a1', 't2'), txnOf(200));
      await bulk.flush();

      // The (accountId, -bookedOn) index serves this shape and is deferred:
      // the aggregate holds until the writer closes.
      var completed = false;
      final aggregate = db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .where(txnBookedOn.isGreaterThanOrEqualTo(20240101))
          .aggregate([count(), sum(txnAmountMinor)])
          .get();
      unawaited(
        aggregate.then<void>((_) {
          completed = true;
        }),
      );
      await settle(50);
      expect(completed, isFalse, reason: 'the aggregate must wait for close');

      await bulk.close();
      final snapshot = await aggregate;
      expect(completed, isTrue);
      expect(snapshot.count, 2);
      expect(snapshot.getSum(txnAmountMinor), 300);
    });
  });
}
