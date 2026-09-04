import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_engine.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_training_panel.dart';
import 'package:chess_auto_prep/widgets/clickable_move_line.dart';

TacticsPosition _position({
  List<String> line = const ['Qf3'],
  String note = 'h5 +0.5 → -2.1, Qf3 +0.5',
  String refutation = 'Nxe5',
  String mistakeType = '??',
}) {
  return TacticsPosition(
    // Move 12, White to play.
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 12',
    gameWhite: 'Alice',
    gameBlack: 'Bob',
    gameResult: '0-1',
    gameDate: '2026.01.01',
    gameId: 'g1',
    userMove: 'h5',
    correctLine: line,
    mistakeType: mistakeType,
    mistakeAnalysis: note,
    opponentBestResponse: refutation,
  );
}

Widget _panel(
  TacticsPosition position, {
  bool solved = false,
  bool showSolution = false,
  List<String> solutionSan = const [],
  List<String> trainableSan = const [],
  int currentMoveIndex = 0,
  String feedback = '',
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TacticsTrainingPanel(
          position: position,
          engine: TacticsEngine(),
          currentMoveIndex: currentMoveIndex,
          positionSolved: solved,
          showSolution: showSolution,
          isAtStartingPosition: true,
          feedback: feedback,
          autoAdvance: false,
          onToggleSolution: () {},
          onAnalyze: () {},
          onResetAnalysis: () {},
          onAutoAdvanceChanged: (_) {},
          onCopyFen: () {},
          onSetRating: (_) {},
          solutionSanMoves: solutionSan,
          trainableSanMoves: trainableSan,
        ),
      ),
    ),
  );
}

void main() {
  group('before the answer is out', () {
    testWidgets('leads with the task, not the coordinates', (tester) async {
      await tester.pumpWidget(_panel(_position()));

      expect(find.text('White to play'), findsOneWidget);
      expect(find.text('Move 12 · Alice vs Bob'), findsOneWidget);
    });

    testWidgets('says what was played and how bad it was, in words', (
      tester,
    ) async {
      await tester.pumpWidget(_panel(_position()));

      expect(
        find.textContaining('You played h5 (blunder).', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('??', findRichText: true), findsNothing);
    });

    testWidgets('multi-move tactics say so in the task line', (tester) async {
      await tester.pumpWidget(_panel(_position(line: ['Qf3', 'Kh8', 'Rxh7'])));

      expect(find.text('White to play · 2 moves'), findsOneWidget);
    });

    testWidgets('keeps the refutation, the evals and the line back', (
      tester,
    ) async {
      await tester.pumpWidget(
        _panel(_position(), solutionSan: const ['Qf3', 'Kh8', 'Rxh7']),
      );

      expect(find.textContaining('allowing', findRichText: true), findsNothing);
      expect(find.textContaining('-2.1', findRichText: true), findsNothing);
      expect(find.byKey(const Key('tactic-solution-line')), findsNothing);
    });

    testWidgets('shows the moves found so far', (tester) async {
      await tester.pumpWidget(
        _panel(
          _position(line: ['Qf3', 'Kh8', 'Rxh7']),
          solutionSan: const ['Qf3', 'Kh8', 'Rxh7'],
          currentMoveIndex: 2,
        ),
      );

      final line = tester.widget<ClickableMoveLineWidget>(
        find.byKey(const Key('tactic-solution-line')),
      );
      expect(line.sanMoves, ['Qf3', 'Kh8']);
      expect(line.onMoveTapped, isNull);
    });

    testWidgets('shows the trained branch before revealing a different PV', (
      tester,
    ) async {
      await tester.pumpWidget(
        _panel(
          _position(line: ['e4', 'c5', 'Nf3']),
          solutionSan: const ['e4', 'e5', 'Nf3', 'Nc6'],
          trainableSan: const ['e4', 'c5', 'Nf3'],
          currentMoveIndex: 2,
        ),
      );

      final line = tester.widget<ClickableMoveLineWidget>(
        find.byKey(const Key('tactic-solution-line')),
      );
      expect(line.sanMoves, const ['e4', 'c5']);
    });
  });

  group('once solved or revealed', () {
    testWidgets('the game line says what the move allowed and cost', (
      tester,
    ) async {
      await tester.pumpWidget(_panel(_position(), solved: true));

      expect(
        find.textContaining(
          'You played h5 (blunder), allowing Nxe5.  +0.5 → -2.1',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('a puzzle with no note still names the refutation', (
      tester,
    ) async {
      await tester.pumpWidget(_panel(_position(note: ''), solved: true));

      expect(
        find.textContaining('allowing Nxe5.', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('→', findRichText: true), findsNothing);
    });

    testWidgets('the whole solution is on screen without a button press', (
      tester,
    ) async {
      await tester.pumpWidget(
        _panel(
          _position(line: ['Qf3', 'Kh8', 'Rxh7']),
          solved: true,
          solutionSan: const ['Qf3', 'Kh8', 'Rxh7'],
        ),
      );

      expect(find.text('Solution'), findsOneWidget);
      final line = tester.widget<ClickableMoveLineWidget>(
        find.byKey(const Key('tactic-solution-line')),
      );
      expect(line.sanMoves, ['Qf3', 'Kh8', 'Rxh7']);
      expect(find.text('Show Solution'), findsNothing);
    });

    testWidgets('reveals the full PV even when only one move is trainable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _panel(
          _position(line: ['e4']),
          solved: true,
          solutionSan: const ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'],
          trainableSan: const ['e4'],
        ),
      );

      final line = tester.widget<ClickableMoveLineWidget>(
        find.byKey(const Key('tactic-solution-line')),
      );
      expect(line.sanMoves, const ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6']);
    });

    testWidgets('feedback is plain text', (tester) async {
      await tester.pumpWidget(
        _panel(_position(), solved: true, feedback: 'Correct!'),
      );

      expect(find.text('Correct!'), findsOneWidget);
    });
  });
}
