/// The Storage tab (preview): where the database file's bytes go and what a
/// bulk load is doing.
///
/// The live feed is not wired yet — the storage format and the bulk writer
/// are not stable — so the tab renders built-in preview payloads
/// ([StorageReport.previewIdle], [StorageReport.previewBulkLoad], the
/// 1M-transaction rivals benchmark) and a banner says so. A later step wires
/// the `ext.cocoon.storage` service extension; the tab already renders
/// exactly the shape that extension will return.
library;

import 'package:flutter/material.dart';

import 'models.dart';

/// The Storage panel of the inspector, fed by preview data for now.
///
/// Sections: the file (headline footprint, WAL, reclaimable pages, page
/// size), one stacked bar per collection table (rows, path index, scope
/// index, secondary indexes, change-log share — tap a slice or its legend
/// row for bytes, share and average bytes per row), the change log's own
/// row, per-collection indexes with their bulk-load state, and the bulk-load
/// progress (idle, or committed/queued rows, chunk size, deferred indexes,
/// waiting queries, elapsed).
class StoragePanel extends StatefulWidget {
  const StoragePanel({super.key});

  @override
  State<StoragePanel> createState() => _StoragePanelState();
}

class _StoragePanelState extends State<StoragePanel> {
  bool _bulkLoading = false;

  /// The tapped segment's [StorageSegment.key], or `null` for the default
  /// (the largest slice of the first collection).
  String? _selectedKey;

  @override
  Widget build(BuildContext context) {
    final report = _bulkLoading
        ? StorageReport.previewBulkLoad()
        : StorageReport.previewIdle();
    final collections = [...report.collections]
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          _previewBanner(),
          const SizedBox(height: 12),
          _fileCard(report),
          const SizedBox(height: 12),
          _bytesCard(collections, report),
          const SizedBox(height: 12),
          _indexesCard(report),
          const SizedBox(height: 12),
          _bulkLoadCard(report),
        ],
      ),
    );
  }

  Widget _previewBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Row(
            children: [
              Icon(
                Icons.preview,
                size: 18,
                color: Theme.of(context).colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Preview data — this tab is not wired to the inspected app '
                  'yet. The numbers are snapshots of the 1M-transaction '
                  'rivals benchmark; a later step connects the live feed.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('Idle'),
                selected: !_bulkLoading,
                onSelected: (_) => setState(() {
                  _bulkLoading = false;
                  _selectedKey = null;
                }),
              ),
              FilterChip(
                label: const Text('Bulk loading'),
                selected: _bulkLoading,
                onSelected: (_) => setState(() {
                  _bulkLoading = true;
                  _selectedKey = null;
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fileCard(StorageReport report) {
    final file = report.file;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text('File', style: Theme.of(context).textTheme.titleMedium),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  formatBytes(file.totalBytes),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'on disk — database file + WAL',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            _fileRow(
              'Database file',
              '${formatBytes(file.dbBytes)} '
                  '(${formatCount(file.pageCount)} pages × '
                  '${formatBytes(file.pageSize)})',
            ),
            _fileRow('WAL', formatBytes(file.walBytes)),
            _fileRow(
              'Reclaimable',
              '${formatBytes(file.reclaimableBytes)} — free pages a VACUUM '
                  'would give back',
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }

  Widget _bytesCard(List<CollectionStorage> collections, StorageReport report) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              'Where the bytes go',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              'One bar per collection table — its rows, indexes and share of '
              'the change log. Tap a segment for its share.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            for (final collection in collections)
              _collectionBlock(
                collection,
                report,
                defaultDetail: identical(collection, collections.first),
              ),
            _changeLogBlock(report),
          ],
        ),
      ),
    );
  }

  Widget _collectionBlock(
    CollectionStorage collection,
    StorageReport report, {
    required bool defaultDetail,
  }) {
    final segments = storageSegments(collection, report);
    final colors = _segmentColors(segments);
    final selectedKey = _selectedKey;
    final detail = selectedKey == null
        ? (defaultDetail && segments.isNotEmpty ? segments.first : null)
        : () {
            for (var i = 0; i < segments.length; i++) {
              if (segments[i].key == selectedKey) {
                return segments[i];
              }
            }
            return null;
          }();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${collection.model} — ${collection.pattern}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(formatBytes(collection.totalBytes)),
          ],
        ),
        if (segments.isNotEmpty) _bar(segments, colors),
        for (var i = 0; i < segments.length; i++)
          _legendRow(segments[i], colors[i], selectedKey: selectedKey),
        _segmentDetail(detail),
      ],
    );
  }

  Widget _bar(List<StorageSegment> segments, List<Color> colors) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 20,
        child: Row(
          children: [
            for (var i = 0; i < segments.length; i++)
              Expanded(
                flex: segments[i].bytes,
                child: Tooltip(
                  message:
                      '${segments[i].label} — ${formatBytes(segments[i].bytes)}',
                  child: InkWell(
                    onTap: () => setState(() => _selectedKey = segments[i].key),
                    child: ColoredBox(
                      color: colors[i],
                      child: const SizedBox(height: 20, width: double.infinity),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _legendRow(
    StorageSegment segment,
    Color color, {
    required String? selectedKey,
  }) {
    final selected = selectedKey != null && selectedKey == segment.key;
    return InkWell(
      onTap: () => setState(() => _selectedKey = segment.key),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                segment.label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              formatBytes(segment.bytes),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _segmentDetail(StorageSegment? segment) {
    if (segment == null) {
      return const SizedBox.shrink();
    }
    final detail = StringBuffer(
      '${segment.label} — ${formatBytes(segment.bytes)} · '
      '${formatPercent(segment.share)} of the file',
    );
    final avg = segment.avgBytesPerRow;
    if (avg > 0) {
      detail.write(' · ${formatBytes(avg)} per row');
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(detail.toString()),
          if (segment.sqlName != null)
            Text(
              segment.sqlName!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _changeLogBlock(StorageReport report) {
    final segment = changeLogSegment(report.changeLog, report.file.dbBytes);
    final selected = _selectedKey == segment.key;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Change log — one row per written document, per commit',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(formatBytes(report.changeLog.bytes)),
          ],
        ),
        _bar([segment], _segmentColors([segment])),
        _legendRow(
          segment,
          _segmentColors([segment]).single,
          selectedKey: _selectedKey,
        ),
        _segmentDetail(selected ? segment : null),
        Text(
          '${formatCount(report.changeLog.rows)} rows. The log is prunable at '
          'runtime; pruning gives these bytes back without a layout change.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _indexesCard(StorageReport report) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text('Indexes', style: Theme.of(context).textTheme.titleMedium),
            for (final collection in report.collections) ...[
              Text(
                '${collection.model} — ${collection.pattern}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final index in [
                ...collection.indexes,
              ]..sort((a, b) => b.bytes.compareTo(a.bytes)))
                _indexRow(index),
            ],
          ],
        ),
      ),
    );
  }

  Widget _indexRow(StorageIndex index) {
    final colorScheme = Theme.of(context).colorScheme;
    final stateColor = switch (index.state) {
      StorageIndexState.live => colorScheme.onSurfaceVariant,
      StorageIndexState.deferred => Colors.orange.shade800,
      StorageIndexState.rebuilding => colorScheme.primary,
      StorageIndexState.unknown => colorScheme.error,
    };
    return Tooltip(
      message:
          '${index.name}${index.unique ? ' (unique)' : ''} — state '
          '${index.stateRaw}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Index: ${index.fieldsLabel}'),
                  Text(
                    storageIndexStateLabel(index),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: stateColor),
                  ),
                ],
              ),
            ),
            Text(index.bytes > 0 ? formatBytes(index.bytes) : '—'),
          ],
        ),
      ),
    );
  }

  Widget _bulkLoadCard(StorageReport report) {
    final bulk = report.bulkLoad;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              children: [
                Text(
                  'Bulk load',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (bulk.active)
                  Text(
                    formatElapsed(bulk.elapsedMs),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (!bulk.active) ...[
              const Text('No bulk load running.'),
              Text(
                'A db.bulkWriter() load shows its progress here: rows '
                'committed and queued, chunk size, deferred indexes and the '
                'queries waiting for them.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else ...[
              LinearProgressIndicator(value: bulk.progress),
              Text(
                '${formatCount(bulk.rowsCommitted)} of '
                '${formatCount(bulk.rowsCommitted + bulk.rowsQueued)} rows '
                'committed — ${formatCount(bulk.rowsQueued)} queued',
              ),
              Text('Chunks of ${formatCount(bulk.chunkSize)} rows'),
              Text(
                bulk.deferredIndexes.isEmpty
                    ? 'No indexes deferred.'
                    : '${bulk.deferredIndexes.length} '
                          '${bulk.deferredIndexes.length == 1 ? 'index' : 'indexes'} '
                          'deferred while the load runs.',
              ),
              if (bulk.waitingQueries > 0)
                Text(
                  '${bulk.waitingQueries} '
                  '${bulk.waitingQueries == 1 ? 'query waits' : 'queries waiting'} '
                  'for the deferred indexes — they finish when the load does.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (bulk.deferredIndexes.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text(
                    'Deferred indexes (${bulk.deferredIndexes.length})',
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        bulk.deferredIndexes.join('\n'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// One color per segment: fixed hues for the engine objects, a cycling
  /// palette for the secondary indexes, all readable on light and dark.
  List<Color> _segmentColors(List<StorageSegment> segments) {
    var indexOrdinal = 0;
    return [
      for (final segment in segments)
        switch (segment.kind) {
          StorageSegmentKind.rows => const Color(0xFF4E7FE1),
          StorageSegmentKind.pathIndex => const Color(0xFF9C6ADE),
          StorageSegmentKind.scopeIndex => const Color(0xFF3FA7A0),
          StorageSegmentKind.changeLog => const Color(0xFFE8A13D),
          StorageSegmentKind.secondary =>
            _indexColors[indexOrdinal++ % _indexColors.length],
        },
    ];
  }
}

/// Distinct hues for the secondary-index slices.
const List<Color> _indexColors = [
  Color(0xFF59A85F),
  Color(0xFFD97066),
  Color(0xFF4FB6D9),
  Color(0xFFC77FB3),
  Color(0xFF8B8BDF),
  Color(0xFFB0A144),
];
