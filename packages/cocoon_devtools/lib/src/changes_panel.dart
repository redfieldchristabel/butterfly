/// The live change feed: every committed write the inspected app makes,
/// streamed as `cocoon:changes` events, filterable by collection and
/// pausable.
library;

import 'package:material_ui/material_ui.dart';

import 'models.dart';

/// The changes panel of the inspector.
///
/// The feed listens to a [ValueNotifier] the app owns (one subscription to
/// the VM service's Extension events, surviving tab switches), shows the
/// newest commits first and can pause, resume and clear. Pausing freezes
/// the view; new commits keep streaming into the notifier and appear when
/// resumed. Rows can be filtered down to one collection model.
class ChangesPanel extends StatefulWidget {
  const ChangesPanel({
    super.key,
    required this.feed,
    required this.collections,
  });

  /// The committed changes, newest first, appended by the app.
  final ValueNotifier<List<ChangeRecord>> feed;

  /// The collections registered on the selected database, for the filter.
  final List<CollectionInfo> collections;

  @override
  State<ChangesPanel> createState() => _ChangesPanelState();
}

class _ChangesPanelState extends State<ChangesPanel> {
  String? _collectionFilter;
  bool _paused = false;
  List<ChangeRecord> _frozen = const [];
  bool _showDeleteOnly = false;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_onFeed);
  }

  @override
  void didUpdateWidget(covariant ChangesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed.removeListener(_onFeed);
      widget.feed.addListener(_onFeed);
    }
  }

  @override
  void dispose() {
    widget.feed.removeListener(_onFeed);
    super.dispose();
  }

  void _onFeed() {
    if (!_paused) {
      setState(() {});
    }
  }

  /// The rows to show, newest first, filtered by collection.
  List<ChangeRecord> get _rows {
    final all = _paused ? _frozen : widget.feed.value;
    return [
      for (final change in all)
        if ((_collectionFilter == null ||
                change.collection == _collectionFilter) &&
            (!_showDeleteOnly || change.op == 'delete'))
          change,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final models = {
      for (final collection in widget.collections) collection.model,
    }.toList()..sort();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Row(
            children: [
              const Text('Collection'),
              const SizedBox(width: 8),
              DropdownButton<String?>(
                value: _collectionFilter,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All collections'),
                  ),
                  for (final model in models)
                    DropdownMenuItem<String?>(value: model, child: Text(model)),
                ],
                onChanged: (value) => setState(() => _collectionFilter = value),
              ),
              const SizedBox(width: 16),
              FilterChip(
                label: const Text('Deletes only'),
                selected: _showDeleteOnly,
                onSelected: (value) => setState(() => _showDeleteOnly = value),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: () {
                  setState(() {
                    if (_paused) {
                      _paused = false;
                    } else {
                      _frozen = widget.feed.value;
                      _paused = true;
                    }
                  });
                },
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                label: Text(_paused ? 'Resume' : 'Pause'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  _frozen = const [];
                  widget.feed.value = const [];
                  setState(() {});
                },
                child: const Text('Clear'),
              ),
            ],
          ),
          if (_paused)
            Text(
              'Paused — new commits are streaming in and appear on resume.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Expanded(child: _rowsView()),
        ],
      ),
    );
  }

  Widget _rowsView() {
    final rows = _rows;
    if (rows.isEmpty) {
      return Text(
        _paused
            ? 'Nothing matched while paused.'
            : 'No committed changes yet. Write to the database from the app '
                  'and commits appear here.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final change = rows[index];
        final isDelete = change.op == 'delete';
        return ListTile(
          dense: true,
          leading: Icon(
            isDelete ? Icons.delete_outline : Icons.edit_outlined,
            size: 18,
            color: isDelete ? Theme.of(context).colorScheme.error : null,
          ),
          title: Text(
            change.path,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          subtitle: Text('${change.collection} — ${_timeOf(change.at)}'),
          trailing: Text(
            isDelete ? 'delete' : 'set',
            style: TextStyle(
              fontSize: 12,
              color: isDelete ? Theme.of(context).colorScheme.error : null,
            ),
          ),
        );
      },
    );
  }

  /// The commit time as a short local clock time.
  String _timeOf(String at) {
    final parsed = DateTime.tryParse(at);
    if (parsed == null) {
      return at;
    }
    final local = parsed.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }
}
