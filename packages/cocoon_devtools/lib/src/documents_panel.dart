/// The document browser: collections to documents to fields, with the path
/// breadcrumb and subcollection drill-down.
library;

import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'models.dart';
import 'widgets.dart';

/// The browser panel of the inspector.
///
/// At the root it lists the top-level collections; after choosing one it
/// lists that collection's documents page by page (ordered by document
/// path, keyset-paginated like the engine); clicking a document shows its
/// decoded fields and the subcollections registered under it, which drill
/// down one more level.
class DocumentsPanel extends StatefulWidget {
  const DocumentsPanel({
    super.key,
    required this.api,
    required this.databaseId,
    required this.collections,
  });

  /// The API to call the inspected app with.
  final CocoonInspectorApi api;

  /// The database to browse.
  final String databaseId;

  /// The collections registered on the database.
  final List<CollectionInfo> collections;

  @override
  State<DocumentsPanel> createState() => _DocumentsPanelState();
}

class _DocumentsPanelState extends State<DocumentsPanel> {
  String? _browsedPath;
  DocPage? _page;
  String? _selectedDocPath;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _openRoot();
  }

  @override
  void didUpdateWidget(covariant DocumentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.databaseId != widget.databaseId) {
      _openRoot();
    }
  }

  void _openRoot() {
    setState(() {
      _browsedPath = null;
      _page = null;
      _selectedDocPath = null;
      _error = null;
    });
  }

  void _openCollection(String path) {
    setState(() {
      _browsedPath = path;
      _page = null;
      _selectedDocPath = null;
      _error = null;
    });
    _load();
  }

  Future<void> _load() async {
    final path = _browsedPath;
    if (path == null) {
      return;
    }
    setState(() {
      _loading = true;
      _loadingMore = false;
    });
    try {
      final page = await widget.api.listDocs(
        databaseId: widget.databaseId,
        path: path,
      );
      if (!mounted || _browsedPath != path) {
        return;
      }
      setState(() {
        _page = page;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || _browsedPath != path) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final path = _browsedPath;
    final page = _page;
    final startAfter = page?.nextStartAfter;
    if (path == null || page == null || startAfter == null) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final next = await widget.api.listDocs(
        databaseId: widget.databaseId,
        path: path,
        startAfter: startAfter,
      );
      if (!mounted || _browsedPath != path) {
        return;
      }
      setState(() {
        _page = DocPage(
          collection: next.collection,
          docs: [...page.docs, ...next.docs],
          nextStartAfter: next.nextStartAfter,
        );
        _loadingMore = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loadingMore = false;
      });
    }
  }

  /// The breadcrumb from the root to the current collection or document.
  List<BreadcrumbSegment> get _crumbs {
    final crumbs = <BreadcrumbSegment>[(label: 'database', path: '')];
    final path = _selectedDocPath ?? _browsedPath;
    if (path == null || path.isEmpty) {
      return crumbs;
    }
    final segments = path.split('/');
    for (var i = 0; i < segments.length; i++) {
      crumbs.add((
        label: segments[i],
        path: segments.sublist(0, i + 1).join('/'),
      ));
    }
    return crumbs;
  }

  void _onCrumb(BreadcrumbSegment segment) {
    if (segment.path.isEmpty) {
      _openRoot();
      return;
    }
    final segments = segment.path.split('/');
    if (segments.length.isOdd) {
      _openCollection(segment.path);
      return;
    }
    // A document id: re-open its collection and select the document; the
    // loaded page stays visible when it already is this collection's.
    final collectionPath = segments.sublist(0, segments.length - 1).join('/');
    final stale = _page?.collection.concretePath != collectionPath;
    setState(() {
      _selectedDocPath = segment.path;
      _browsedPath = collectionPath;
      if (stale) {
        _page = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_browsedPath == null) {
      body = _rootView();
    } else if (_selectedDocPath == null) {
      body = _docsView();
    } else {
      body = _docView();
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          PathBreadcrumb(segments: _crumbs, onSelected: _onCrumb),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _rootView() {
    final topLevel = topLevelCollectionPaths(widget.collections);
    if (topLevel.isEmpty) {
      return const Text(
        'This database registers no top-level collection. Every collection '
        'here lives under a parent document; reach it by opening a document '
        'of a parent collection.',
      );
    }
    return ListView.builder(
      itemCount: topLevel.length,
      itemBuilder: (context, index) {
        final path = topLevel[index];
        final collection = widget.collections.firstWhere(
          (c) => c.pattern == path,
        );
        return Card(
          child: ListTile(
            title: Text(
              collection.model,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${collection.pattern} — ${collection.documentCount} documents',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openCollection(path),
          ),
        );
      },
    );
  }

  Widget _docsView() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _errorView();
    }
    final page = _page;
    if (page == null) {
      return const SizedBox.shrink();
    }
    if (page.docs.isEmpty) {
      return const Text('No documents in this collection yet.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${page.collection.model} — ${page.docs.length}'
          '${page.nextStartAfter == null ? '' : '+'} documents, ordered by path',
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: page.docs.length + (page.nextStartAfter == null ? 0 : 1),
            itemBuilder: (context, index) {
              if (index == page.docs.length) {
                return TextButton.icon(
                  onPressed: _loadingMore ? null : _loadMore,
                  icon: const Icon(Icons.unfold_more),
                  label: Text(_loadingMore ? 'Loading…' : 'Load more'),
                );
              }
              final doc = page.docs[index];
              return Card(
                child: ListTile(
                  title: Text(doc.id),
                  subtitle: Text(
                    _previewOf(doc.json),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _subcollectionsOf(doc.path),
                  onTap: () => setState(() => _selectedDocPath = doc.path),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _docView() {
    final docPath = _selectedDocPath!;
    final page = _page;
    DocSummary? doc;
    for (final candidate in page?.docs ?? const <DocSummary>[]) {
      if (candidate.path == docPath) {
        doc = candidate;
      }
    }
    if (doc == null) {
      return Text(
        'Document $docPath is not on the loaded page; go back and '
        'reload the collection.',
      );
    }
    final subcollections = _subcollectionNamesOf(docPath);
    return ListView(
      children: [
        JsonMapView(fields: doc.json),
        if (subcollections.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Subcollections', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final entry in subcollections)
                ActionChip(
                  label: Text(entry.label),
                  tooltip: entry.path,
                  onPressed: () => _openCollection(entry.path),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// The subcollection chips of one document row: the registered
  /// collections that live directly under it.
  Widget? _subcollectionsOf(String docPath) {
    final names = _subcollectionNamesOf(docPath);
    if (names.isEmpty) {
      return null;
    }
    return Tooltip(
      message: 'Subcollections: ${names.map((e) => e.label).join(', ')}',
      child: const Icon(Icons.account_tree, size: 18),
    );
  }

  /// The (label, concrete path) pairs of every registered collection that
  /// is a direct subcollection of [docPath].
  List<({String label, String path})> _subcollectionNamesOf(String docPath) {
    final entries = <({String label, String path})>[];
    for (final collection in widget.collections) {
      final path = subcollectionPathOf(collection.pattern, docPath);
      if (path != null) {
        final label = path.split('/').last;
        entries.add((label: label, path: path));
      }
    }
    return entries;
  }

  Widget _errorView() {
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
}

/// A one-line preview of a document: its first scalar fields.
String _previewOf(Map<String, Object?> json) {
  final parts = <String>[];
  for (final entry in json.entries) {
    if (parts.length == 3) {
      break;
    }
    final value = entry.value;
    if (value is Map || value is List) {
      continue;
    }
    parts.add('${entry.key}: $value');
  }
  return parts.isEmpty ? '{}' : parts.join(', ');
}
