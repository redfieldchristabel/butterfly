import 'dart:convert';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/query.dart';
import 'package:test/test.dart';

import 'support/models.dart';

Txn txn(int bookedOn, int amountMinor) => Txn(
  bookedOn: bookedOn,
  amountMinor: amountMinor,
  rate: 1.5,
  currency: 'MYR',
  status: TxnStatus.posted,
  createdAt: DateTime.utc(2026, 1, 15, 10, 30),
);

/// The missing-index behaviours of a query no declared index serves:
///
/// - the default throws the `MissingIndexException` whose message ends with
///   the ready `Fix:` line;
/// - the debug-only `MissingIndexMode.scanAndWarn` fallback runs the query as
///   a full scan, records one `MissingIndexReport` per distinct missing index
///   in `db.missingIndexes`, and never creates an index;
/// - in a build without asserts the fallback is refused: it throws like the
///   default. That build does not exist under `dart test` (asserts are on),
///   so it is exercised through `test/fixtures/missing_index_fixture.dart`,
///   a subprocess run with plain `dart run` (asserts off) and with
///   `dart run --enable-asserts` (asserts on, the warn-once behaviour over
///   real stderr). See `spawnFixture` below.
///
/// Every case runs against a real SQLite database in a temp dir.
void main() {
  late Directory dir;
  final openDbs = <Cocoon>[];

  String dbPath([String name = 'cocoon.db']) =>
      '${dir.path}${Platform.pathSeparator}$name';

  Future<Cocoon> openDatabase({
    List<CollectionAdapter<Object?>>? collections,
    CocoonOptions options = const CocoonOptions(),
  }) async {
    final opened = await Cocoon.open(
      dbPath(),
      collections: collections ?? [accounts, txns, splits],
      options: options,
    );
    openDbs.add(opened);
    return opened;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cocoon_missing_index_test');
    // The warn-once set is process-wide; keep the suites independent.
    resetMissingIndexWarnings();
  });

  tearDown(() async {
    for (final opened in openDbs) {
      await opened.close();
    }
    openDbs.clear();
    dir.deleteSync(recursive: true);
  });

  Future<void> seed(Cocoon db, Iterable<Txn> docs) async {
    var i = 0;
    for (final doc in docs) {
      await db
          .collection(accounts)
          .doc('a1')
          .collection(txns)
          .doc('t${i++}')
          .set(doc);
    }
  }

  /// The query no declared index serves (amountMinor is @Mirrored, so it has
  /// a column but no index): an equality filter on it.
  CocoonQuery<Txn> missingEqualityQuery(Cocoon db) =>
      db.collectionGroup(txns).where(txnAmountMinor.isEqualTo(100));

  /// A second, different missing index on the same model: an order by
  /// amountMinor descending.
  CocoonQuery<Txn> missingOrderQuery(Cocoon db) =>
      db.collectionGroup(txns).orderBy(txnAmountMinor, descending: true);

  /// The physical indexes on the txn table, by name.
  Future<Set<String>> indexNames(Cocoon db) async {
    final rows = await db.executor.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'txn'",
    );
    return {for (final row in rows) row['name']! as String};
  }

  group('the default (throwError)', () {
    test('throws the MissingIndexException with its Fix: line', () async {
      final db = await openDatabase();
      await expectLater(
        missingEqualityQuery(db).get(),
        throwsA(
          isA<MissingIndexException>()
              .having(
                (error) => error.fixCommand,
                'fixCommand',
                'dart run cocoon_generator:index add Txn amountMinor',
              )
              .having(
                (error) => error.message.split('\n').last,
                'last line',
                'Fix: dart run cocoon_generator:index add Txn amountMinor '
                    '(writes @Indexed() on amountMinor)',
              ),
        ),
      );
      expect(db.missingIndexes, isEmpty);
    });
  });

  group('scanAndWarn (asserts are on under dart test)', () {
    test('runs the query as a full scan, like allowFullScan', () async {
      final docs = [txn(20240101, 100), txn(20240102, 250), txn(20240103, 100)];
      final scanned = await openDatabase(
        options: const CocoonOptions(
          onMissingIndex: MissingIndexMode.scanAndWarn,
        ),
      );
      await seed(scanned, docs);
      final allowScan = await openDatabase();
      await seed(allowScan, docs);

      final ids = (await missingEqualityQuery(
        scanned,
      ).get()).docs.map((snapshot) => snapshot.id).toList();
      final allowed = (await missingEqualityQuery(
        allowScan,
      ).allowFullScan().get()).docs.map((snapshot) => snapshot.id).toList();
      expect(ids, allowed);
      expect(ids, ['t0', 't2']);
    });

    test('records one report per distinct missing index', () async {
      final db = await openDatabase(
        options: const CocoonOptions(
          onMissingIndex: MissingIndexMode.scanAndWarn,
        ),
      );
      await seed(db, [txn(20240101, 100), txn(20240102, 250)]);
      await missingEqualityQuery(db).get();
      await missingEqualityQuery(db).get();
      await missingOrderQuery(db).get();

      final reports = db.missingIndexes;
      expect(reports, hasLength(2));
      expect(reports.map((report) => report.fixCommand), [
        'dart run cocoon_generator:index add Txn amountMinor',
        'dart run cocoon_generator:index add Txn -amountMinor',
      ]);
      final first = reports.first;
      expect(first.model, 'Txn');
      expect(first.fields, ['amountMinor']);
      expect(first.query, 'where amountMinor ==');
      expect(
        first.fixCommand,
        'dart run cocoon_generator:index add Txn amountMinor',
      );
      expect(DateTime.now().difference(first.firstSeen).inMinutes, lessThan(1));
      expect(
        first.toString(),
        'Txn: amountMinor (where amountMinor ==). '
        'Fix: dart run cocoon_generator:index add Txn amountMinor',
      );

      // The list is read-only: the engine owns it.
      expect(
        () => (reports as List).add(first),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('allowFullScan queries record nothing', () async {
      final db = await openDatabase(
        options: const CocoonOptions(
          onMissingIndex: MissingIndexMode.scanAndWarn,
        ),
      );
      await seed(db, [txn(20240101, 100)]);
      await missingEqualityQuery(db).allowFullScan().get();
      expect(db.missingIndexes, isEmpty);
    });

    test('never creates an index', () async {
      final db = await openDatabase(
        options: const CocoonOptions(
          onMissingIndex: MissingIndexMode.scanAndWarn,
        ),
      );
      await seed(db, [txn(20240101, 100)]);
      final before = await indexNames(db);
      await missingEqualityQuery(db).get();
      await missingOrderQuery(db).get();
      expect(await indexNames(db), before);
      expect(db.missingIndexes, isNotEmpty);
    });
  });

  group('a build without asserts (the release behaviour)', () {
    // Locates the package root (the directory whose pubspec.yaml is
    // cocoon's) so the fixture subprocess resolves the same package.
    String packageRoot() {
      var current = Directory.current;
      while (true) {
        final pubspec = File('${current.path}/pubspec.yaml');
        if (pubspec.existsSync() &&
            pubspec.readAsStringSync().startsWith('name: cocoon\n')) {
          return current.path;
        }
        final parent = current.parent;
        if (parent.path == current.path) {
          throw StateError(
            'pubspec.yaml of package:cocoon not found upwards '
            'from ${Directory.current.path}',
          );
        }
        current = parent;
      }
    }

    /// Runs [mode] of `test/fixtures/missing_index_fixture.dart` in a
    /// subprocess: [enableAsserts] decides between the debug behaviour
    /// (`dart run --enable-asserts`) and the release behaviour (plain
    /// `dart run`, asserts off). Returns (stdout lines, stderr).
    Future<(List<String>, String)> spawnFixture(
      String mode, {
      required bool enableAsserts,
    }) async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          if (enableAsserts) '--enable-asserts',
          'test/fixtures/missing_index_fixture.dart',
          mode,
        ],
        workingDirectory: packageRoot(),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(
        result.exitCode,
        0,
        reason: 'fixture failed:\n${result.stdout}\n${result.stderr}',
      );
      return (
        result.stdout.toString().split('\n')..removeWhere((l) => l.isEmpty),
        result.stderr.toString(),
      );
    }

    test('scanAndWarn throws like the default', () async {
      final (lines, stderr) = await spawnFixture(
        'release',
        enableAsserts: false,
      );
      expect(lines, contains('RESULT threw'));
      expect(lines, contains('REPORTS 0'));
      // No fallback warning in a release build: the query threw instead.
      // (The subprocess stderr also carries `dart run` build-hook noise
      // without a trailing newline, so count markers, not lines.)
      expect('[cocoon]'.allMatches(stderr), isEmpty);
    });

    test(
      'with asserts the scan runs and warns once per missing index',
      () async {
        final (lines, stderr) = await spawnFixture('warn', enableAsserts: true);
        // The same missing index twice: two scans, one report, one warning.
        expect(lines.where((line) => line == 'RESULT scanned:2'), hasLength(2));
        expect(lines, contains('REPORTS 1'));
        // The warning prints once, message plus its Fix: line, on stderr —
        // after `dart run` build-hook noise without a trailing newline, so
        // count markers rather than lines.
        expect('[cocoon]'.allMatches(stderr), hasLength(1));
        expect(
          'Fix: dart run cocoon_generator:index add Txn amountMinor'.allMatches(
            stderr,
          ),
          hasLength(1),
        );
      },
    );
  });
}
