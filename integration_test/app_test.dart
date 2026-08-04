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
    testWidgets('boots into the unified Tactics home', (tester) async {
      await pumpApp(tester);

      // App-bar title. At the root of the history the breadcrumb trail is
      // deliberately absent — a lone crumb would just repeat this title.
      expect(find.text('Tactics'), findsWidgets);

      // Left pane: the recent-games home. A fresh environment has no
      // usernames configured, so its empty-state card shows.
      expect(find.text('No accounts configured'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
      // Idle Tactics shows the games home instead of a decorative board;
      // the board returns only when a puzzle session starts.
      expect(find.byType(ChessBoardWidget), findsNothing);

      // Left pane header: the Lichess username box is on screen even before a
      // name is typed. The Chess.com field stays on the accounts card.
      expect(find.byKey(const Key('lichess-username-field')), findsOneWidget);

      // Right pane: who you are, and what is in the puzzle database.
      expect(find.text('My accounts'), findsOneWidget);
      expect(find.text('Chess.com Username'), findsOneWidget);
      expect(find.text('My tactics'), findsOneWidget);
      // The engine-settings gear is gone: cores and depth are steppers on the
      // review strip, and downloading is the review's play button, so this card
      // has neither a gear nor a per-site Import button.
      expect(find.byTooltip('Engine settings…'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Import'), findsNothing);
      // Nor a play button of its own: both live on the review strip in the left
      // pane, one under the other.
      expect(find.textContaining('Start Practice Session'), findsNothing);
    });
  });

  // ── Mode Switching ─────────────────────────────────────────────────────

  group('Mode Switching', () {
    testWidgets('popup menu shows the modes', (tester) async {
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

      expect(
        getAppState(tester).currentMode,
        equals(AppMode.repertoireTrainer),
      );
    });
  });
}
