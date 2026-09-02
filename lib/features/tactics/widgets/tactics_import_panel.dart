import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/accounts/accounts_card.dart';
import '../../../widgets/engine/engine_gate.dart';
import '../../../services/master_games/master_games_service.dart';
import '../../../widgets/labeled_toggle.dart';
import '../../games/controllers/recent_games_controller.dart';
import '../../games/services/home_review_runner.dart';
import '../../games/services/opening_review.dart';
import '../../games/services/recent_game_navigation.dart';
import '../../games/widgets/analysis_block.dart';
import '../../games/widgets/home_block.dart';
import '../../games/widgets/home_review_settings_dialog.dart';
import '../../games/widgets/my_books_row.dart';
import '../../games/widgets/opening_review_dialog.dart';
import '../../master_games/widgets/master_games_browser.dart';
import '../controllers/tactics_session_controller.dart';
import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import '../services/tactics_import_coordinator.dart';

part 'tactics_import_panel_start_card.dart';
part 'tactics_import_panel_widgets.dart';

/// The tactics home column, when no puzzle is active: three blocks ordered by
/// how often you press them — Play, Analysis, Openings — over a footer that
/// states the accounts the games come from and the books they are checked
/// against.
///
/// It is the one place a session starts. The play button used to have a
/// twin on the left ("Study tactics") and the analysis lived in a strip over
/// the games list with a checkbox, a refresh, a gear, a CPU sentence and a
/// pulsing green button; that strip is gone. The left pane is only ever your
/// games, and everything configurational is behind the Analysis block's gear.
///
/// The analysis and openings blocks read the games controller, the runner and
/// the import coordinator from context, nullably: the panel is also pumped in
/// widget tests with only a session in scope, and then it is the Play block
/// and the footer.
///
/// Layout rule: the structure is static. Blocks never collapse, reorder, or
/// appear/disappear in reaction to state.
class TacticsImportPanel extends StatefulWidget {
  const TacticsImportPanel({
    super.key,
    required this.isImporting,
    required this.positions,
    required this.onBrowseTactics,
  });

  final bool isImporting;
  final List<TacticsPosition> positions;
  final VoidCallback onBrowseTactics;

  @override
  State<TacticsImportPanel> createState() => _TacticsImportPanelState();
}

/// Shared state for [TacticsImportPanel]: what the block mixins read. The
/// concrete [_TacticsImportPanelState] applies them and keeps the lifecycle
/// hooks and [build].
abstract class _TacticsImportPanelStateBase extends State<TacticsImportPanel> {
  /// The practice filters, owned by [TacticsSessionController].
  TacticsSessionSettings get _settings =>
      context.read<TacticsSessionController>().sessionSettings;
}

class _TacticsImportPanelState extends _TacticsImportPanelStateBase
    with _TacticsImportPanelStartCard {
  @override
  void initState() {
    super.initState();
    // Restore the user's last-used session settings into the shared controller
    // (save: false — this *is* what was saved).
    unawaited(
      TacticsSessionSettings.load().then((saved) {
        if (!mounted) return;
        context.read<TacticsSessionController>().setSessionSettings(
          saved,
          save: false,
        );
      }),
    );
  }

  void _startReview(HomeReviewRunner runner) {
    // The review is an engine pass — refuse while tree generation holds
    // Stockfish, with the same message every other engine consumer shows.
    if (!EngineGate.ensureAvailable(context)) return;
    unawaited(runner.start());
  }

  Future<void> _showSettingsDialog(
    RecentGamesController controller,
    HomeReviewRunner runner,
  ) async {
    final result = await showDialog<HomeReviewSettingsResult>(
      context: context,
      builder: (_) => HomeReviewSettingsDialog(
        filters: controller.filters,
        window: controller.window,
      ),
    );
    if (result != null) {
      await controller.setFilters(result.filters, window: result.window);
      // A different set of games means "analysis complete" was about the old
      // set — back to the resting state so the button reads honestly.
      runner.reset();
    }
  }

  /// All the window's deviations in one dialog — reviewable as a queue, like
  /// tactics, instead of clicking into each game.
  Future<void> _showOpeningReview(RecentGamesController controller) async {
    final appState = context.read<AppState>();
    await showDialog<void>(
      context: context,
      builder: (_) => OpeningReviewDialog(
        data: aggregateOpeningReview(controller.games),
        windowLabel: controller.window.label,
        onEditLine: (entry) => openLineInBuilder(appState, entry),
        onOpenGame: (game) =>
            openRecentGame(appState, game, tab: PgnViewerTab.line),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final positionCount = widget.positions.length;
    // Nullable: absent in widget tests that pump the panel on its own.
    final games = context.watch<RecentGamesController?>();
    final runner = context.watch<HomeReviewRunner?>();
    final coordinator = context.watch<TacticsImportCoordinator?>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPlayBlock(positionCount),
        if (games != null && runner != null && coordinator != null) ...[
          const SizedBox(height: 8),
          _buildAnalysisBlock(games, runner, coordinator),
          const SizedBox(height: 8),
          _buildOpeningsBlock(games),
        ],
        const SizedBox(height: 16),
        const Divider(height: 1, thickness: 1, color: AppColors.divider),
        const SizedBox(height: 8),
        const AccountsCard(),
        const SizedBox(height: 4),
        const MyBooksRow(),
      ],
    );
  }

  Widget _buildAnalysisBlock(
    RecentGamesController games,
    HomeReviewRunner runner,
    TacticsImportCoordinator coordinator,
  ) {
    final list = games.games;
    return AnalysisBlock(
      runner: runner,
      coordinator: coordinator,
      isLoadingGames: games.isLoading,
      gamesInWindow: list.length,
      unreviewedCount: list
          .where((g) => g.meWhite != null && g.summary == null)
          .length,
      windowLabel: games.window.label,
      onStart: () => _startReview(runner),
      onPause: runner.pause,
      onRefresh: () => games.refresh(force: true),
      onSettings: () => _showSettingsDialog(games, runner),
    );
  }

  Widget _buildOpeningsBlock(RecentGamesController games) {
    // Cheap enough to recompute per build (a walk over ≤ a window of games,
    // no IO) and it has to be: the count ticks up as the analysis reports
    // each game.
    final review = aggregateOpeningReview(games.games);
    return OpeningsBlock(
      openingIssueCount: review.mistakes.length + review.bookEnds.length,
      gamesInWindow: games.games.length,
      windowLabel: games.window.label,
      onOpeningReview: () => _showOpeningReview(games),
      masterGameCount: MasterGamesService.instance.stats?.games ?? 0,
      onBrowseMasterGames: () =>
          showMasterGamesBrowser(context, appState: context.read<AppState>()),
      repeated: review.repeated(),
      onFixEntry: (entry) => openLineInBuilder(context.read<AppState>(), entry),
    );
  }
}
