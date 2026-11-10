import 'package:cocoon_devtools/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The storage view model against the built-in preview payloads: the wire
/// shape a future `ext.cocoon.storage` handler must return, the segment math
/// the Storage tab renders, the bulk-load states, and the formatting
/// helpers. The expected numbers are the committed benchmark figures
/// (`benchmarks/cocoon_rivals/STORAGE.md` Part A, RESULTS.md's 425.8 MB
/// file row); when either side drifts, these tests fail.
void main() {
  group('StorageReport preview payloads', () {
    test('the idle preview parses and round-trips through toJson', () {
      final json = StorageReport.previewIdleJson();
      final report = StorageReport.fromJson(json);
      expect(report.file.dbBytes, 99875 * 4096);
      expect(report.file.pageCount, 99875);
      expect(report.file.pageSize, 4096);
      expect(report.file.walBytes, 9117 * 4096);
      expect(report.file.totalBytes, 99875 * 4096 + 9117 * 4096);
      expect(report.file.reclaimableBytes, 0);
      expect(report.bulkLoad, BulkLoadReport.idle);
      final txn = report.collections.single;
      expect(txn.model, 'Txn');
      expect(txn.pattern, 'accounts/{accountId}/txns');
      expect(txn.table, 'txn');
      expect(txn.documentCount, 1000025);
      expect(txn.pathIndex!.name, 'sqlite_autoindex_txn_1');
      expect(txn.scopeIndex!.name, 'cx_txn_scope');
      expect(txn.indexes, hasLength(4));
      expect(report.changeLog.rows, 1000690);
      // The wire shape is the contract: encoding back gives the same JSON
      // and re-parsing gives the same model.
      expect(report.toJson(), json);
      expect(StorageReport.fromJson(report.toJson()), report);
    });

    test('numbers reproduce the committed benchmark figures', () {
      final report = StorageReport.previewIdle();
      // RESULTS.md's File size row: the open file plus its un-checkpointed
      // WAL, in the benchmark's MB = 1024² convention.
      expect(formatBytes(report.file.totalBytes), '425.8 MB');
      expect(formatBytes(report.file.dbBytes), '390.1 MB');
      expect(formatBytes(report.file.walBytes), '35.6 MB');
      final txn = report.collections.single;
      expect(formatBytes(txn.totalBytes), '390.1 MB');
      expect(formatBytes(txn.tableBytes), '158.1 MB');
      expect(formatBytes(txn.pathIndex!.bytes), '39.4 MB');
      expect(formatBytes(txn.scopeIndex!.bytes), '24.8 MB');
      expect(formatBytes(txn.changeLogBytes), '52.2 MB');
      expect(formatBytes(report.changeLog.bytes), '52.2 MB');
      final sizes = [for (final index in txn.indexes) formatBytes(index.bytes)];
      expect(sizes, ['29.6 MB', '34.7 MB', '27.0 MB', '24.2 MB']);
    });

    test('the active-bulk-load preview parses with deferred indexes', () {
      final report = StorageReport.previewBulkLoad();
      expect(report.bulkLoad.active, isTrue);
      expect(report.bulkLoad.rowsCommitted, 800000);
      expect(report.bulkLoad.rowsQueued, 200000);
      expect(report.bulkLoad.progress, 0.8);
      expect(report.bulkLoad.chunkSize, 10000);
      expect(report.bulkLoad.deferredIndexes, hasLength(4));
      expect(report.bulkLoad.waitingQueries, 2);
      // A deferred index is not in the file: no pages, and no segment.
      for (final index in report.collections.single.indexes) {
        expect(index.state, StorageIndexState.deferred);
        expect(index.bytes, 0);
      }
      expect(formatBytes(report.file.totalBytes), '251.0 MB');
      expect(formatBytes(report.file.dbBytes), '220.0 MB');
      expect(formatBytes(report.file.reclaimableBytes), '384 KB');
      expect(report.changeLog.rows, 800000);
    });

    test('a wrong shape throws a FormatException naming the piece', () {
      expect(() => StorageReport.fromJson('nope'), throwsFormatException);
      expect(() => StorageReport.fromJson({'file': 3}), throwsFormatException);
      expect(
        () => StorageReport.fromJson({'file': null}),
        throwsFormatException,
      );
    });
  });

  group('segments', () {
    test('sorted by size, zero-byte objects dropped', () {
      final report = StorageReport.previewIdle();
      final segments = storageSegments(report.collections.single, report);
      expect(segments.map((segment) => segment.label), [
        'Documents',
        'Change log',
        'Path index',
        'Index: status, booked on',
        'Index: account, newest first',
        'Index: booked on',
        'Scope (account, id)',
        'Index: amount minor',
      ]);
    });

    test(
      'a deferred index produces no segment while it is not in the file',
      () {
        final loading = StorageReport.previewBulkLoad();
        final segments = storageSegments(loading.collections.single, loading);
        expect(
          segments.where(
            (segment) => segment.kind == StorageSegmentKind.secondary,
          ),
          isEmpty,
        );
        expect(segments.first.kind, StorageSegmentKind.rows);
        expect(
          segments.map((segment) => segment.label),
          contains('Change log'),
        );
      },
    );

    test('share and average bytes per row', () {
      final report = StorageReport.previewIdle();
      final segments = storageSegments(report.collections.single, report);
      final rows = segments.first;
      expect(rows.kind, StorageSegmentKind.rows);
      expect(formatPercent(rows.share), '40.5%');
      expect(formatBytes(rows.avgBytesPerRow), '166 B');
      final log = segments[1];
      expect(log.kind, StorageSegmentKind.changeLog);
      expect(formatPercent(log.share), '13.4%');
      expect(formatBytes(log.avgBytesPerRow), '55 B');
      final path = segments[2];
      expect(path.kind, StorageSegmentKind.pathIndex);
      expect(formatPercent(path.share), '10.1%');
      expect(formatBytes(path.avgBytesPerRow), '41 B');
    });

    test('the change log has its own separate segment', () {
      final report = StorageReport.previewIdle();
      final segment = changeLogSegment(report.changeLog, report.file.dbBytes);
      expect(segment.label, 'Change log');
      expect(segment.sqlName, '_cocoon_changes');
      expect(segment.bytes, report.changeLog.bytes);
      expect(formatPercent(segment.share), '13.4%');
      expect(segment.entries, report.changeLog.rows);
    });
  });

  group('bulk load states', () {
    test('an inactive payload parses to the idle report', () {
      final idle = BulkLoadReport.fromJson({'active': false});
      expect(idle, BulkLoadReport.idle);
      expect(idle.active, isFalse);
      expect(idle.progress, 0);
      expect(idle.toJson(), {'active': false});
    });

    test('an active payload carries the whole progress set', () {
      final json = StorageReport.previewBulkLoadJson()['bulkLoad']!;
      final active = BulkLoadReport.fromJson(json);
      expect(active.active, isTrue);
      expect(active.progress, 0.8);
      expect(active.toJson(), json);
    });

    test('an active payload without its fields throws', () {
      expect(
        () => BulkLoadReport.fromJson({'active': true}),
        throwsFormatException,
      );
      expect(() => BulkLoadReport.fromJson(null), throwsFormatException);
    });
  });

  group('index states', () {
    StorageIndex indexOf(String state) => StorageIndex.fromJson({
      'name': 'cx_txn_0000000000000000',
      'unique': false,
      'parts': const [],
      'bytes': 0,
      'state': state,
    });

    test('known words parse', () {
      expect(indexOf('live').state, StorageIndexState.live);
      expect(indexOf('deferred').state, StorageIndexState.deferred);
      expect(indexOf('rebuilding').state, StorageIndexState.rebuilding);
    });

    test('an unknown word parses as unknown and shows the raw word', () {
      final index = indexOf('reindexing-later');
      expect(index.state, StorageIndexState.unknown);
      expect(index.stateRaw, 'reindexing-later');
      expect(storageIndexStateLabel(index), 'reindexing-later');
      expect(storageIndexStateLabel(indexOf('live')), 'Live');
      expect(
        storageIndexStateLabel(indexOf('deferred')),
        'Deferred by a bulk load',
      );
      expect(storageIndexStateLabel(indexOf('rebuilding')), 'Rebuilding');
    });

    test('human field labels', () {
      StorageIndex index(List<Object?> parts) => StorageIndex.fromJson({
        'name': 'cx_txn_0000000000000000',
        'unique': false,
        'parts': parts,
        'bytes': 0,
        'state': 'live',
      });
      expect(
        index([
          {'name': 'accountId', 'descending': false},
          {'name': 'bookedOn', 'descending': true},
        ]).fieldsLabel,
        'account, newest first',
      );
      expect(
        index([
          {'name': 'status', 'descending': false},
          {'name': 'bookedOn', 'descending': false},
        ]).fieldsLabel,
        'status, booked on',
      );
      expect(
        index([
          {'name': 'amountMinor', 'descending': false},
        ]).fieldsLabel,
        'amount minor',
      );
      // A descending part on a field that is not date-like says so plainly.
      expect(
        index([
          {'name': 'amountMinor', 'descending': true},
        ]).fieldsLabel,
        'amount minor, descending',
      );
    });
  });

  group('formatting helpers', () {
    test('formatBytes uses the benchmark MB convention', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(4096), '4 KB');
      expect(formatBytes(32768), '32 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes(409088000), '390.1 MB');
    });

    test('formatCount groups thousands', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1000025), '1,000,025');
      expect(formatCount(1000690), '1,000,690');
    });

    test('formatPercent and formatElapsed', () {
      expect(formatPercent(0), '0.0%');
      expect(formatPercent(0.4053667), '40.5%');
      expect(formatPercent(1), '100.0%');
      expect(formatElapsed(10400), '10.4 s');
      expect(formatElapsed(65000), '1 m 05 s');
    });
  });
}
