/// The inspector's multi-isolate routing: a background-mode Cocoon
/// registers its `ext.cocoon.*` handlers in its worker isolate, so the
/// DevTools extension must merge the `listDatabases` answers of every
/// isolate and route later calls to the isolate that owns the database.
///
/// Pure functions over plain maps, so the VM test runner can exercise them;
/// `live.dart` (web-only) supplies the VM service transport.
library;

/// One isolate's `listDatabases` answer during discovery.
typedef IsolateAnswer = ({String isolateId, Map<String, Object?> json});

/// Splits the composite database id the extension hands out
/// (`<isolateId>/<databaseId>`) into its isolate id and the receiving
/// isolate's own database id. Returns `null` when [composite] carries no
/// isolate prefix — an id from an app-side build before the merge — which
/// the caller routes to the main isolate.
(String isolateId, String databaseId)? splitDatabaseId(String composite) {
  final slash = composite.lastIndexOf('/');
  if (slash <= 0) {
    return null;
  }
  return (composite.substring(0, slash), composite.substring(slash + 1));
}

/// Merges every isolate's `listDatabases` answer into one result whose
/// database ids are unique across the process, plus the route map from
/// composite id to (isolate id, the owning isolate's own database id).
/// Answers without a `databases` list are skipped (an isolate without the
/// inspector registered answers with an error before this runs).
({Map<String, Object?> json, Map<String, (String, String)> routes})
mergeDatabaseLists(List<IsolateAnswer> answers) {
  final routes = <String, (String, String)>{};
  final databases = <Map<String, Object?>>[];
  for (final (:isolateId, :json) in answers) {
    final list = json['databases'];
    if (list is! List) {
      continue;
    }
    for (final entry in list) {
      if (entry is! Map<String, Object?>) {
        continue;
      }
      final localId = entry['id'];
      if (localId is! String) {
        continue;
      }
      final composite = '$isolateId/$localId';
      routes[composite] = (isolateId, localId);
      databases.add({...entry, 'id': composite, 'isolateId': isolateId});
    }
  }
  return (json: <String, Object?>{'databases': databases}, routes: routes);
}
