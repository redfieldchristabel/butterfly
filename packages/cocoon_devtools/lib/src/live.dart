/// The web-only wiring of the inspector API: the DevTools service manager
/// as the transport for the `ext.cocoon.*` calls and the source of the
/// `cocoon:changes` event stream.
///
/// This file is separate from `api.dart` because it imports
/// `package:devtools_extensions`, which pulls in `package:web` and
/// `dart:js_interop` — those compile only for web, so the VM test runner
/// cannot load anything that reaches them.
library;

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:vm_service/vm_service.dart';

import 'api.dart';
import 'models.dart';

/// Builds an API over the DevTools service manager of a connected app.
///
/// Extension calls run on the app's main isolate — the same isolate the
/// `Cocoon` object lives on, even though the engine's SQLite work happens
/// in `sqlite_async` isolates.
CocoonInspectorApi liveCocoonInspectorApi() {
  return CocoonInspectorApi(
    call: (method, args) async {
      final response = await serviceManager.callServiceExtensionOnMainIsolate(
        '$inspectorServicePrefix$method',
        args: args,
      );
      return response.json;
    },
    changes: liveChangeStream(),
  );
}

/// The `cocoon:changes` events of the connected VM service, decoded.
///
/// Returns an empty stream when the service is not connected yet; the app
/// builds the API (and this stream) once per connection.
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
