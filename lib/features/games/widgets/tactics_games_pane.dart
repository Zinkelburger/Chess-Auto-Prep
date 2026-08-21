import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../screens/settings_screen.dart';
import '../../../services/tactics/tactics_import_coordinator.dart';
import '../../../services/tactics/tactics_session_controller.dart';
import '../../../services/tactics/tactics_database.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/list_search_field.dart';
import '../../../widgets/engine/engine_gate.dart';
import '../controllers/recent_games_controller.dart';
import '../models/recent_game.dart';
import '../services/home_review_runner.dart';
import '../services/my_repertoire_settings.dart';
import '../services/opening_review.dart';
import 'game_card.dart';
import 'games_home_header.dart';
import 'home_review_settings_dialog.dart';
import 'opening_review_dialog.dart';
import 'review_strip.dart';

/// The recent-games half of the unified Tactics home: who you are, the review
/// job, then your games as cards. Shown in the Tactics screen's left pane
/// whenever no puzzle is active; the board takes the pane back during a
/// session.
///
/// Nothing here starts the engine on its own — the review waits for its play
/// button (see [HomeReviewRunner]).
///
/// Layout rule: the header and the review strip are always on screen — even
/// with no account set. Only the *list* area shows loading and empty states;
/// hiding the play button until games arrived meant the one control that
/// fetches them was missing exactly when it was needed. The usernames are
/// edited on the accounts card in the right pane (each box has a title
/// there); this pane only *shows* whose games it lists.
///
/// The [RecentGamesController] and [HomeReviewRunner] are provided by
/// `_TacticsModeView` (they must outlive this widget: the pane is swapped out
/// for the board mid-session and neither the list nor a running review should
/// restart when it comes back).
class TacticsGamesPane extends StatefulWidget {
  const TacticsGamesPane({super.key});

  @override
  State<TacticsGamesPane> createState() => _TacticsGamesPaneState();
}

class _TacticsGamesPaneState extends State<TacticsGamesPane> {
  RecentGamesController? _controller;
  HomeReviewRunner? _runner;
  AppState? _appState;

  /// Guard so the opt-in auto-run fires at most once per app session, however
  /// many times the pane is rebuilt or swapped back in.
  static bool _autoRunAttempted = false;

  /// Type-to-filter over the loaded games. Narrows the list only — the window
  /// and time-control filters (gear dialog) still decide what gets fetched.
  String _search = '';

  @override
  void initState() {
    super.initState();
    MyRepertoireSettings.instance.addListener(_onRepertoireSettingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      final controller = context.read<RecentGamesController>();
      _appState = appState;
      _controller = controller;
      _runner = context.read<HomeReviewRunner>();
      appState.addListener(_onAppStateChanged);
      controller.addListener(_onControllerChanged);
      controller.ensureLoaded();
    });
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    _controller?.removeListener(_onControllerChanged);
    MyRepertoireSettings.instance.removeListener(_onRepertoireSettingsChanged);
    super.dispose();
  }

  void _onAppStateChanged() {
    // Usernames load async at startup and can change in Settings; the first
    // notification that provides one (while this pane is visible) loads the
    // list. ensureLoaded is a no-op after the first successful load.
    if (_appState?.currentMode == AppMode.tactics) _controller?.ensureLoaded();
  }

  void _onControllerChanged() => _maybeAutoRun();

  void _onRepertoireSettingsChanged() {
    final controller = _controller;
    if (controller != null && controller.hasLoadedOnce) {
      unawaited(controller.recomputeDeviations());
    }
  }

  /// Opt-in only: the review costs every core for minutes, so it starts itself
  /// exactly when the user asked it to in the settings dialog.
  void _maybeAutoRun() {
    final controller = _controller;
    final runner = _runner;
    if (controller == null || runner == null) return;
    if (!controller.hasLoadedOnce || controller.isLoading) return;
    if (!controller.filters.autoRun || _autoRunAttempted) return;
    _autoRunAttempted = true;
    unawaited(runner.start());
  }

  void _startReview() {
    // The review is an engine pass — refuse while tree generation holds
    // Stockfish, with the same message every other engine consumer shows.
    if (!EngineGate.ensureAvailable(context)) return;
    unawaited(_runner?.start());
  }

  /// Open one game in the PGN viewer, on the tab that answers the question the
  /// user clicked on.
  void _openGame(RecentGame game, {PgnViewerTab tab = PgnViewerTab.game}) {
    context.read<AppState>().switchToPgnViewer(
      path: game.cachePath,
      gameId: game.record.dedupKey,
      tab: tab,
      // Only the Analysis tab is worth an engine pass on arrival; opening a
      // game to read it, or to see the line it left, should not start one.
      autoAnalyze: tab == PgnViewerTab.analysis,
      historyLabel: 'Game: ${game.white} vs ${game.black}',
    );
  }

  /// All the window's deviations in one dialog — reviewable as a queue,
  /// like tactics, instead of clicking into each game.
  Future<void> _showOpeningReview() async {
    final controller = _controller;
    if (controller == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => OpeningReviewDialog(
        data: aggregateOpeningReview(controller.games),
        windowLabel: controller.window.label,
        onEditLine: _openLineInBuilder,
        onOpenGame: (game) => _openGame(game, tab: PgnViewerTab.line),
      ),
    );
  }

  /// The deliberate trip to the builder: editing the book, not reviewing it.
  void _openLineInBuilder(OpeningReviewEntry entry) {
    context.read<AppState>().switchToBuilder(
      repertoirePath: entry.chapterPath,
      moveSequence: entry.pathSans,
      historyLabel: 'Repertoire: ${entry.chapterName}',
    );
  }

  Future<void> _showSettingsDialog() async {
    final controller = _controller;
    if (controller == null) return;
    final result = await showDialog<HomeReviewSettingsResult>(
      context: context,
      builder: (_) => HomeReviewSettingsDialog(filters: controller.filters),
    );
    if (result != null) {
      await controller.setFilters(result.filters);
      // A different set of games means "review complete" was about the old
      // set — back to the resting state so the button reads honestly.
      _runner?.reset();
    }
  }

  void _openSettings() {
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
    );
  }

  /// Step two of the loop: play the puzzles the review found. The button is
  /// here, next to Review games; setting a puzzle up is the control panel's
  /// job, so it is asked through the shared session controller (the two panes
  /// are siblings and can't call each other).
  void _studyTactics() {
    context.read<TacticsSessionController>().onStartRequested?.call();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.read<RecentGamesController>();
    final runner = context.read<HomeReviewRunner>();
    final coordinator = context.read<TacticsImportCoordinator>();
    final database = context.read<TacticsDatabase>();
    final session = context.read<TacticsSessionController>();
    return ListenableBuilder(
      // The coordinator reports each reviewed game, so the strip's counters and
      // the rows' mistake counts fill in while the review runs. The database and
      // session join them for the Study-tactics button's ready count — puzzles
      // stream in during a review, so the number has to keep up.
      listenable: Listenable.merge([
        controller,
        runner,
        coordinator,
        database,
        session,
      ]),
      builder: (context, _) => _buildBody(
        context,
        controller,
        runner,
        coordinator,
        database,
        session,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    RecentGamesController controller,
    HomeReviewRunner runner,
    TacticsImportCoordinator coordinator,
    TacticsDatabase database,
    TacticsSessionController session,
  ) {
    // Usernames come out of prefs asynchronously at startup; until that read
    // finishes, "no usernames" may just mean "still loading" — don't flash
    // the no-accounts card at a configured user.
    final usernamesLoaded = context.select<AppState, bool>(
      (s) => s.usernamesLoaded,
    );
    if (!usernamesLoaded && !controller.hasAnyUsername) {
      return const Center(child: CircularProgressIndicator());
    }
    final games = controller.games;
    // Cheap enough to recompute per build (a walk over ≤ a window of games,
    // no IO) and it has to be: the count on the Opening-review button ticks up
    // as the analysis reports each game.
    final openingReview = aggregateOpeningReview(games);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GamesHomeHeader(controller: controller),
        ReviewStrip(
          runner: runner,
          coordinator: coordinator,
          isLoadingGames: controller.isLoading,
          gamesInWindow: games.length,
          unreviewedCount: games
              .where((g) => g.meWhite != null && g.summary == null)
              .length,
          windowLabel: controller.window.label,
          readyPuzzleCount: session.sessionSettings.countMatching(
            database.positions,
          ),
          openingIssueCount:
              openingReview.mistakes.length + openingReview.bookEnds.length,
          autoRun: controller.filters.autoRun,
          onAutoRunChanged: controller.setAutoRun,
          onStart: _startReview,
          onPause: runner.pause,
          onStudyTactics: _studyTactics,
          onRefresh: () => controller.refresh(force: true),
          onSettings: _showSettingsDialog,
          onOpeningReview: _showOpeningReview,
        ),
        Expanded(child: _buildList(controller)),
      ],
    );
  }

  Widget _buildList(RecentGamesController controller) {
    if (!controller.hasAnyUsername) {
      return _EmptyStateCard(
        icon: Icons.person_off,
        title: 'No accounts configured',
        message:
            'Type your username on the My accounts card to the right — or in '
            'Settings → Accounts — and your recent games will appear here.',
        buttonLabel: 'Open Settings',
        onPressed: _openSettings,
      );
    }
    if (controller.isLoading && controller.games.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              controller.statusMessage ?? 'Loading games…',
              style: AppTextStyles.body.copyWith(
                color: AppColors.onSurfaceSoft,
              ),
            ),
          ],
        ),
      );
    }
    if (controller.games.isEmpty) {
      return _EmptyStateCard(
        icon: Icons.cloud_off,
        title: 'No games found',
        message:
            controller.error ??
            'Nothing in your ${controller.window.label} matched the current '
                'time controls.',
        buttonLabel: 'Try again',
        onPressed: () => controller.refresh(force: true),
      );
    }
    final games = [
      for (final game in controller.games)
        if (matchesSearch(_search, _gameHaystack(game))) game,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: ListSearchField(
            hintText: 'Search by opponent, opening or date',
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(
          child: games.isEmpty
              ? Center(
                  child: Text(
                    'No games match "$_search"',
                    style: AppTextStyles.body.copyWith(
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: games.length,
                  itemBuilder: (context, index) {
                    final game = games[index];
                    return GameCard(
                      game: game,
                      onOpen: () => _openGame(game),
                      onOpenAnalysis: () =>
                          _openGame(game, tab: PgnViewerTab.analysis),
                      onOpenLine: () => _openGame(game, tab: PgnViewerTab.line),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// What a game can be looked up by: either player's name (so it works
  /// whichever side you had), the opening, and the date as displayed.
  String _gameHaystack(RecentGame game) =>
      '${game.white} ${game.black} ${game.openingName ?? ''} '
      '${game.dateDisplay}';
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          color: AppColors.surfaceElevated,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 40, color: AppColors.onSurfaceMuted),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: AppTextStyles.body.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.body.copyWith(
                    fontSize: 13,
                    color: AppColors.onSurfaceSoft,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
