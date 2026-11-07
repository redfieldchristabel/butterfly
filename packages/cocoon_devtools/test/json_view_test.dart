import 'package:cocoon_devtools/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Map<String, Object?> fields) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: JsonMapView(fields: fields),
              ),
            ),
          ),
        ),
      );

  testWidgets('renders scalar fields of every JSON type', (tester) async {
    await pump(tester, {
      'name': 'Ana',
      'balanceMinor': -1250,
      'active': true,
      'memo': null,
      'bookedAt': '2026-11-07T10:30:00.000Z',
    });
    expect(find.text('name:'), findsOneWidget);
    expect(find.text('"Ana"'), findsOneWidget);
    expect(find.text('-1250'), findsOneWidget);
    expect(find.text('true'), findsOneWidget);
    expect(find.text('null'), findsOneWidget);
    expect(find.text('"2026-11-07T10:30:00.000Z"'), findsOneWidget);
  });

  testWidgets('renders binary placeholders dimmed but readable', (
    tester,
  ) async {
    await pump(tester, {'receipt': '<3 bytes>'});
    expect(find.text('<3 bytes>'), findsOneWidget);
  });

  testWidgets('renders nested embedded objects with their fields', (
    tester,
  ) async {
    await pump(tester, {
      'address': {
        'city': 'Kuala Lumpur',
        'geo': {'lat': 3.14, 'lon': 101.69},
      },
    });
    expect(find.text('address:'), findsOneWidget);
    expect(find.text('city:'), findsOneWidget);
    expect(find.text('"Kuala Lumpur"'), findsOneWidget);
    expect(find.text('geo:'), findsOneWidget);
    expect(find.text('101.69'), findsOneWidget);
  });

  testWidgets('renders list fields as index rows', (tester) async {
    await pump(tester, {
      'tags': ['savings', 'joint'],
    });
    expect(find.text('tags:'), findsOneWidget);
    expect(find.text('[0]:'), findsOneWidget);
    expect(find.text('"savings"'), findsOneWidget);
    expect(find.text('[1]:'), findsOneWidget);
    expect(find.text('"joint"'), findsOneWidget);
  });

  testWidgets('keeps the document field order the adapter emitted', (
    tester,
  ) async {
    await pump(tester, {
      'bookedOn': 20261107,
      'amountMinor': -500,
      'currency': 'MYR',
    });
    final rows = tester
        .widgetList<JsonFieldRow>(find.byType(JsonFieldRow))
        .map((row) => row.name)
        .toList();
    expect(rows, ['bookedOn', 'amountMinor', 'currency']);
  });

  testWidgets('empty containers render compactly', (tester) async {
    await pump(tester, {'tags': <Object?>[], 'address': <String, Object?>{}});
    expect(find.text('[]'), findsOneWidget);
    expect(find.text('{}'), findsOneWidget);
  });
}
