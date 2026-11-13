import 'package:cocoon_devtools/src/models.dart';
import 'package:cocoon_devtools/src/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlanVerdict', () {
    test('an index use names the index', () {
      final verdict = PlanVerdict.fromPlan({
        'sql': 'SELECT …',
        'explain': 'SEARCH t USING INDEX cx_txn_ab12cd34 (f_status=? …)',
        'usedIndex': true,
        'indexName': 'cx_txn_ab12cd34',
      });
      expect(verdict.outcome, PlanOutcome.usedIndex);
      expect(verdict.headline, 'Used index cx_txn_ab12cd34');
    });

    test('a full scan tells the developer to add Index([...])', () {
      final verdict = PlanVerdict.fromPlan({
        'sql': 'SELECT …',
        'explain': 'SCAN t',
        'usedIndex': false,
        'indexName': null,
      });
      expect(verdict.outcome, PlanOutcome.fullScan);
      expect(verdict.headline, 'Full scan: add Index([...])');
      expect(verdict.advice, contains('Declare an Index'));
    });

    test('a primary-key walk reads as the document-id path', () {
      final verdict = PlanVerdict.fromPlan({
        'sql': 'SELECT …',
        'explain': 'SEARCH t USING INTEGER PRIMARY KEY (rowid=?)',
        'usedIndex': true,
        'indexName': null,
      });
      expect(verdict.outcome, PlanOutcome.usedPrimaryKey);
      expect(verdict.headline, 'Used the document-id primary key');
    });

    test('a refused query carries the suggested declaration', () {
      final verdict = PlanVerdict.missingIndex("Index(['status', 'bookedOn'])");
      expect(verdict.headline, 'Full scan: add Index([...])');
      expect(verdict.suggestedIndex, "Index(['status', 'bookedOn'])");
    });
  });

  group('PlanVerdictView', () {
    Future<void> pump(WidgetTester tester, PlanVerdict verdict) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(8),
                child: PlanVerdictView(verdict: verdict),
              ),
            ),
          ),
        );

    testWidgets('renders the headline and the advice sentence', (tester) async {
      await pump(tester, PlanVerdict.index('cx_txn_ab12cd34'));
      expect(find.text('Used index cx_txn_ab12cd34'), findsOneWidget);
      expect(find.byType(PlanVerdictView), findsOneWidget);
      expect(
        find.text(
          'A declared index served this query; no extra rows were read.',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.bolt), findsOneWidget);
    });

    testWidgets('a full scan shows the Index([...]) headline', (tester) async {
      await pump(tester, PlanVerdict.fullScan());
      expect(find.text('Full scan: add Index([...])'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('a refused query shows the suggested declaration as code', (
      tester,
    ) async {
      await pump(
        tester,
        PlanVerdict.missingIndex("Index(['status', 'bookedOn'])"),
      );
      expect(find.text('Declare this on the model:'), findsOneWidget);
      expect(find.text("Index(['status', 'bookedOn'])"), findsOneWidget);
    });

    testWidgets('a primary-key verdict needs no suggested declaration', (
      tester,
    ) async {
      await pump(tester, PlanVerdict.primaryKey());
      expect(find.text('Used the document-id primary key'), findsOneWidget);
      expect(find.text('Declare this on the model:'), findsNothing);
    });
  });
}
