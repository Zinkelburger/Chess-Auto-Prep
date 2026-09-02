/// Where a recent game opens when clicked, and where an opening leak opens
/// when you want to fix it. Shared by the games list (left pane) and the home
/// column (right pane), which are siblings and cannot call each other.
library;

import '../../../core/app_state.dart';
import '../models/recent_game.dart';
import 'game_moments.dart';
import 'opening_review.dart';

/// Open one game in the viewer, on the tab that answers the question the
/// user clicked on, optionally parked on one position. Only the Analysis tab
/// is worth an engine pass on arrival.
void openRecentGame(
  AppState appState,
  RecentGame game, {
  PgnViewerTab tab = PgnViewerTab.game,
  int? ply,
}) {
  appState.switchToPgnViewer(
    path: game.cachePath,
    gameId: game.record.dedupKey,
    tab: tab,
    ply: ply,
    autoAnalyze: tab == PgnViewerTab.analysis,
    historyLabel: 'Game: ${game.white} vs ${game.black}',
  );
}

/// Open the game at one of its moments: the analysis at a mistake, the line
/// tab where the book was left.
void openGameMoment(AppState appState, RecentGame game, GameMoment moment) =>
    openRecentGame(appState, game, tab: moment.tab, ply: moment.ply);

/// The deliberate trip to the builder: editing the book, not reviewing it.
void openLineInBuilder(AppState appState, OpeningReviewEntry entry) {
  appState.switchToBuilder(
    repertoirePath: entry.chapterPath,
    moveSequence: entry.pathSans,
    historyLabel: 'Repertoire: ${entry.chapterName}',
  );
}
