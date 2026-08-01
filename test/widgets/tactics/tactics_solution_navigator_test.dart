/// Show Solution walks the solution as a variation off the tactic's own ply
/// inside the source game — it is not the PGN mainline, and revealing it must
/// not throw away the moves the player tried.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:chess_auto_prep/widgets/tactics/tactics_solution_navigator.dart';

/// A full source game; the tactic sits six plies in, at White's 4th move.
const _gamePgn = '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. d3 d6';
const _tacticPly = 6;

Position _positionAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = pos.play(pos.parseSan(san)!);
  }
  return pos;
}

TacticsPosition _tacticAt(String fen) => TacticsPosition(
  fen: fen,
  userMove: 'd2d3',
  correctLine: const ['f3g5', 'g8h6'],
  mistakeType: '?',
  mistakeAnalysis: '',
  positionContext: 'Move 4, White to play',
  gameWhite: 'W',
  gameBlack: 'B',
  gameResult: '*',
  gameDate: '',
  gameId: 'g1',
);

class _Harness {
  _Harness(this.controller, this.navigator);

  final PgnViewerWidgetController controller;
  final TacticsSolutionNavigator navigator;

  /// Last position the navigator wrote to the board.
  Position? boardPosition;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required List<String> solution,
}) async {
  final controller = PgnViewerWidgetController();
  final tactic = _tacticAt(
    _positionAfter(const ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']).fen,
  );
  late final _Harness harness;
  harness = _Harness(
    controller,
    TacticsSolutionNavigator(
      pgn: controller,
      currentTactic: () => tactic,
      solutionToSan: (_) => solution,
      setBoardPosition: (position) => harness.boardPosition = position,
    ),
  );

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PgnViewerWidget(pgnText: _gamePgn, controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(controller.mainLineLength, 8, reason: 'game should have loaded');
  return harness;
}

void main() {
  testWidgets('the solution branches off the tactic ply, not the game start', (
    tester,
  ) async {
    final h = await _pump(tester, solution: const ['Ng5', 'Nh6']);

    h.navigator.navigateToIndex(0);
    await tester.pumpAndSettle();

    expect(
      h.controller.mainLineIndex,
      _tacticPly,
      reason: 'the cursor parks on the tactic position inside the game',
    );
    expect(h.controller.inVariation, isTrue);
    expect(find.text('Ng5'), findsOneWidget);
    expect(
      h.boardPosition!.fen,
      _positionAfter(const ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'Ng5']).fen,
    );
  });

  testWidgets('revealing the solution keeps the moves the player tried', (
    tester,
  ) async {
    final h = await _pump(tester, solution: const ['Ng5', 'Nh6']);

    // The player's own attempt, recorded at the board while solving.
    h.controller.goToMainLineIndex(_tacticPly);
    await tester.pumpAndSettle();
    h.controller.addEphemeralMove('Qe2');
    await tester.pumpAndSettle();

    h.navigator.navigateToIndex(0);
    await tester.pumpAndSettle();

    expect(find.text('Qe2'), findsOneWidget, reason: 'attempt not wiped');
    expect(find.text('Ng5'), findsOneWidget);
  });

  testWidgets('stepping through the line and back stays anchored', (
    tester,
  ) async {
    final h = await _pump(tester, solution: const ['Ng5', 'Nh6']);

    h.navigator.navigateToIndex(0);
    await tester.pumpAndSettle();
    expect(h.navigator.arrowForward(), isTrue);
    await tester.pumpAndSettle();

    expect(h.navigator.activeIndex, 1);
    expect(h.controller.mainLineIndex, _tacticPly);
    expect(find.text('Nh6'), findsOneWidget);
    // Walking past the end of the line does nothing.
    expect(h.navigator.arrowForward(), isFalse);

    expect(h.navigator.arrowBack(), isTrue);
    await tester.pumpAndSettle();
    expect(h.navigator.arrowBack(), isTrue);
    await tester.pumpAndSettle();

    expect(h.navigator.activeIndex, isNull);
    expect(h.controller.mainLineIndex, _tacticPly);
    expect(h.controller.inVariation, isFalse, reason: 'back on the game line');
    expect(h.navigator.arrowBack(), isFalse);
  });

  testWidgets('a legacy puzzle whose PGN starts at the tactic still anchors', (
    tester,
  ) async {
    // No source game was captured, so the analysis tab falls back to the
    // solution-only PGN: the tactic position *is* the start of the game.
    final tacticFen = _positionAfter(const [
      'e4',
      'e5',
      'Nf3',
      'Nc6',
      'Bc4',
      'Bc5',
    ]).fen;
    final controller = PgnViewerWidgetController();
    Position? board;
    final navigator = TacticsSolutionNavigator(
      pgn: controller,
      currentTactic: () => _tacticAt(tacticFen),
      solutionToSan: (_) => const ['Ng5', 'Nh6'],
      setBoardPosition: (position) => board = position,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText: '[SetUp "1"]\n[FEN "$tacticFen"]\n\n4. Ng5 Nh6 *',
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigator.navigateToIndex(1);
    await tester.pumpAndSettle();

    expect(controller.mainLineIndex, 2, reason: 'the solution is the mainline');
    expect(controller.hasEphemeralMoves, isFalse);
    expect(board, isNotNull);
  });

  testWidgets('a solution the game actually played follows the mainline', (
    tester,
  ) async {
    // 4. d3 is both the game's move and (here) the solution: it must not be
    // duplicated as a sideline beside itself.
    final h = await _pump(tester, solution: const ['d3']);

    h.navigator.navigateToIndex(0);
    await tester.pumpAndSettle();

    expect(h.controller.mainLineIndex, _tacticPly + 1);
    expect(h.controller.inVariation, isFalse);
    expect(h.controller.hasEphemeralMoves, isFalse);
    expect(find.text('d3'), findsOneWidget);
  });
}
