/// The root app of the Cocoon DevTools extension: connection handling, the
/// database picker and the five panels.
library;

import 'dart:async';

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'changes_panel.dart';
import 'documents_panel.dart';
import 'live.dart';
import 'models.dart';
import 'query_panel.dart';
import 'schema_panel.dart';
import 'storage_panel.dart';

/// How many change rows the feed keeps in memory.
const int _feedCapacity = 500;

/// The Cocoon inspector: browse documents, run typed queries, watch changes
/// live and read the schema of a running debug app.
///
/// The app waits for the DevTools service connection, lists the databases
/// the inspected process opened via the `ext.cocoon.*` service extensions,
/// and shows one tab per capability. It is read-only end to end: nothing in
/// this app writes to the inspected database.
class CocoonInspectorApp extends StatefulWidget {
  const CocoonInspectorApp({super.key});

  @override
  State<CocoonInspectorApp> createState() => _CocoonInspectorAppState();
}

class _CocoonInspectorAppState extends State<CocoonInspectorApp> {
  CocoonInspectorApi? _api;
  List<InspectorDatabase> _databases = const [];
  String? _selectedDatabaseId;
  CollectionListing? _listing;
  Object? _error;
  bool _connecting = false;
  final ValueNotifier<List<ChangeRecord>> _feed = ValueNotifier(const []);
  StreamSubscription<Map<String, Object?>>? _changesSubscription;

  /// The database the panels render.
  InspectorDatabase? get _selected {
    for (final database in _databases) {
      if (database.id == _selectedDatabaseId) {
        return database;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    serviceManager.connectedState.addListener(_onConnectionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onConnectionChanged());
  }

  @override
  void dispose() {
    serviceManager.connectedState.removeListener(_onConnectionChanged);
    _changesSubscription?.cancel();
    _feed.dispose();
    super.dispose();
  }

  void _onConnectionChanged() {
    final connected = serviceManager.connectedState.value.connected;
    if (!connected) {
      _reset(
        'No running application is connected. Run your app in debug or '
        'profile mode with a Cocoon database open, then reopen this tab.',
      );
      return;
    }
    _connect();
  }

  void _reset(String message) {
    _changesSubscription?.cancel();
    _changesSubscription = null;
    setState(() {
      _api = null;
      _databases = const [];
      _selectedDatabaseId = null;
      _listing = null;
      _error = message;
      _connecting = false;
      _feed.value = const [];
    });
  }

  Future<void> _connect() async {
    if (_connecting) {
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await serviceManager.onServiceAvailable;
      final api = liveCocoonInspectorApi();
      final databases = await api.listDatabases();
      _changesSubscription?.cancel();
      _changesSubscription = api.changes.listen(
        _onChanges,
        onError: (Object _) {},
      );
      String? selectedId;
      for (final database in databases) {
        if (database.open) {
          selectedId = database.id;
          break;
        }
      }
      CollectionListing? listing;
      if (selectedId != null) {
        listing = await api.listCollections(selectedId);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _api = api;
        _databases = databases;
        _selectedDatabaseId = selectedId;
        _listing = listing;
        _connecting = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Could not reach the Cocoon inspector extensions: $error';
        _connecting = false;
      });
    }
  }

  /// Appends one committed batch to the feed, newest first.
  void _onChanges(Map<String, Object?> event) {
    final ChangeBatch batch;
    try {
      batch = ChangeBatch.fromJson(event);
    } on FormatException {
      return;
    }
    final value = _feed.value;
    final next = <ChangeRecord>[...batch.changes, ...value];
    _feed.value = next.length <= _feedCapacity
        ? next
        : next.sublist(0, _feedCapacity);
  }

  Future<void> _selectDatabase(String id) async {
    final api = _api;
    if (api == null || id == _selectedDatabaseId) {
      return;
    }
    setState(() {
      _selectedDatabaseId = id;
      _listing = null;
    });
    try {
      final listing = await api.listCollections(id);
      if (!mounted) {
        return;
      }
      setState(() => _listing = listing);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    final api = _api;
    if (api == null) {
      return _messageView();
    }
    final selected = _selected;
    if (selected == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'The app has no Cocoon database open yet. Open one with '
            'Cocoon.open, then reopen this tab.',
          ),
        ),
      );
    }
    final collections = _listing?.collections ?? const <CollectionInfo>[];
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          _header(selected),
          const TabBar(
            tabs: [
              Tab(text: 'Documents'),
              Tab(text: 'Query runner'),
              Tab(text: 'Changes'),
              Tab(text: 'Schema'),
              Tab(text: 'Storage'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                DocumentsPanel(
                  api: api,
                  databaseId: selected.id,
                  collections: collections,
                ),
                QueryPanel(
                  api: api,
                  databaseId: selected.id,
                  collections: collections,
                ),
                ChangesPanel(feed: _feed, collections: collections),
                SchemaPanel(api: api, databaseId: selected.id),
                const StoragePanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(InspectorDatabase selected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          const Icon(Icons.storage, size: 18),
          const SizedBox(width: 6),
          Text('Cocoon', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 16),
          if (_databases.length > 1)
            DropdownButton<String>(
              value: selected.id,
              items: [
                for (final database in _databases)
                  DropdownMenuItem(
                    value: database.id,
                    child: Text(database.label),
                  ),
              ],
              onChanged: (id) {
                if (id != null) {
                  _selectDatabase(id);
                }
              },
            )
          else
            Text(
              selected.path == null
                  ? 'Database ${selected.id} (custom executor)'
                  : selected.path!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const Spacer(),
          if (_error != null)
            Tooltip(
              message: '$_error',
              child: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  Widget _messageView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _connect, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
