import 'dart:async';

import 'package:flutter/services.dart';

import '../../ui/app_action.dart';
import '../../ui/pane_tabs.dart';
import '../../workspace/document_session.dart';
import '../../workspace/engine_analysis.dart';
import '../../workspace/workspace_tabs.dart';
import 'my_games.dart';
import 'puzzle_trainer.dart';

/// The Actions menu in Tactics, which is for solving: the puzzle's own
/// actions, the user's games, the board and the card's tabs — none of the
/// file and repertoire work the other modes do on the same board. The
/// engine cannot be turned on while an answer is hidden.
List<AppAction> tacticsActions({
  required PuzzleTrainer trainer,
  required MyGames games,
  required DocumentSession session,
  required EngineAnalysis analysis,
  required PaneTabs<WorkspaceTab> tabs,
  required VoidCallback onAccounts,
}) {
  final open = session.chapter != null;
  final hidden = session.shownTo != null;
  return [
    ...puzzleActions(trainer),
    ...myGamesActions(games, onAccounts: onAccounts),
    AppAction(
      'Flip board',
      open ? session.flip : null,
      shortcut: 'F',
      group: 'Board',
    ),
    AppAction(
      analysis.enabled ? 'Engine off' : 'Engine on',
      analysis.enabled || !hidden
          ? () => unawaited(
              analysis.enabled ? analysis.disable() : analysis.enable(),
            )
          : null,
      shortcut: 'E',
      group: 'Board',
    ),
    AppAction(
      'Copy FEN',
      open
          ? () => unawaited(
              Clipboard.setData(ClipboardData(text: session.fen.value)),
            )
          : null,
      group: 'Board',
    ),
    ...tabActions(tabs),
  ];
}

/// Getting the user's games, pausing that, and their usernames: the same
/// entries wherever the games are shown.
List<AppAction> myGamesActions(
  MyGames games, {
  required VoidCallback onAccounts,
}) => [
  AppAction(
    games.running ? 'Pause the review' : 'Get my games',
    games.running
        ? games.pause
        : games.accounts.isEmpty
        ? null
        : () => unawaited(games.start()),
    group: 'My games',
  ),
  AppAction(
    'My accounts…',
    games.running ? null : onAccounts,
    group: 'My games',
  ),
];

/// What can be done to the puzzle on the board, while one is.
List<AppAction> puzzleActions(PuzzleTrainer trainer) {
  final up = trainer.up;
  if (up == null) return const [];
  return [
    AppAction(
      'Show solution',
      up.finished ? null : trainer.showSolution,
      shortcut: 'Space',
      group: 'Tactics',
    ),
    AppAction(
      up.finished || up.decided != null ? 'Next puzzle' : 'Skip puzzle',
      () => unawaited(trainer.next()),
      shortcut: '↓',
      group: 'Tactics',
    ),
    AppAction(
      'Previous puzzle',
      trainer.hasPrevious ? () => unawaited(trainer.previous()) : null,
      shortcut: '↑',
      group: 'Tactics',
    ),
    AppAction('End session', trainer.end, shortcut: 'Esc', group: 'Tactics'),
  ];
}
