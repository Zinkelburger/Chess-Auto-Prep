import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/position_analysis.dart';
import 'package:chess_auto_prep/widgets/common/choice_field.dart';
import 'package:chess_auto_prep/widgets/common/list_nav.dart';
import 'package:chess_auto_prep/widgets/fen_list_widget.dart';

/// Three positions whose default sort (Lowest Win Rate) orders them
/// fen-low, fen-mid, fen-high.
PositionAnalysis _threePositionAnalysis() {
  final analysis = PositionAnalysis();
  for (final entry in {'fen-mid': 5, 'fen-low': 1, 'fen-high': 9}.entries) {
    analysis.addPositionStats(
      PositionStats(
        fen: entry.key,
        games: 10,
        wins: entry.value,
        losses: 10 - entry.value,
      ),
    );
  }
  return analysis;
}

Future<void> _pumpList(
  WidgetTester tester, {
  required List<String> selections,
  ListNavController? controller,
  VoidCallback? onAnalyzeWithEngine,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: FenListWidget(
            analysis: _threePositionAnalysis(),
            onFenSelected: selections.add,
            navController: controller,
            onAnalyzeWithEngine: onAnalyzeWithEngine,
          ),
        ),
      ),
    ),
  );
}

/// Pick a sort by typing into the sort field and taking the top hit.
Future<void> _sortBy(WidgetTester tester, String label) async {
  await tester.enterText(find.byType(ChoiceField<String>), label);
  await tester.pumpAndSettle();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('has no title header and shows a position counter', (
    tester,
  ) async {
    await _pumpList(tester, selections: []);

    expect(find.text('Weak Positions'), findsNothing);
    expect(find.text('3 positions'), findsOneWidget);
    expect(find.text('Prev'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('Prev/Next buttons step the selection in ranked order', (
    tester,
  ) async {
    final selections = <String>[];
    await _pumpList(tester, selections: selections);

    // Nothing selected yet: Prev is disabled, Next selects the top row.
    final previousButton = find.widgetWithText(TextButton, 'Prev');
    expect(tester.widget<TextButton>(previousButton).onPressed, isNull);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(selections, ['fen-low']);
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(selections, ['fen-low', 'fen-mid']);
    expect(find.text('2 of 3'), findsOneWidget);

    await tester.tap(find.text('Prev'));
    await tester.pumpAndSettle();
    expect(selections, ['fen-low', 'fen-mid', 'fen-low']);
    expect(find.text('1 of 3'), findsOneWidget);
  });

  testWidgets('controller steps the selection and clamps at the ends', (
    tester,
  ) async {
    final selections = <String>[];
    final controller = ListNavController();
    await _pumpList(tester, selections: selections, controller: controller);

    controller.selectPrevious();
    await tester.pumpAndSettle();
    expect(selections, ['fen-low'], reason: 'first step selects the top row');

    controller.selectPrevious();
    await tester.pumpAndSettle();
    expect(selections, ['fen-low'], reason: 'clamped at the top');

    controller.selectNext();
    controller.selectNext();
    controller.selectNext();
    await tester.pumpAndSettle();
    expect(selections, ['fen-low', 'fen-mid', 'fen-high'], reason: 'clamped');

    // At the bottom the Next button reflects the clamp.
    final nextButton = find.widgetWithText(TextButton, 'Next');
    expect(tester.widget<TextButton>(nextButton).onPressed, isNull);
  });

  testWidgets('an eval sort before any engine pass offers to run one', (
    tester,
  ) async {
    var opened = 0;
    await _pumpList(
      tester,
      selections: [],
      onAnalyzeWithEngine: () => opened++,
    );

    // The eval sorts are listed even though nothing has been evaluated.
    await _sortBy(tester, 'Bad Eval');

    expect(find.textContaining('not been analyzed with the engine'), findsOne);
    await tester.tap(find.text('Analyze with engine…'));
    await tester.pumpAndSettle();
    expect(opened, 1);

    // Back to a stats sort, the rows return.
    await _sortBy(tester, 'Most Games');
    expect(find.text('3 positions'), findsOneWidget);
  });

  testWidgets('the engine button is disabled while a run cannot start', (
    tester,
  ) async {
    await _pumpList(tester, selections: []);
    await _sortBy(tester, 'Good Eval');

    final button = find.widgetWithText(FilledButton, 'Analyze with engine…');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });
}
