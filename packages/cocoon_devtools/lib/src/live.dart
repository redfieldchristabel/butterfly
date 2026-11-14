/// The web-only wiring of the inspector API: the DevTools service manager
/// as the transport for the `ext.cocoon.*` calls and the source of the
/// `cocoon:changes` event stream.
///
/// This file is separate from `api.dart` because it imports
/// `package:devtools_extensions`, which pulls in `package:web` and
/// `dart:js_interop` — those compile only for web, so the VM test runner
/// cannot load anything that reaches them.
///
/// Isolate discovery: a Cocoon database registers its `ext.cocoon.*`
/// handlers on the isolate its engine runs in — the main isolate for
/// `caller` and `auto` databases, a per-database worker isolate for
/// `background` databases. `listDatabases` therefore asks every live
/// isolate and merges the answers under composite ids
/// (`<isolateId>/<databaseId>`); every other call routes through the
/// composite id to the owning isolate (see `routing.dart`).
library;

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:vm_service/vm_service.dart';

import 'api.dart';
import 'models.dart';
import 'routing.dart';

/// Builds an API over the DevTools service manager of a connected app.
CocoonInspectorApi liveCocoonInspectorApi() {
  final routes = <String, (String, String)>{};
  return CocoonInspectorApi(
    call: (method, args) async {
      final service = serviceManager.service;
      if (service == null) {
        return null;
      }
      if (method == listDatabasesMethod) {
        final merged = await _listDatabasesAcrossIsolates(service);
        routes
          ..clear()
          ..addAll(merged.routes);
        return merged.json;
      }
      final composite = args['databaseId'] ?? '';
      final route = splitDatabaseId(composite);
      final Response response;
      if (route == null) {
        // A bare id: the app side predates isolate discovery, and its
        // handlers live on the main isolate — the protocol's default
        // target.
        response = await service
            .callServiceExtension('$inspectorServicePrefix$method', args: args)
            .timeout(const Duration(seconds: 60));
      } else {
        response = await service
            .callServiceExtension(
              '$inspectorServicePrefix$method',
              isolateId: route.$1,
              args: {...args, 'databaseId': route.$2},
            )
            .timeout(const Duration(seconds: 60));
      }
      final json = response.json;
      // Keep the response's echoed database id composite, so the panels'
      // cached ids stay valid.
      final database = json?['database'];
      if (database is Map<Object?, Object?>) {
        database['id'] = composite;
      }
      return json;
    },
    changes: liveChangeStream(),
  );
}

/// Asks every live isolate for its `ext.cocoon.listDatabases` answer and
/// merges them. Isolates without the inspector (the service isolate, an
/// auto helper, isolates that are already gone) answer with an error and
/// are skipped.
Future<({Map<String, Object?> json, Map<String, (String, String)> routes})>
_listDatabasesAcrossIsolates(VmService service) async {
  final vm = await service.getVM();
  final answers = <IsolateAnswer>[];
  for (final isolate in vm.isolates ?? const <IsolateRef>[]) {
    final isolateId = isolate.id;
    if (isolateId == null) {
      continue;
    }
    try {
      final response = await service
          .callServiceExtension(
            '$inspectorServicePrefix$listDatabasesMethod',
            isolateId: isolateId,
          )
          .timeout(const Duration(seconds: 30));
      final json = response.json;
      if (json == null) {
        continue;
      }
      answers.add((isolateId: isolateId, json: json));
    } on Object {
      continue; // No inspector on this isolate, or it is gone.
    }
  }
  return mergeDatabaseLists(answers);
}

/// The `ext.cocoon.` method the extension broadcasts across isolates; the
/// other methods route by database id instead.
const String listDatabasesMethod = 'listDatabases';

/// The `cocoon:changes` events of the connected VM service, decoded.
///
/// Returns an empty stream when the service is not connected yet; the app
/// builds the API (and this stream) once per connection. The events carry
/// the emitting isolate's own database id, but the change feed does not
/// match ids — it shows every committed change of the process.
Stream<Map<String, Object?>> liveChangeStream() {
  final VmService? service = serviceManager.service;
  if (service == null) {
    return const Stream.empty();
  }
  return service
      .onEvent(EventStreams.kExtension)
      .where((event) => event.extensionKind == inspectorChangesEventKind)
      .map((event) => event.extensionData?.data ?? <String, Object?>{});
}
