/// The isolate-mode benchmark CLI: one process measures one operation in
/// one isolate mode over the same seeded database file, so peak RSS never
/// leaks between runs.
///
/// ```sh
/// dart run bin/isolate_bench.dart --role seed --size 10000
/// dart run bin/isolate_bench.dart --mode background --op page --size 10000
/// ```
///
/// The last stdout line is the JSON result. See
/// `tool/run_isolate_bench.sh` for the full table and
/// `lib/isolate_bench.dart` for the measurement itself.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_bench/isolate_bench.dart';

/// The seeded database file for one size (the runner seeds each size once
/// and every mode measures over the same file).
String seedPath(int size) =>
    '${Platform.environment['TMPDIR'] ?? '/tmp'}'
    '/cocoon_isolate_bench/size_$size/cocoon.db';

Future<void> main(List<String> args) async {
  String? role;
  CocoonIsolate? mode;
  String? op;
  var size = 0;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--role':
        role = args[++i];
      case '--mode':
        mode = CocoonIsolate.values.byName(args[++i]);
      case '--op':
        op = args[++i];
      case '--size':
        size = int.parse(args[++i]);
      default:
        stderr.writeln('Unknown argument ${args[i]}');
        exit(2);
    }
  }
  if (size <= 0) {
    stderr.writeln('--size is required (documents in the seeded scope)');
    exit(2);
  }
  if (role == 'seed') {
    final sw = Stopwatch()..start();
    await seedScope(seedPath(size), size);
    sw.stop();
    stdout.writeln(
      jsonEncode({
        'role': 'seed',
        'size': size,
        'seedMs': sw.elapsedMilliseconds,
      }),
    );
    return;
  }
  if (mode == null || op == null) {
    stderr.writeln(
      'Usage: dart run bin/isolate_bench.dart --role seed --size N\n'
      '       dart run bin/isolate_bench.dart --mode caller|background|auto '
      '--op page|group|import|latency|writes|mixed --size N',
    );
    exit(2);
  }
  final result = await runIsolateOp(
    mode: mode,
    op: op,
    size: size,
    path: seedPath(size),
  );
  stdout.writeln(
    jsonEncode({
      'engine': 'cocoon-${result.mode}',
      'size': size,
      'op': result.op,
      'wallMs': result.wallMs.toStringAsFixed(1),
      'longestStallMs': result.longestStallMs.toStringAsFixed(1),
      'totalStallMs': result.totalStallMs.toStringAsFixed(1),
      'stallsOver8ms': result.stallsOver8ms,
      'peakRssBytes': ProcessInfo.maxRss,
      'rssAtEndBytes': ProcessInfo.currentRss,
      ...result.extra,
    }),
  );
}
