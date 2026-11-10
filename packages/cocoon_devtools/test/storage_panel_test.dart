import 'package:cocoon_devtools/src/storage_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget smoke tests for the Storage tab: both preview states render
/// without exceptions, at the DevTools panel's narrow and wide widths.
void main() {
  Future<void> pump(WidgetTester tester, {double width = 900}) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: StoragePanel())),
    );
  }

  testWidgets('the idle preview renders every section', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    // The preview banner is visible and names its state toggle.
    expect(find.textContaining('Preview data'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('Bulk loading'), findsOneWidget);
    // File: the headline is the on-disk footprint (file + WAL).
    expect(find.text('425.8 MB'), findsOneWidget);
    expect(find.text('390.1 MB'), findsWidgets);
    expect(find.textContaining('free pages a VACUUM'), findsOneWidget);
    // Where the bytes go: the collection bar and the change log row.
    // (The title also shows in the Indexes card.)
    expect(find.text('Txn — accounts/{accountId}/txns'), findsNWidgets(2));
    expect(find.text('Documents'), findsWidgets);
    expect(
      find.textContaining('Change log — one row per written'),
      findsOneWidget,
    );
    // Indexes: human labels, live state. (The account index's label also
    // appears as a legend row in the bytes card.)
    expect(find.text('Index: account, newest first'), findsWidgets);
    expect(find.text('Live'), findsWidgets);
    // Bulk load: the idle state.
    expect(find.text('No bulk load running.'), findsOneWidget);
  });

  testWidgets('the bulk-loading preview shows progress and deferred indexes', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Bulk loading'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.text('800,000 of 1,000,000 rows committed — 200,000 queued'),
      findsOneWidget,
    );
    expect(find.text('Chunks of 10,000 rows'), findsOneWidget);
    expect(
      find.text('4 indexes deferred while the load runs.'),
      findsOneWidget,
    );
    expect(
      find.text(
        '2 queries waiting for the deferred indexes — they finish when the '
        'load does.',
      ),
      findsOneWidget,
    );
    expect(find.text('Deferred by a bulk load'), findsNWidgets(4));
    expect(find.text('10.4 s'), findsOneWidget);
  });

  testWidgets('renders at a narrow panel width without exceptions', (
    tester,
  ) async {
    await pump(tester, width: 480);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Bulk loading'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a segment selects it for the detail line', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Path index'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('Path index — 39.4 MB · 10.1% of the file'),
      findsOneWidget,
    );
  });
}
