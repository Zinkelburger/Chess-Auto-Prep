import 'package:flutter/material.dart';
import 'package:chess_auto_prep/widgets/clickable_move_line.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';

import 'board_helpers.dart';

/// Switch modes through the app-bar title (from a freshly booted app, where
/// only one screen — and thus one switcher — has been built).
Future<void> switchToMode(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(AppModeSwitcher.switcherKey).first);
  await tester.pumpAndSettle();
  final item = find.ancestor(
    of: find.text(label),
    matching: find.byType(PopupMenuItem<AppMode>),
  );
  await tester.tap(item);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

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

/// Run the review (download → book check → engine pass) and poll until puzzles
/// exist, i.e. until the Study-tactics button reports a ready count.
///
/// This is the one way to get games into the app now: there is no per-site
/// Import button any more, because downloading and analysing are the same job
/// — the review strip's play button in the left pane. All of the home's
/// buttons live on that strip: the engine-analysis job, then Study tactics and
/// Opening review under it.
Future<void> importAndWaitForPositions(
  WidgetTester tester, {
  String username = 'DrNykterstein',
  String gameCount = '5',
  Duration pollInterval = const Duration(seconds: 2),
  int maxPolls = 60,
}) async {
  // How many games to fetch is a section of the review strip's analysis
  // settings. Set it *before* the account exists: with auto-start on by
  // default, saving a username begins the run immediately, and a window
  // changed after that would apply to the next run instead of this one. The
  // strip is on screen from boot, with no account, for exactly this kind of
  // reason. The window defaults to "my last N games", so the count field is
  // already the active one; it carries no label, hence the key.
  await tester.tap(find.byTooltip('Analysis settings…'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('window-games-field')),
    gameCount,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
  await tester.pumpAndSettle();

  // Usernames are typed in the accounts dialog now, behind the home card's
  // one button; nothing is saved until Save is pressed.
  await tester.tap(find.byKey(const Key('accounts-setup-button')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('lichess-username-field')),
    username,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('accounts-save-button')));
  await tester.pumpAndSettle();

  // The username makes the left pane load, which is what starts the run:
  // auto-start is on by default, so in the normal case nothing is pressed
  // here at all. Wait for the strip's button either way — with the run under
  // way it is Pause, and tapping it would stop the very work we are waiting
  // for.
  final reviewButton = find.byKey(const Key('review-transport-button'));
  for (int i = 0; i < maxPolls && reviewButton.evaluate().isEmpty; i++) {
    await tester.pump(pollInterval);
  }
  if (reviewButton.evaluate().isEmpty) {
    fail('The Analysis block never appeared after setting a username');
  }

  // Give the auto-start a few frames to take hold before deciding.
  for (int i = 0; i < 5 && find.byIcon(Icons.pause).evaluate().isEmpty; i++) {
    await tester.pump(pollInterval);
    if (_studyButton().evaluate().isNotEmpty) return;
  }
  if (find.byIcon(Icons.pause).evaluate().isEmpty) {
    // Auto-start did not take (turned off in a previous test's prefs, or the
    // list arrived empty first): press it by hand.
    await tester.tap(reviewButton.first);
    await tester.pump();
  }

  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(pollInterval);
    if (_studyButton().evaluate().isNotEmpty) return;
  }
  fail(
    'Play tactics never reported any puzzles after reviewing $gameCount '
    'games for $username',
  );
}

/// The Play-tactics button once it has puzzles to offer. Its label carries the
/// count ("Play tactics (12)"), which is exactly the signal that the review
/// produced something — with none it renders as a bare, disabled label.
Finder _studyButton() => find.textContaining(RegExp(r'Play tactics \(\d+\)'));

/// Tap the Play-tactics button, re-evaluating the finder after pumping so a
/// count that ticks up mid-test can't leave a stale reference behind.
Future<void> tapStartSession(WidgetTester tester) async {
  await tester.ensureVisible(_studyButton());
  await tester.pumpAndSettle();
  await tester.tap(_studyButton());
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

  final lineFinder = find.byKey(const Key('tactic-solution-line'));
  expect(lineFinder, findsOneWidget);

  final line = tester.widget<ClickableMoveLineWidget>(lineFinder);
  if (line.sanMoves.isEmpty) {
    fail('Tactic has no solution moves on the line widget');
  }

  return line.sanMoves;
}

/// Play the user moves from a tactic solution via the tactics session controller.
///
/// [allMoves] is the interleaved list [userMove, opponentResponse, ...].
/// Only user moves (even indices) are played; opponent moves are automatic.
Future<void> playTacticMoves(WidgetTester tester, List<String> allMoves) async {
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
    expect(
      uci,
      isNotNull,
      reason: 'Cannot parse move "$moveStr" for FEN: $fenBefore',
    );

    print('  Playing "$moveStr" as UCI "$uci"');

    await playMoveViaAppState(tester, uci!);

    final fenAfter = getAppState(tester).currentPosition.fen;
    expect(
      fenAfter,
      isNot(equals(fenBefore)),
      reason: 'Board should change after "$moveStr" (UCI: $uci)',
    );

    final feedback = find.textContaining('Correct');
    if (feedback.evaluate().isEmpty) {
      break;
    }

    // Wait for opponent response before next user move
    if (idx < userMoveIndices.length - 1) {
      await tester.pump(const Duration(milliseconds: 1200));
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
    reason:
        'Expected "Correct!" or auto-advance (Show Solution). Found neither.',
  );
}
