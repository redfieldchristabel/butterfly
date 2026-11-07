import 'package:cocoon_devtools/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const crumbs = <BreadcrumbSegment>[
    (label: 'database', path: ''),
    (label: 'accounts', path: 'accounts'),
    (label: 'a1', path: 'accounts/a1'),
    (label: 'txns', path: 'accounts/a1/txns'),
    (label: 't9', path: 'accounts/a1/txns/t9'),
  ];

  Future<void> pump(
    WidgetTester tester,
    List<BreadcrumbSegment> segments, {
    void Function(BreadcrumbSegment)? onSelected,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(8),
          child: PathBreadcrumb(segments: segments, onSelected: onSelected),
        ),
      ),
    ),
  );

  testWidgets('renders one crumb per path segment, slash separated', (
    tester,
  ) async {
    await pump(tester, crumbs);
    for (final segment in crumbs) {
      expect(find.text(segment.label), findsOneWidget);
    }
    expect(find.text('/'), findsNWidgets(crumbs.length - 1));
  });

  testWidgets('tapping a crumb reports its full path', (tester) async {
    final selected = <String>[];
    await pump(
      tester,
      crumbs,
      onSelected: (segment) => selected.add(segment.path),
    );
    await tester.tap(find.text('a1'));
    await tester.pump();
    expect(selected, ['accounts/a1']);
  });

  testWidgets('the current crumb is not clickable', (tester) async {
    final selected = <String>[];
    await pump(
      tester,
      crumbs,
      onSelected: (segment) => selected.add(segment.path),
    );
    await tester.tap(find.text('t9'));
    await tester.pump();
    expect(selected, isEmpty);
  });

  testWidgets('an empty crumb list renders nothing', (tester) async {
    await pump(tester, const []);
    expect(find.byType(PathBreadcrumb), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);
  });
}
