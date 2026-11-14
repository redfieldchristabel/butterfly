import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon/src/engine/query.dart' show QueryOrder;
import 'package:test/test.dart';
import 'support/open_db.dart';

/// Keyset pagination over a collection group: a document's id is unique only
/// within one parent, so a group query's tiebreaker must be the full
/// identity — every path param the scope leaves unbound, then the id.
/// Regression tests for the two bugs that caused: pages silently skipping
/// every later row sharing the last row's id under another parent, and
/// `InvalidCursorException` on page 2 when an order mapped to a param column
/// (which the page SELECT does not re-list).

/// A hand-written adapter over JSON-map documents, written the way the code
/// generator emits adapters.
final class JsonStore extends CollectionAdapter<Object> {
  JsonStore(this.path, {this.cols = const [], this.idx = const []});

  final String path;
  final List<FieldColumn<Object, Object?>> cols;
  final List<IndexDef> idx;

  @override
  String get model => path.replaceAll(RegExp(r'[^a-z]'), '_');

  @override
  CollectionPattern get pattern => CollectionPattern.parse(path);

  @override
  List<FieldColumn<Object, Object?>> get columns => cols;

  @override
  List<IndexDef> get indexes => idx;

  @override
  Uint8List encode(Object value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));

  @override
  Object decode(Uint8List bytes) => jsonDecode(utf8.decode(bytes)) as Object;

  @override
  Map<String, Object?> toInspectorJson(Object value) =>
      (value as Map).cast<String, Object?>();
}

FieldColumn<Object, String?> jsonText(String field) =>
    FieldColumn<Object, String?>(
      name: field,
      type: ColumnType.text,
      nullable: true,
      read: (v) => (v as Map?)?[field] as String?,
      toSql: (v) => v,
      fromSql: (v) => v as String?,
    );

FieldColumn<Object, int> jsonInt(String field) => FieldColumn<Object, int>(
  name: field,
  type: ColumnType.integer,
  read: (v) => ((v as Map?)?[field] as num?)?.toInt() ?? 0,
  toSql: (v) => v,
  fromSql: (v) => v as int,
);

final lineAccount = jsonText('accountId');
final lineDay = jsonInt('day');

final entries = JsonStore('entries');

final lines = JsonStore(
  'entries/{entryId}/lines',
  cols: [lineAccount, lineDay],
  idx: [
    IndexDef.fromFields(['accountId']),
    IndexDef.fromFields(['day']),
    IndexDef.fromFields(['-day']),
  ],
);

/// The `{entryId}` value of a line document's path
/// (`entries/<entryId>/lines/l0`).
String parentOf(DocSnapshot<Object> doc) => doc.ref.path.path.split('/')[1];

void main() {
  late Directory dir;
  late Cocoon db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cocoon_keyset');
    db = await openCocoon('${dir.path}/b.db', collections: [entries, lines]);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  /// Seeds [parents] parents, each holding one child [childId] with
  /// [account]/[day] columns, inside ONE transaction.
  Future<void> seed(
    int parents, {
    String childId = 'l0',
    String account = 'cash',
    int day = 0,
  }) async {
    final batch = db.batch();
    for (var i = 0; i < parents; i++) {
      batch.set(
        db.collection(entries).doc('e$i').collection(lines).doc(childId),
        {'accountId': account, 'day': day},
      );
    }
    await batch.commit();
  }

  /// Drains [query] page by page with `startAfter`, returning every document
  /// in page order.
  Future<List<DocSnapshot<Object>>> drain(CocoonQuery<Object> query) async {
    final docs = <DocSnapshot<Object>>[];
    var page = await query.get();
    docs.addAll(page.docs);
    while (page.nextCursor != null) {
      page = await query.startAfter(page.nextCursor!).get();
      docs.addAll(page.docs);
    }
    return docs;
  }

  test('a paged collection group returns every row (2500 of 2500)', () async {
    await seed(2500);
    final q = db
        .collectionGroup(lines)
        .where(lineAccount.isEqualTo('cash'))
        .limit(1000);
    final docs = await drain(q);
    expect(docs, hasLength(2500));
    // Every row seen exactly once: full paths collected into a Set.
    expect({for (final doc in docs) doc.ref.path.path}, hasLength(2500));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a paged group query ordered by a field with many ties', () async {
    await seed(60, day: 7);
    final q = db.collectionGroup(lines).orderBy(lineDay).limit(10);
    final docs = await drain(q);
    expect(docs, hasLength(60));
    expect({for (final doc in docs) doc.ref.path.path}, hasLength(60));
  });

  test('a paged group query ordered by a path param', () async {
    await seed(60);
    // The engine-internal sort-key list is how the DevTools inspector runs
    // saved queries; path params are sortable there.
    final q = CocoonQuery<Object>(
      db,
      lines,
      null,
      orders: const [QueryOrder('entryId')],
    ).limit(10);
    final docs = await drain(q);
    expect(docs, hasLength(60));
    expect({for (final doc in docs) doc.ref.path.path}, hasLength(60));
    // Ordered by the param: rows come back parent by parent, ids in their
    // stored (text) order.
    final ids = [for (var i = 0; i < 60; i++) 'e$i']..sort();
    expect([for (final doc in docs) parentOf(doc)], ids);
  });

  test('a paged group query ordered descending', () async {
    await seed(60, day: 7);
    final q = db
        .collectionGroup(lines)
        .orderBy(lineDay, descending: true)
        .limit(10);
    final docs = await drain(q);
    expect(docs, hasLength(60));
    expect({for (final doc in docs) doc.ref.path.path}, hasLength(60));
    // The sort field ties everywhere, so the identity tiebreak decides —
    // with its direction: parents in reverse stored (text) order.
    final ids = [for (var i = 0; i < 60; i++) 'e$i']..sort();
    expect(parentOf(docs.first), ids.last);
    expect(parentOf(docs.last), ids.first);
  });

  test('limit 1, limit = total and limit > total all page exactly', () async {
    await seed(5);
    final where = lineAccount.isEqualTo('cash');
    for (final limit in [1, 5, 50]) {
      final docs = await drain(
        db.collectionGroup(lines).where(where).limit(limit),
      );
      expect(docs, hasLength(5), reason: 'limit $limit');
      expect({for (final doc in docs) doc.ref.path.path}, hasLength(5));
    }
  });

  test('a page boundary exactly between two parents sharing the id', () async {
    await seed(4);
    final q = db
        .collectionGroup(lines)
        .where(lineAccount.isEqualTo('cash'))
        .limit(2);
    final page1 = await q.get();
    expect([for (final doc in page1.docs) parentOf(doc)], ['e0', 'e1']);
    // The cursor sits between (e1, l0) and (e2, l0) — same child id under
    // different parents. The next page must not skip (e2, l0).
    final page2 = await q.startAfter(page1.nextCursor!).get();
    expect([for (final doc in page2.docs) parentOf(doc)], ['e2', 'e3']);
  });

  test('garbled and foreign cursors are still rejected', () async {
    await seed(4);
    final q = db
        .collectionGroup(lines)
        .where(lineAccount.isEqualTo('cash'))
        .limit(2);
    final page = await q.get();
    expect(page.nextCursor, isNotNull);
    await expectLater(
      q.startAfter('not-a-cursor').get(),
      throwsA(isA<InvalidCursorException>()),
    );
    // A cursor from a query with a different filter (different fingerprint).
    final foreign = db
        .collectionGroup(lines)
        .where(lineAccount.isEqualTo('petty'))
        .limit(2);
    await expectLater(
      foreign.startAfter(page.nextCursor!).get(),
      throwsA(isA<CursorMismatchException>()),
    );
  });

  test('watch() still emits the current page of a paged group query', () async {
    await seed(30);
    final first = Completer<int>();
    final sub = db
        .collectionGroup(lines)
        .where(lineAccount.isEqualTo('cash'))
        .limit(10)
        .watch()
        .listen((page) => first.complete(page.docs.length));
    expect(await first.future, 10);
    await sub.cancel();
  });
}
