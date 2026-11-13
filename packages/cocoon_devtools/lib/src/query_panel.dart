/// The query runner: pick a collection, add filters and orders from the
/// collection's indexed fields, run read-only, and read the plan as plain
/// words.
library;

import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'models.dart';
import 'widgets.dart';

/// The query panel of the inspector.
///
/// A query is either scoped to a concrete collection path (typed into the
/// parent-path field when the pattern has parameters) or a collection-group
/// query over every parent. Filter and order fields come from the
/// collection's indexed columns plus its path params, the same names the
/// app side accepts. The result shows the rows, the plain-words plan
/// verdict and, folded away, the SQL and `EXPLAIN QUERY PLAN` text.
class QueryPanel extends StatefulWidget {
  const QueryPanel({
    super.key,
    required this.api,
    required this.databaseId,
    required this.collections,
  });

  /// The API to call the inspected app with.
  final CocoonInspectorApi api;

  /// The database to query.
  final String databaseId;

  /// The collections registered on the database.
  final List<CollectionInfo> collections;

  @override
  State<QueryPanel> createState() => _QueryPanelState();
}

class _QueryPanelState extends State<QueryPanel> {
  int _collectionIndex = 0;
  final _parentController = TextEditingController();
  bool _group = false;
  bool _fullScan = false;
  final _limitController = TextEditingController(text: '50');
  final List<_FilterRow> _filters = [];
  final List<_OrderRow> _orders = [];
  bool _running = false;
  QueryOutcome? _outcome;
  Object? _error;

  CollectionInfo get _collection {
    final collections = widget.collections;
    if (_collectionIndex >= collections.length) {
      _collectionIndex = 0;
    }
    return collections.isEmpty
        ? const CollectionInfo(
            model: '',
            pattern: '',
            table: '',
            documentCount: 0,
            columns: [],
            indexes: [],
          )
        : collections[_collectionIndex];
  }

  /// The field names the query runner offers: path params plus indexed
  /// columns — the names the app side validates against.
  List<CollectionColumn> get _queryableFields => [
    for (final param in _collection.params)
      CollectionColumn(name: param, type: 'text', nullable: false),
    ..._collection.columns,
  ];

  /// The field names that may appear in `orders`: params plus non-nullable,
  /// non-blob columns — the sort rules `CocoonQuery.orderBy` enforces.
  List<CollectionColumn> get _sortableFields => _queryableFields
      .where((field) => !field.nullable && field.type != 'blob')
      .toList();

  @override
  void didUpdateWidget(covariant QueryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.databaseId != widget.databaseId) {
      setState(() {
        _collectionIndex = 0;
        _filters.clear();
        _orders.clear();
        _outcome = null;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _parentController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final collection = _collection;
    if (collection.pattern.isEmpty) {
      return;
    }
    QueryScope scope;
    try {
      scope = _scopeOf(collection);
    } on Object catch (error) {
      setState(() {
        _error = error;
        _outcome = null;
      });
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final outcome = await widget.api.runQuery(
        databaseId: widget.databaseId,
        scope: scope,
        filters: [
          for (final row in _filters)
            QueryFilterSpec(
              field: row.field,
              op: row.op,
              value: parseQueryValue(row.valueText),
              values: [
                if (row.op == listValueOp)
                  for (final part in row.valueText.split(','))
                    parseQueryValue(part),
              ],
            ),
        ],
        orders: [
          for (final row in _orders)
            QueryOrderSpec(field: row.field, descending: row.descending),
        ],
        limit: int.tryParse(_limitController.text.trim()) ?? 50,
        fullScan: _fullScan,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _outcome = outcome;
        _running = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _running = false;
      });
    }
  }

  /// The scope the panel sends: a collection-group query when the toggle is
  /// on, otherwise the concrete path the pattern plus parent path build.
  ///
  /// A pattern with parameters needs every parent id, so the parent-path
  /// field must carry them (e.g. `accounts/a1` for
  /// `accounts/{accountId}/txns`).
  QueryScope _scopeOf(CollectionInfo collection) {
    if (_group) {
      return QueryScope.group(collection.pattern);
    }
    final patternSegments = collection.pattern.split('/');
    final parents = _parentController.text
        .trim()
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    final missing = patternSegments.length - 1 - parents.length;
    if (missing > 0) {
      throw ArgumentError(
        'The pattern ${collection.pattern} needs ${patternSegments.length - 1} '
        'parent path segments; the parent field has ${parents.length}.',
      );
    }
    return QueryScope.collection([...parents, patternSegments.last].join('/'));
  }

  @override
  Widget build(BuildContext context) {
    final collection = _collection;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Row(
            children: [
              const Text('Collection'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _collectionIndex < widget.collections.length
                    ? _collectionIndex
                    : 0,
                items: [
                  for (var i = 0; i < widget.collections.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${widget.collections[i].model} (${widget.collections[i].pattern})',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _collectionIndex = value ?? 0;
                  _filters.clear();
                  _orders.clear();
                  _outcome = null;
                }),
              ),
              const SizedBox(width: 16),
              Tooltip(
                message:
                    'Run over every parent of the pattern instead of '
                    'one concrete collection path.',
                child: CheckboxListTile(
                  title: const Text('Collection group'),
                  value: _group,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (value) => setState(() => _group = value ?? false),
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Run'),
              ),
            ],
          ),
          if (!_group && _collection.params.isNotEmpty)
            TextField(
              controller: _parentController,
              decoration: InputDecoration(
                labelText: 'Parent path',
                hintText: _parentHint(collection),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          _filtersCard(),
          _ordersCard(),
          Row(
            children: [
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _limitController,
                  decoration: const InputDecoration(
                    labelText: 'Limit',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Tooltip(
                message:
                    'Opt out of the index rule: run even when no index '
                    'serves the query (a full scan).',
                child: CheckboxListTile(
                  title: const Text('Allow full scan'),
                  value: _fullScan,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (value) =>
                      setState(() => _fullScan = value ?? false),
                ),
              ),
            ],
          ),
          if (_error != null)
            SelectableText(
              '$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_running) const Center(child: CircularProgressIndicator()),
          if (_outcome != null) _outcomeView(),
        ],
      ),
    );
  }

  String _parentHint(CollectionInfo collection) => collection.pattern
      .split('/')
      .sublist(0, collection.pattern.split('/').length - 1)
      .join('/');

  Widget _filtersCard() {
    final fields = _queryableFields;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              children: [
                Text('Filters', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: 'Add a filter',
                  icon: const Icon(Icons.add),
                  onPressed: fields.isEmpty
                      ? null
                      : () => setState(() => _filters.add(_FilterRow())),
                ),
              ],
            ),
            if (_filters.isEmpty)
              Text(
                'No filters: the query runs over the whole collection.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            for (final row in _filters)
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: row.field,
                      decoration: const InputDecoration(
                        labelText: 'Field',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final field in fields)
                          DropdownMenuItem(
                            value: field.name,
                            child: Text(
                              field.mirrored
                                  ? '${field.name} (mirrored)'
                                  : field.name,
                            ),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => row.field = value ?? ''),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButtonFormField<String>(
                    initialValue: row.op,
                    decoration: const InputDecoration(
                      labelText: 'Op',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final op in filterOpNames)
                        DropdownMenuItem(value: op, child: Text(_opLabel(op))),
                    ],
                    onChanged: (value) =>
                        setState(() => row.op = value ?? 'equal'),
                  ),
                  const SizedBox(width: 8),
                  if (!valuelessOps.contains(row.op))
                    Expanded(
                      child: TextFormField(
                        initialValue: row.valueText,
                        decoration: InputDecoration(
                          labelText: row.op == listValueOp
                              ? 'Values (comma separated)'
                              : 'Value',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          helperText:
                              'null, true, false, number, or text '
                              '(DateTime: UTC microseconds)',
                        ),
                        onChanged: (value) => row.valueText = value,
                      ),
                    ),
                  IconButton(
                    tooltip: 'Remove this filter',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _filters.remove(row)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _ordersCard() {
    final fields = _sortableFields;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              children: [
                Text('Order by', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: 'Add a sort key',
                  icon: const Icon(Icons.add),
                  onPressed: fields.isEmpty
                      ? null
                      : () => setState(() => _orders.add(_OrderRow())),
                ),
              ],
            ),
            if (_orders.isEmpty)
              Text(
                'No explicit order: results come back in index order, '
                'documents by path last.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            for (final row in _orders)
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: row.field,
                      decoration: const InputDecoration(
                        labelText: 'Field',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final field in fields)
                          DropdownMenuItem(
                            value: field.name,
                            child: Text(
                              field.mirrored
                                  ? '${field.name} (mirrored)'
                                  : field.name,
                            ),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => row.field = value ?? ''),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CheckboxListTile(
                    title: const Text('Descending'),
                    value: row.descending,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (value) =>
                        setState(() => row.descending = value ?? false),
                  ),
                  IconButton(
                    tooltip: 'Remove this sort key',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _orders.remove(row)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _outcomeView() {
    final outcome = _outcome!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            switch (outcome) {
              QuerySucceeded() => PlanVerdictView(verdict: outcome.verdict),
              QueryRefused() => PlanVerdictView(verdict: outcome.verdict),
            },
            if (outcome is QueryRefused)
              SelectableText(
                outcome.message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (outcome is QuerySucceeded) _rowsView(outcome),
            ExpansionTile(
              title: const Text('Query plan'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('SQL'),
                      _monospace(outcome is QuerySucceeded ? outcome.sql : ''),
                      const Text('EXPLAIN QUERY PLAN'),
                      _monospace(
                        outcome is QuerySucceeded ? outcome.explain : '',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowsView(QuerySucceeded succeeded) {
    if (succeeded.rows.isEmpty) {
      return const Text('No documents matched.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${succeeded.rowCount} document(s)'),
        const SizedBox(height: 8),
        for (final row in succeeded.rows)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              row.path,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: JsonMapView(fields: row.json),
              ),
            ],
          ),
      ],
    );
  }

  Widget _monospace(String text) => text.isEmpty
      ? const SizedBox.shrink()
      : Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 4, bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        );
}

/// One filter row the user edits.
class _FilterRow {
  String field = '';
  String op = 'equal';
  String valueText = '';
}

/// One order row the user edits.
class _OrderRow {
  String field = '';
  bool descending = false;
}

/// The friendly label of a filter operator name.
String _opLabel(String op) => switch (op) {
  'equal' => '=',
  'notEqual' => '!=',
  'less' => '<',
  'lessEqual' => '<=',
  'greater' => '>',
  'greaterEqual' => '>=',
  'inList' => 'IN (…)',
  'isNull' => 'IS NULL',
  'isNotNull' => 'IS NOT NULL',
  _ => op,
};
