import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
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
      // Idle Tactics shows the games home instead of a decorative board;
      // the board returns only when a puzzle session starts.
      expect(find.byType(ChessBoardWidget), findsNothing);

      // With nothing set up, both panes offer the same one thing to do — the
      // accounts button — and neither shows a username box: those live in the
      // dialog it opens.
      expect(find.text('Set up my accounts'), findsNWidgets(2));
      expect(find.byKey(const Key('accounts-setup-button')), findsOneWidget);
      expect(find.byKey(const Key('lichess-username-field')), findsNothing);
      expect(find.byKey(const Key('chesscom-username-field')), findsNothing);
      // The games window is not on this pane either — it is a section of the
      // review strip's analysis-settings dialog.
      expect(find.text('Games to download'), findsNothing);
      expect(find.text('Play tactics'), findsOneWidget);
      // The engine-settings gear is gone: cores and depth are steppers on the
      // review strip, and downloading is the review's play button, so this card
      // has neither a gear nor a per-site Import button.
      expect(find.byTooltip('Engine settings…'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Import'), findsNothing);
      // Nor a play button of its own: both live on the review strip in the left
      // pane, one under the other.
      expect(find.textContaining('Start Practice Session'), findsNothing);
    });

    testWidgets('the accounts button opens the username form', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byKey(const Key('accounts-setup-button')));
      await tester.pumpAndSettle();

      // One form, both sites, and no login anywhere in it.
      expect(find.text('My accounts'), findsOneWidget);
      expect(find.byKey(const Key('lichess-username-field')), findsOneWidget);
      expect(find.byKey(const Key('chesscom-username-field')), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lichess-username-field')), findsNothing);
    });
  });

  // ── Mode Switching ─────────────────────────────────────────────────────

  group('Mode Switching', () {
    testWidgets('popup menu shows the modes', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byKey(AppModeSwitcher.switcherKey));
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
          matching: find.text('Player analysis'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<AppMode>),
          matching: find.text('Repertoire builder'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<AppMode>),
          matching: find.text('Repertoire trainer'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<AppMode>),
          matching: find.text('Engine tournament'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('switches to Repertoire Builder', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byKey(AppModeSwitcher.switcherKey));
      await tester.pumpAndSettle();

      final menuItem = find.ancestor(
        of: find.text('Repertoire builder'),
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

      await tester.tap(find.byKey(AppModeSwitcher.switcherKey));
      await tester.pumpAndSettle();

      final menuItem = find.ancestor(
        of: find.text('Repertoire trainer'),
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
