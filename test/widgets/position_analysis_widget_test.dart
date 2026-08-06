import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/position_analysis.dart';
import 'package:chess_auto_prep/widgets/position_analysis_widget.dart';

void main() {
  testWidgets('stacks analysis panes cleanly on narrow layouts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 800,
              child: const PositionAnalysisWidget(playerIsWhite: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Positions'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.byType(PositionAnalysisWidget), findsOneWidget);
  });

  testWidgets('P/S and ↑/↓ both step through the weak-positions list', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 800,
              child: PositionAnalysisWidget(
                playerIsWhite: true,
                analysis: analysis,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The screen's Focus owns key events and forwards previous/next to the
    // list. Every chord AppShortcut.nextItem/previousItem advertises has to
    // work, not just the first one — that is the whole point of binding a
    // registry entry rather than a single key.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget, reason: 'stops at the top');
  });
}
