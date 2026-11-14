import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_bench/isolate_bench.dart';
import 'package:test/test.dart';

/// The isolate benchmark's own correctness check: before the measured
/// table in the docs means anything, every mode must answer the same
/// operations over the same seeded file — pages hold every seeded
/// document, group-bys group them, imports land, single gets and writes
/// work, and the mixed run interleaves both. The numbers themselves are
/// environment-dependent; only the invariants are asserted here.
void main() {
  late Directory tempDir;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cocoon_isolate_bench');
    path = '${tempDir.path}/cocoon.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'every mode answers page, latency, writes and mixed over one seed',
    () async {
      const size = 300;
      await seedScope(path, size);
      for (final mode in CocoonIsolate.values) {
        final page = await runIsolateOp(
          mode: mode,
          op: 'page',
          size: size,
          path: path,
        );
        expect(page.wallMs, greaterThan(0));
        expect(page.extra['docs'], size);

        final latency = await runIsolateOp(
          mode: mode,
          op: 'latency',
          size: size,
          path: path,
        );
        expect(latency.extra['gets'], latencyGets);
        expect((latency.extra['p50Us'] as int), greaterThanOrEqualTo(0));

        final writes = await runIsolateOp(
          mode: mode,
          op: 'writes',
          size: size,
          path: path,
        );
        expect(writes.extra['writes'], writesCount);

        final mixed = await runIsolateOp(
          mode: mode,
          op: 'mixed',
          size: size,
          path: path,
        );
        expect(mixed.extra['pages'], writesCount ~/ 50);
      }
    },
  );

  test('group and import run in every mode over the same file', () async {
    const size = 200;
    await seedScope(path, size);
    for (final mode in CocoonIsolate.values) {
      final group = await runIsolateOp(
        mode: mode,
        op: 'group',
        size: size,
        path: path,
      );
      expect(group.extra['rows'], size);

      final imported = await runIsolateOp(
        mode: mode,
        op: 'import',
        size: size,
        path: path,
      );
      expect(imported.extra['docs'], size);
    }
  });
}
