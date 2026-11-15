import 'dart:async';
import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

/// The isolate mode the test suite runs its file-backed opens in, from the
/// `COCOON_TEST_ISOLATE` environment variable: `background` or `auto` move
/// every [openCocoon] to that mode; unset (or anything else) is the default
/// caller mode — today's behaviour, byte for byte.
///
/// `COCOON_TEST_ISOLATE=background dart test` (or `=auto`) runs the whole
/// suite against the isolate plumbing; the gate runs all three modes (see
/// `tool/test_all_modes.sh`).
CocoonIsolate get testIsolateMode {
  final raw = Platform.environment['COCOON_TEST_ISOLATE'] ?? '';
  return switch (raw) {
    'background' => CocoonIsolate.background,
    'auto' => CocoonIsolate.auto,
    _ => CocoonIsolate.caller,
  };
}

/// [Cocoon.open] with [options]' isolate mode replaced by the suite's
/// `COCOON_TEST_ISOLATE` mode (default [CocoonIsolate.caller]).
///
/// The same arguments as [Cocoon.open]; in background and auto mode the
/// options are rebuilt with [CocoonOptions.isolate] set, everything else
/// untouched. Callbacks never cross an isolate boundary on their own: the
/// engine delivers migration progress and compaction failures as events on
/// the isolate that called [openCocoon], so the callbacks keep working.
Future<Cocoon> openCocoon(
  String path, {
  required List<CollectionAdapter<Object?>> collections,
  CocoonOptions options = const CocoonOptions(),
  int? schemaVersion,
  List<CocoonMigration> migrations = const [],
  void Function(int done, int total)? onMigrationProgress,
  SchemaLock? schemaLock,
}) {
  final mode = testIsolateMode;
  final effective = mode == CocoonIsolate.caller
      ? options
      : CocoonOptions(
          durability: options.durability,
          cacheSize: options.cacheSize,
          keepChanges: options.keepChanges,
          changeRetention: options.changeRetention,
          pageCacheMiB: options.pageCacheMiB,
          tempStoreInMemory: options.tempStoreInMemory,
          walAutoCheckpointPages: options.walAutoCheckpointPages,
          compactAfterUpgrade: options.compactAfterUpgrade,
          onCompactionFailed: options.onCompactionFailed,
          onMissingIndex: options.onMissingIndex,
          isolate: mode,
          autoThresholds: options.autoThresholds,
        );
  return Cocoon.open(
    path,
    collections: collections,
    options: effective,
    schemaVersion: schemaVersion,
    migrations: migrations,
    onMigrationProgress: onMigrationProgress,
    schemaLock: schemaLock,
  );
}

/// Waits until [db]'s auto-mode helper isolate has attached, failing after
/// [timeout]. Auto mode's open returns before the helper is ready (the
/// spawn runs in the background), so tests that assert helper routing or
/// the helper counters poll for [CocoonHelperState.ready] first.
Future<void> waitHelperReady(
  Cocoon db, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final stats = db.isolateStats;
    if (stats != null && stats.helperState == CocoonHelperState.ready) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'the auto helper never became ready '
    '(state: ${db.isolateStats?.helperState})',
  );
}
