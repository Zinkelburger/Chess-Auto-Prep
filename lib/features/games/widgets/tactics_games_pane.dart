import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/accounts/accounts_dialog.dart';
import '../../../widgets/common/list_search_field.dart' show matchesSearch;
import '../controllers/recent_games_controller.dart';
import '../models/recent_game.dart';
import '../services/home_review_runner.dart';
import '../services/my_repertoire_settings.dart';
import '../services/recent_game_navigation.dart';
import 'game_card.dart';
import 'games_home_header.dart';

/// The games half of the tactics home: a one-line header, then your games as
/// cards. Shown in the Tactics screen's left pane whenever no puzzle is
/// active; the board takes the pane back during a session.
///
/// Only the list lives here. The engine analysis, the opening review and the
/// play button are blocks of the home column on the right (see
/// `TacticsImportPanel`); this pane is never anything but your games.
///
/// Auto-start still lives here, because the list is what triggers it: the
/// first load with games in it starts the run (see [_maybeAutoRun]).
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

  /// Guard so the auto-run fires at most once per app session, however many
  /// times the pane is rebuilt or swapped back in. Only a run that actually
  /// started spends it — see [_maybeAutoRun].
  static bool _autoRunAttempted = false;

  /// Type-to-filter over the loaded games. Narrows the list only — the window
  /// and time-control filters (analysis settings) still decide what gets
  /// fetched.
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

  /// Check for new games and start the review after the first cached load.
  ///
  /// On by default (see [GamesListFilters.autoRun]), which is what makes
  /// setting a username enough: the save loads the list, the list's first
  /// completed load lands here, and a fresh download-and-analyse run begins
  /// without anyone pressing anything. Unchecking Auto-start in the analysis
  /// settings stops that.
  ///
  /// The one-shot guard is only spent on a run that really starts. A pane that
  /// loaded with no account, or while a run was already going, stays armed —
  /// otherwise the very first visit (no username yet) would silently use up
  /// the session's auto-run and typing a name would sit there doing nothing.
  void _maybeAutoRun() {
    final controller = _controller;
    final runner = _runner;
    if (controller == null || runner == null) return;
    if (!controller.hasLoadedOnce || controller.isLoading) return;
    if (!controller.filters.autoRun || _autoRunAttempted) return;
    if (!runner.hasAnySource || runner.isRunning) return;
    _autoRunAttempted = true;
    unawaited(runner.start(checkForNewGames: true));
  }

  void _openGame(RecentGame game, {PgnViewerTab tab = PgnViewerTab.game}) =>
      openRecentGame(context.read<AppState>(), game, tab: tab);

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RecentGamesController>();
    // Usernames come out of prefs asynchronously at startup; until that read
    // finishes, "no usernames" may just mean "still loading" — don't flash
    // the no-accounts card at a configured user.
    final usernamesLoaded = context.select<AppState, bool>(
      (s) => s.usernamesLoaded,
    );
    if (!usernamesLoaded && !controller.hasAnyUsername) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GamesHomeHeader(
          controller: controller,
          onSearchChanged: (v) => setState(() => _search = v),
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
            'Add your Lichess or Chess.com username and your recent games '
            'appear here.',
        buttonLabel: 'Set up my accounts',
        onPressed: () => showAccountsDialog(context),
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
              style: AppTextStyles.muted,
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
    if (games.isEmpty) {
      return Center(
        child: Text('No games match "$_search"', style: AppTextStyles.muted),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: games.length,
      itemBuilder: (context, index) {
        final game = games[index];
        return GameCard(
          game: game,
          onOpen: () => _openGame(game),
          onOpenAnalysis: () => _openGame(game, tab: PgnViewerTab.analysis),
          onOpenLine: () => _openGame(game, tab: PgnViewerTab.line),
          onOpenMoment: (moment) =>
              openGameMoment(context.read<AppState>(), game, moment),
        );
      },
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
                Text(title, style: AppTextStyles.emptyStateTitle),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.emptyStateBody,
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
