import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ── App Launch ─────────────────────────────────────────────────────────

  group('App Launch', () {
    testWidgets('boots into Tactics mode with import controls visible',
        (tester) async {
      await pumpApp(tester);

      expect(find.text('Tactics'), findsOneWidget);
      expect(find.byType(ChessBoardWidget), findsOneWidget);
      expect(find.text('Import Games'), findsOneWidget);
      expect(find.text('Lichess Username'), findsOneWidget);
      expect(find.text('Chess.com Username'), findsOneWidget);
      expect(find.text('Stockfish Depth'), findsOneWidget);
    });
  });

  // ── Mode Switching ─────────────────────────────────────────────────────

  group('Mode Switching', () {
    testWidgets('popup menu shows all four modes', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.view_module));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<AppMode>),
          matching: find.text('Tactics'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<AppMode>),
          matching: find.text('Player Analysis'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<AppMode>),
          matching: find.text('Repertoire Builder'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<AppMode>),
          matching: find.text('Repertoire Trainer'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('switches to Repertoire Builder', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.view_module));
      await tester.pumpAndSettle();

      final menuItem = find.ancestor(
        of: find.text('Repertoire Builder'),
        matching: find.byType(PopupMenuItem<AppMode>),
      );
      await tester.tap(menuItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(getAppState(tester).currentMode, equals(AppMode.repertoire));
    });

    testWidgets('switches to Repertoire Trainer', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.view_module));
      await tester.pumpAndSettle();

      final menuItem = find.ancestor(
        of: find.text('Repertoire Trainer'),
        matching: find.byType(PopupMenuItem<AppMode>),
      );
      await tester.tap(menuItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(getAppState(tester).currentMode, equals(AppMode.repertoireTrainer));
    });
  });

  // ── Tactics End-to-End ─────────────────────────────────────────────────

  group('Tactics — End-to-End', () {
    testWidgets(
      'import, start, show solution, play moves, complete tactic',
      (tester) async {
        await pumpApp(tester);

        await importAndWaitForPositions(tester);
        await tapStartSession(tester);
        expectTacticLoaded();

        final allMoves = await showSolutionAndParseMoves(tester);
        print('Solution moves: $allMoves');

        await playTacticMoves(tester, allMoves);
        await expectTacticCompleted(tester);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  // ── Chess Board ────────────────────────────────────────────────────────

  group('Chess Board', () {
    testWidgets('board renders at initial position', (tester) async {
      await pumpApp(tester);

      final board = find.byType(ChessBoardWidget);
      expect(board, findsOneWidget);

      final boardWidget = tester.widget<ChessBoardWidget>(board);
      expect(boardWidget.position.fen,
          contains('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR'));
    });
  });
}
