/// The tactics screen drives two views at once — the board and the PGN tree.
/// Every write to either goes through [TacticsBoardBridge], so these pin that
/// the pair moves together whichever way a move arrives.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/controllers/tactics_session_controller.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_board_bridge.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_solution_navigator.dart';

/// A full source game; the tactic sits six plies in, at White's 4th move.
const _gamePgn = '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. d3 d6';
const _tacticPly = 6;
const _tacticLine = ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5'];

Position _positionAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = pos.play(pos.parseSan(san)!);
  }
  return pos;
}

class _Harness {
  _Harness(this.controller);

  final PgnViewerWidgetController controller;
  late final TacticsBoardBridge bridge;

  /// Stands in for AppState's board.
  Position board = Chess.initial;
  bool flipped = false;
  int gameChangedCount = 0;
}

Future<_Harness> _pump(WidgetTester tester) async {
  final controller = PgnViewerWidgetController();
  final h = _Harness(controller);
  final tacticFen = _positionAfter(_tacticLine).fen;
  h.board = _positionAfter(_tacticLine);
  h.bridge = TacticsBoardBridge(
    pgn: controller,
    solutionNav: TacticsSolutionNavigator(
      pgn: controller,
      currentTactic: () => TacticsPosition(
        fen: tacticFen,
        userMove: 'd2d3',
        correctLine: const ['f3g5'],
        mistakeType: '?',
        mistakeAnalysis: '',
        gameWhite: 'W',
        gameBlack: 'B',
        gameResult: '*',
        gameDate: '',
        gameId: 'g1',
      ),
      solutionToSan: (_) => const ['Ng5'],
      setBoardPosition: (position) => h.board = position,
    ),
    currentPosition: () => h.board,
    setPosition: (position) => h.board = position,
    setFlipped: (value) => h.flipped = value,
    notifyGameChanged: () => h.gameChangedCount++,
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
  controller.goToFen(tacticFen);
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('a played move lands on the board and in the PGN tree', (
    tester,
  ) async {
    final h = await _pump(tester);

    expect(h.bridge.playMove('f3g5'), isTrue);
    await tester.pumpAndSettle();

    expect(h.board.fen, _positionAfter([..._tacticLine, 'Ng5']).fen);
    expect(h.gameChangedCount, 1);
    expect(
      find.text('Ng5'),
      findsOneWidget,
      reason: 'the move is recorded as a variation off the tactic ply',
    );
  });

  testWidgets('an opponent reply arriving as a FEN still reaches the PGN', (
    tester,
  ) async {
    final h = await _pump(tester);
    final after = _positionAfter([..._tacticLine, 'Ng5']);

    expect(
      h.bridge.applyUpdate(TacticsBoardUpdate(setFen: after.fen, san: 'Ng5')),
      isTrue,
    );
    await tester.pumpAndSettle();

    expect(h.board.fen, after.fen);
    expect(find.text('Ng5'), findsOneWidget);
  });

  testWidgets('an unparseable move or FEN is reported, not thrown', (
    tester,
  ) async {
    final h = await _pump(tester);
    final before = h.board.fen;

    expect(h.bridge.playMove('zz9z9'), isFalse);
    expect(
      h.bridge.applyUpdate(const TacticsBoardUpdate(setFen: 'not a fen')),
      isFalse,
    );
    expect(h.board.fen, before, reason: 'the board is left where it was');
  });

  testWidgets('showPosition sets the board and the orientation together', (
    tester,
  ) async {
    final h = await _pump(tester);
    final target = _positionAfter(const ['e4', 'e5']);

    expect(
      h.bridge.showPosition(
        TacticsPositionSetup(fen: target.fen, flipBoard: true),
      ),
      isNull,
    );
    expect(h.board.fen, target.fen);
    expect(h.flipped, isTrue);

    // A bad FEN comes back as a message for the caller to surface.
    expect(
      h.bridge.showPosition(
        const TacticsPositionSetup(fen: 'nonsense', flipBoard: false),
      ),
      isNotNull,
    );
  });

  testWidgets('resetToStart puts the standard position back, unflipped', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.bridge.showPosition(
      TacticsPositionSetup(fen: h.board.fen, flipBoard: true),
    );

    h.bridge.resetToStart();

    expect(h.board.fen, Chess.initial.fen);
    expect(h.flipped, isFalse);
  });

  testWidgets('resetToTactic drops scratch moves and parks on the tactic ply', (
    tester,
  ) async {
    final h = await _pump(tester);
    final tacticFen = _positionAfter(_tacticLine).fen;

    // The player tries something at the board, then the puzzle is reloaded.
    h.bridge.playMove('d1e2');
    await tester.pumpAndSettle();
    expect(find.text('Qe2'), findsOneWidget);

    h.bridge.resetToTactic(tacticFen);
    await tester.pumpAndSettle();

    expect(find.text('Qe2'), findsNothing);
    expect(h.controller.mainLineIndex, _tacticPly);
  });

  testWidgets('resetToTactic falls back to the game start for an alien FEN', (
    tester,
  ) async {
    final h = await _pump(tester);

    h.bridge.resetToTactic(_positionAfter(const ['d4']).fen);
    await tester.pumpAndSettle();

    expect(h.controller.mainLineIndex, 0);
  });
}
