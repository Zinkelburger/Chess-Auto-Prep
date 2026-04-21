import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';

import 'board_helpers.dart';

/// Boot the app and wait for it to settle.
Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(const ChessAutoPrepApp());
  await tester.pumpAndSettle();
}

/// Run the Lichess import flow and poll until a start button appears.
Future<void> importAndWaitForPositions(
  WidgetTester tester, {
  String username = 'DrNykterstein',
  String gameCount = '5',
  Duration pollInterval = const Duration(seconds: 2),
  int maxPolls = 60,
}) async {
  final lichessField = find.widgetWithText(TextField, 'Lichess Username');
  await tester.enterText(lichessField, username);
  await tester.pumpAndSettle();

  final gameCountField = find.widgetWithText(TextField, 'Recent Games').first;
  await tester.enterText(gameCountField, gameCount);
  await tester.pumpAndSettle();

  final importButtons = find.widgetWithText(ElevatedButton, 'Import');
  await tester.tap(importButtons.first);
  await tester.pump();

  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(pollInterval);
    if (find.textContaining('Start Practice Session').evaluate().isNotEmpty ||
        find.textContaining('Start Training Now').evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Start button never appeared after importing $gameCount games for $username');
}

/// Tap the start-session button (whichever variant is visible).
Future<void> tapStartSession(WidgetTester tester) async {
  final startPractice = find.textContaining('Start Practice Session');
  final startTraining = find.textContaining('Start Training Now');
  final buttonToTap = startPractice.evaluate().isNotEmpty
      ? startPractice
      : startTraining;

  await tester.ensureVisible(buttonToTap);
  await tester.pumpAndSettle();
  await tester.tap(buttonToTap);
  await tester.pumpAndSettle();
}

/// Assert that we're on the tactics training screen with a tactic loaded.
void expectTacticLoaded() {
  expect(find.text('Show Solution'), findsOneWidget);
  expect(find.byType(ChessBoardWidget), findsOneWidget);
}

/// Tap "Show Solution" and return the list of move tokens from the solution.
/// Fails if no solution is available.
Future<List<String>> showSolutionAndParseMoves(WidgetTester tester) async {
  await tester.tap(find.text('Show Solution'));
  await tester.pumpAndSettle();

  final solutionFinder = find.textContaining('Solution: ');
  expect(solutionFinder, findsOneWidget);

  final fullText = tester.widget<Text>(solutionFinder).data ?? '';
  final movesStr = fullText.replaceFirst(RegExp(r'^Solution:\s*'), '').trim();

  if (movesStr.isEmpty || movesStr == 'No solution available') {
    fail('Tactic has no solution to play: "$fullText"');
  }

  return movesStr.split(RegExp(r'\s+'));
}

/// Play the user moves from a tactic solution via AppState.onMoveAttempted.
///
/// [allMoves] is the interleaved list [userMove, opponentResponse, ...].
/// Only user moves (even indices) are played; opponent moves are automatic.
Future<void> playTacticMoves(
  WidgetTester tester,
  List<String> allMoves,
) async {
  final userMoveIndices = <int>[];
  for (var i = 0; i < allMoves.length; i += 2) {
    userMoveIndices.add(i);
  }

  for (var idx = 0; idx < userMoveIndices.length; idx++) {
    final moveIdx = userMoveIndices[idx];
    final moveStr = allMoves[moveIdx];
    final appState = getAppState(tester);
    final position = appState.currentPosition;
    final fenBefore = position.fen;

    final uci = parseMoveToUci(position, moveStr);
    expect(uci, isNotNull,
        reason: 'Cannot parse move "$moveStr" for FEN: $fenBefore');

    print('  Playing "$moveStr" as UCI "$uci"');

    await playMoveViaAppState(tester, uci!);

    final fenAfter = getAppState(tester).currentPosition.fen;
    expect(fenAfter, isNot(equals(fenBefore)),
        reason: 'Board should change after "$moveStr" (UCI: $uci)');

    final feedback = find.textContaining('Correct');
    expect(feedback.evaluate().isNotEmpty, isTrue,
        reason: 'Expected "Correct" after "$moveStr"');

    // Wait for opponent response before next user move
    if (idx < userMoveIndices.length - 1) {
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
    }
  }
}

/// Verify the tactic was completed: "Correct!" or auto-advanced to next.
Future<void> expectTacticCompleted(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1700));
  await tester.pumpAndSettle();

  final correctFeedback = find.textContaining('Correct!');
  final nextShowSolution = find.text('Show Solution');

  expect(
    correctFeedback.evaluate().isNotEmpty ||
        nextShowSolution.evaluate().isNotEmpty,
    isTrue,
    reason: 'Expected "Correct!" or auto-advance (Show Solution). Found neither.',
  );
}
