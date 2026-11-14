import 'dart:io';

import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

import 'support/models.dart';
import 'support/open_db.dart';

/// A database that did heavy reads must close without sidecar leftovers.
///
/// In auto mode heavy reads run on a helper isolate's read-only connection.
/// When the database closed while that connection was still attached, SQLite
/// kept the `-wal` beside the file — the last-close cleanup never ran — and
/// the helper, killed rather than closed, never detached its handle either.
/// A `-wal` left behind holds every un-checkpointed page and replays them
/// over whatever main file is later swapped in beside it: a backup restore
/// renames a fresh book over the live path, and the stale `-wal` resurrected
/// the old pages over it. Closing the helper (its connection detached
/// cleanly) before the main connection lets SQLite run its last-close
/// cleanup in every mode.
void main() {
  for (final mode in [
    CocoonIsolate.caller,
    CocoonIsolate.background,
    CocoonIsolate.auto,
  ]) {
    test(
      'close removes the -wal and -shm sidecars after a heavy read '
      '(${mode.name})',
      () async {
        final dir = await Directory.systemTemp.createTemp('cocoon_wal_close');
        addTearDown(() => dir.delete(recursive: true));
        final adapter = AccountAdapter();
        final db = await openCocoon(
          '${dir.path}/t.db',
          collections: [adapter],
          options: CocoonOptions(isolate: mode),
        );
        for (var i = 0; i < 50; i++) {
          await db.collection(adapter).doc('d$i').set(
                Account(name: 'account-$i', active: true, note: 'x' * 200),
              );
        }
        // A limit above the auto threshold: this read runs on the helper's
        // read-only connection in auto mode.
        final page = await db
            .collection(adapter)
            .query()
            .limit(1000)
            .get();
        expect(page.docs, hasLength(50));

        await db.close();

        final leftovers = dir
            .listSync()
            .map((e) => e.uri.pathSegments.last)
            .where((name) => name.endsWith('-wal') || name.endsWith('-shm'))
            .toList();
        expect(leftovers, isEmpty, reason: 'sidecars left after close');
      },
    );
  }
}
