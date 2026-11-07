/// The schema view: the stored schema version, the schema lock (field
/// numbers, reserved numbers, indexes) and the live SQL tables.
library;

import 'package:flutter/material.dart';

import 'api.dart';
import 'models.dart';

/// The schema panel of the inspector.
///
/// Shows what the engine knows live (tables, columns, indexes, row counts,
/// shape hashes) next to what the lock pins (per-model field numbers and
/// reserved numbers). When the app opened without a lock, the lock section
/// says so instead of pretending.
class SchemaPanel extends StatefulWidget {
  const SchemaPanel({super.key, required this.api, required this.databaseId});

  /// The API to call the inspected app with.
  final CocoonInspectorApi api;

  /// The database to read the schema of.
  final String databaseId;

  @override
  State<SchemaPanel> createState() => _SchemaPanelState();
}

class _SchemaPanelState extends State<SchemaPanel> {
  SchemaReport? _report;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SchemaPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.databaseId != widget.databaseId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.api.schema(widget.databaseId);
      if (!mounted) {
        return;
      }
      setState(() {
        _report = report;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.all(12), child: _body());
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            '$_error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    final report = _report;
    if (report == null) {
      return const SizedBox.shrink();
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          Row(
            children: [
              Text('Schema', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 12),
              if (report.schemaVersion != null)
                Chip(label: Text('version ${report.schemaVersion}'))
              else
                const Text(
                  'No schema version stored (the file predates locks).',
                ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _lockSection(report),
          const SizedBox(height: 16),
          for (final table in report.tables) ...[
            _tableCard(table),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  /// The committed lock: per model, the field numbers, the reserved (never
  /// reused) numbers and the declared index field lists.
  Widget _lockSection(SchemaReport report) {
    final lock = report.lock;
    if (lock == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'The app opened without a schema lock, so pinned field numbers '
            'and reserved numbers are not available. Pass the parsed '
            'cocoon.lock.json to Cocoon.open to see them here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    final collections = lock['collections'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text('Schema lock', style: Theme.of(context).textTheme.titleSmall),
            if (collections is! Map<String, Object?> || collections.isEmpty)
              const Text('The lock registers no collections.')
            else
              for (final entry in collections.entries)
                _lockModel(entry.key, entry.value),
          ],
        ),
      ),
    );
  }

  Widget _lockModel(String model, Object? spec) {
    if (spec is! Map<String, Object?>) {
      return Text('$model: (unreadable lock entry)');
    }
    final fields = spec['fields'];
    final reserved = spec['reserved'];
    final indexes = spec['indexes'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(model, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (fields is Map<String, Object?>)
            for (final field in fields.entries)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Builder(
                  builder: (context) {
                    final value = field.value;
                    final number = value is Map<String, Object?>
                        ? value['number']
                        : '?';
                    final type = value is Map<String, Object?>
                        ? value['type']
                        : '?';
                    return Text('field $number: ${field.key} ($type)');
                  },
                ),
              ),
          if (reserved is List<Object?> && reserved.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                'reserved (never reused): ${reserved.join(', ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (indexes is List<Object?> && indexes.isNotEmpty)
            for (final index in indexes)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  'Index([${index is List<Object?> ? index.join(', ') : '?'}])',
                ),
              ),
        ],
      ),
    );
  }

  Widget _tableCard(TableInfo table) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${table.table} — ${table.model}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text('${table.rowCount} rows'),
              ],
            ),
            Text(
              '${table.pattern}${table.exists ? '' : ' — table not created yet'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'shape hash ${table.shapeHash}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (table.columns.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final column in table.columns)
                    Tooltip(
                      message: column.isPrimaryKey
                          ? 'primary key'
                          : (column.notNull ? 'NOT NULL' : 'nullable'),
                      child: Chip(
                        label: Text(
                          '${column.name}: ${column.type}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
            if (table.indexes.isNotEmpty)
              for (final index in table.indexes)
                Text(
                  '${index.unique ? 'UNIQUE ' : ''}index ${index.name}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            if (table.sql != null)
              ExpansionTile(
                title: const Text('CREATE TABLE'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      table.sql!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
