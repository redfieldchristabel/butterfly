/// The typed API the panels call: one method per `ext.cocoon.*` service
/// extension, plus the live change stream.
///
/// The API is built around two function seams so everything except the
/// process-global [CocoonInspectorApi.live] constructor stays testable
/// without a VM service: [_call] performs an extension call, [_changes]
/// exposes the `cocoon:changes` event stream.
library;

import 'dart:convert';

import 'models.dart';

/// Performs one service extension call and returns the decoded result JSON.
///
/// Returns `null` when the VM service answered without a payload.
typedef InspectorCall =
    Future<Map<String, Object?>?> Function(
      String method,
      Map<String, String> args,
    );

/// The API surface the inspector's panels render.
///
/// This file is deliberately free of the DevTools imports: the VM test
/// runner cannot compile them (`package:web` / `dart:js_interop` are
/// web-only), and the panels and tests only need the pure call layer. The
/// web-only wiring lives in `live.dart`.
final class CocoonInspectorApi {
  /// Builds an API over explicit seams; the [live] constructor in
  /// `live.dart` wires the DevTools service manager in.
  CocoonInspectorApi({
    required InspectorCall call,
    required Stream<Map<String, Object?>> changes,
  }) : _call = call,
       _changes = changes;

  final InspectorCall _call;
  final Stream<Map<String, Object?>> _changes;

  /// The committed-change event stream of the connected app.
  Stream<Map<String, Object?>> get changes => _changes;

  /// Every database the process opened, open or closed, in open order.
  Future<List<InspectorDatabase>> listDatabases() async =>
      InspectorDatabase.listFrom(await _checked('listDatabases', const {}));

  /// The collections registered on the database, plus the stored schema
  /// version.
  Future<CollectionListing> listCollections(String databaseId) async =>
      CollectionListing.fromJson(
        await _checked('listCollections', {'databaseId': databaseId}),
      );

  /// One keyset page of documents of the concrete collection [path].
  Future<DocPage> listDocs({
    required String databaseId,
    required String path,
    int? limit,
    String? startAfter,
  }) async {
    return DocPage.fromJson(
      await _checked('listDocs', {
        'databaseId': databaseId,
        'path': path,
        if (limit != null) 'limit': '$limit',
        if (startAfter != null && startAfter.isNotEmpty)
          'startAfter': startAfter,
      }),
    );
  }

  /// One document at [path], existing or not.
  Future<DocDetail> getDoc({
    required String databaseId,
    required String path,
  }) async {
    final json = await _checked('getDoc', {
      'databaseId': databaseId,
      'path': path,
    });
    final doc = json['doc'];
    return DocDetail.fromJson(doc);
  }

  /// Runs a read-only query built from [filters], [orders] and [scope].
  ///
  /// [scope] carries either a concrete collection path (`path`), or a
  /// collection-group query (`pattern` + `group: 'true'`). A query no index
  /// serves comes back as a [QueryRefused] carrying the suggested
  /// `Index([...])` declaration instead of rows.
  Future<QueryOutcome> runQuery({
    required String databaseId,
    required QueryScope scope,
    List<QueryFilterSpec> filters = const [],
    List<QueryOrderSpec> orders = const [],
    int limit = 50,
    bool fullScan = false,
  }) async {
    final json = await _checked('runQuery', {
      'databaseId': databaseId,
      ...scope.toArgs(),
      'filters': jsonEncode([for (final filter in filters) filter.toJson()]),
      'orders': jsonEncode([for (final order in orders) order.toJson()]),
      'limit': '$limit',
      if (fullScan) 'fullScan': 'true',
    });
    return QueryOutcome.fromJson(json);
  }

  /// The database's schema: stored version, lock JSON and live tables.
  Future<SchemaReport> schema(String databaseId) async => SchemaReport.fromJson(
    await _checked('schema', {'databaseId': databaseId}),
  );

  /// Calls [method] and turns an `{"error": ...}` result into an
  /// [InspectorCallException]; `runQuery` handles its own error shape.
  Future<Map<String, Object?>> _checked(
    String method,
    Map<String, String> args,
  ) async {
    final json = await _call(method, args);
    if (json == null) {
      throw InspectorCallException('$method returned no result');
    }
    final error = json['error'];
    if (error is String) {
      throw InspectorCallException(error);
    }
    return json;
  }
}

/// Which documents a query runs over.
final class QueryScope {
  const QueryScope.collection(this.path) : pattern = null, group = false;

  const QueryScope.group(this.pattern) : path = null, group = true;

  /// The concrete collection path of a scoped query.
  final String? path;

  /// The collection pattern of a collection-group query.
  final String? pattern;

  /// Whether the query runs over every parent (a collection group).
  final bool group;

  /// Encodes the scope as `runQuery` parameters.
  Map<String, String> toArgs() =>
      group ? {'pattern': pattern!, 'group': 'true'} : {'path': path!};
}
