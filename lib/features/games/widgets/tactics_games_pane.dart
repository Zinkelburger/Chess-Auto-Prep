import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_state.dart';
import '../../../screens/settings_screen.dart';
import '../../../services/games_library/game_filter.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/labeled_toggle.dart';
import '../controllers/recent_games_controller.dart';
import '../models/recent_game.dart';
import '../services/game_auto_analysis_service.dart';
import '../services/my_repertoire_settings.dart';
import '../services/opening_review.dart';
import '../services/rating_trend.dart';
import 'opening_review_dialog.dart';

/// The recent-games half of the unified Tactics home: welcome header, then a
/// static table of the last two weeks' games — time control, players, result,
/// review summary, repertoire deviation, date. Shown in the Tactics screen's
/// left pane whenever no puzzle is active; the board takes the pane back
/// during a session.
///
/// The [RecentGamesController] is provided by `_TacticsModeView` (it must
/// outlive this widget: the pane is swapped out for the board mid-session
/// and the list should not reload when it comes back).
class TacticsGamesPane extends StatefulWidget {
  const TacticsGamesPane({super.key});

  @override
  State<TacticsGamesPane> createState() => _TacticsGamesPaneState();
}

class _TacticsGamesPaneState extends State<TacticsGamesPane> {
  RecentGamesController? _controller;
  AppState? _appState;

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
      appState.addListener(_onAppStateChanged);
      controller.addListener(_onControllerChanged);
      controller.ensureLoaded();
      _maybeAutoAnalyze();
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

  void _onControllerChanged() => _maybeAutoAnalyze();

  void _onRepertoireSettingsChanged() {
    final controller = _controller;
    if (controller != null && controller.hasLoadedOnce) {
      controller.recomputeDeviations();
    }
  }

  /// Hand freshly loaded games to the background analyzer. Idempotent — the
  /// service no-ops while running and attempts each game once per session.
  void _maybeAutoAnalyze() {
    final controller = _controller;
    if (controller == null || controller.isLoading) return;
    if (!controller.hasLoadedOnce || !controller.filters.autoAnalyze) return;
    GameAutoAnalysisService.instance.maybeRun(controller.games);
  }

  void _openGame(RecentGame game) {
    context.read<AppState>().switchToPgnViewer(
      path: game.cachePath,
      gameId: game.record.dedupKey,
      autoAnalyze: true,
      historyLabel: 'Game: ${game.white} vs ${game.black}',
    );
  }

  void _openDeviation(RecentGame game) {
    final report = game.deviation;
    if (report == null) return;
    context.read<AppState>().switchToBuilder(
      repertoirePath: report.chapterPath,
      moveSequence: report.pathSans,
      historyLabel: 'Repertoire: ${report.chapterName}',
    );
  }

  void _openReviewEntry(OpeningReviewEntry entry) {
    context.read<AppState>().switchToBuilder(
      repertoirePath: entry.chapterPath,
      moveSequence: entry.pathSans,
      historyLabel: 'Repertoire: ${entry.chapterName}',
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
        sinceDays: controller.filters.sinceDays,
        onOpenLine: _openReviewEntry,
        onOpenGame: _openGame,
        onOpenSettings: _openSettings,
      ),
    );
  }

  Future<void> _showFilterDialog() async {
    final controller = _controller;
    if (controller == null) return;
    final result = await showDialog<GamesListFilters>(
      context: context,
      builder: (_) => _GamesFilterDialog(initial: controller.filters),
    );
    if (result != null) await controller.setFilters(result);
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.read<RecentGamesController>();
    return ListenableBuilder(
      // The auto-analysis service notifies as each game's summary lands, so
      // the chips fill in while the job runs.
      listenable: Listenable.merge([
        controller,
        GameAutoAnalysisService.instance,
      ]),
      builder: (context, _) => _buildBody(context, controller),
    );
  }

  Widget _buildBody(BuildContext context, RecentGamesController controller) {
    // Usernames come out of prefs asynchronously at startup; until that read
    // finishes, "no usernames" may just mean "still loading" — don't flash
    // the no-accounts card at a configured user.
    final usernamesLoaded = context.select<AppState, bool>(
      (s) => s.usernamesLoaded,
    );
    if (!usernamesLoaded && !controller.hasAnyUsername) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!controller.hasAnyUsername) {
      return _EmptyStateCard(
        icon: Icons.person_off,
        title: 'No accounts configured',
        message:
            'Set your Chess.com or Lichess username in Settings → Accounts '
            'and your recent games will appear here.',
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
            'No games in the last ${controller.filters.sinceDays} days '
                'matched the current filters.',
        buttonLabel: 'Try again',
        onPressed: () => controller.refresh(force: true),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WelcomeHeader(controller: controller),
        _GamesToolbarRow(
          controller: controller,
          onRefresh: () => controller.refresh(force: true),
          onFilters: _showFilterDialog,
          onOpeningReview: _showOpeningReview,
        ),
        SizedBox(
          height: 3,
          child: controller.isLoading
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox.expand(),
        ),
        const _GamesHeaderRow(),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: ListView.builder(
            itemCount: controller.games.length,
            itemBuilder: (context, index) {
              final game = controller.games[index];
              return _GameRow(
                game: game,
                onOpen: () => _openGame(game),
                onOpenDeviation: () => _openDeviation(game),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Welcome header ─────────────────────────────────────────────────────────

/// The friendly part of coming home: greeting, rating trend over the visible
/// window, and a one-line pointer at what deserves attention. Static layout —
/// nothing moves, nothing animates.
class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader({required this.controller});

  final RecentGamesController controller;

  @override
  Widget build(BuildContext context) {
    final games = controller.games;
    final trends = computeRatingTrends(games);
    final name = games.isNotEmpty ? games.first.myUsername : '';

    final analyzed = games.where((g) => g.summary != null).length;
    final unanalyzed = games.where((g) => g.meWhite != null).length - analyzed;
    final withMistakes = games
        .where((g) => (g.summary?.clean ?? true) == false)
        .length;
    final leftBook = games
        .where(
          (g) =>
              g.deviation != null &&
              !g.deviation!.inBook &&
              !g.deviation!.bookEnded &&
              g.deviation!.byMe == true,
        )
        .length;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name.isEmpty ? 'Welcome back!' : 'Welcome back, $name!',
            style: AppTextStyles.body.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (trends.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [for (final t in trends.take(2)) _TrendLine(trend: t)],
            ),
          ],
          const SizedBox(height: 6),
          Text(
            _encouragement(trends),
            style: AppTextStyles.body.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            _attentionLine(
              total: games.length,
              days: controller.filters.sinceDays,
              unanalyzed: unanalyzed,
              withMistakes: withMistakes,
              leftBook: leftBook,
            ),
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ],
      ),
    );
  }

  static String _encouragement(List<RatingTrendEntry> trends) {
    final top = trends.isEmpty ? null : trends.first;
    if (top == null || !top.hasTrend) {
      return 'Ready to sharpen up? Your recent games are below.';
    }
    if (top.delta > 0) {
      return 'Congrats on +${top.delta} ${top.speedLabel} — keep it rolling!';
    }
    if (top.delta < 0) {
      return 'Down ${-top.delta} ${top.speedLabel} — your mistakes below '
          'are the fastest way back.';
    }
    return 'Holding steady — a review below might find the next step up.';
  }

  static String _attentionLine({
    required int total,
    required int days,
    required int unanalyzed,
    required int withMistakes,
    required int leftBook,
  }) {
    final parts = <String>[
      days > 0 ? '$total games in the last $days days' : '$total games',
      if (unanalyzed > 0) '$unanalyzed awaiting analysis',
      if (withMistakes > 0) '$withMistakes with mistakes to review',
      if (unanalyzed == 0 && withMistakes == 0) 'all reviewed — clean!',
      if (leftBook > 0)
        'left book in $leftBook ${leftBook == 1 ? 'game' : 'games'}',
    ];
    return parts.join(' · ');
  }
}

class _TrendLine extends StatelessWidget {
  const _TrendLine({required this.trend});

  final RatingTrendEntry trend;

  @override
  Widget build(BuildContext context) {
    final delta = trend.delta;
    final deltaColor = !trend.hasTrend || delta == 0
        ? AppColors.onSurfaceSoft
        : (delta > 0 ? AppColors.success : AppColors.danger);
    final deltaText = !trend.hasTrend
        ? ''
        : '  ${delta >= 0 ? '+$delta' : '$delta'}';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${trend.speedLabel} ${trend.latestElo}',
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (deltaText.isNotEmpty)
            TextSpan(
              text: deltaText,
              style: AppTextStyles.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: deltaColor,
              ),
            ),
          TextSpan(
            text:
                '  (${trend.gameCount} '
                '${trend.gameCount == 1 ? 'game' : 'games'}, '
                '${trend.platformLabel})',
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Toolbar row (section title + refresh + filters) ────────────────────────

class _GamesToolbarRow extends StatelessWidget {
  const _GamesToolbarRow({
    required this.controller,
    required this.onRefresh,
    required this.onFilters,
    required this.onOpeningReview,
  });

  final RecentGamesController controller;
  final VoidCallback onRefresh;
  final VoidCallback onFilters;
  final VoidCallback onOpeningReview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Text(
            'Recent games',
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurfaceMuted,
            ),
          ),
          const Spacer(),
          // Static entry point (not gated on there being mistakes): the
          // dialog itself explains the no-repertoire and all-clean states.
          TextButton.icon(
            onPressed: onOpeningReview,
            icon: const Icon(Icons.menu_book, size: 16),
            label: const Text('Opening review'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Refresh games',
            visualDensity: VisualDensity.compact,
            onPressed: controller.isLoading ? null : onRefresh,
          ),
          IconButton(
            icon: const Icon(Icons.tune, size: 18),
            tooltip: 'Game list filters…',
            visualDensity: VisualDensity.compact,
            onPressed: onFilters,
          ),
        ],
      ),
    );
  }
}

// ── Layout constants shared by header and rows (static table) ─────────────
//
// Fixed columns stay narrow so the two flexible cells (players, repertoire)
// absorb whatever width the pane actually gets; every text cell ellipsizes,
// so the row cannot overflow even in a half-window pane.

const double _kTimeColWidth = 64;
const double _kScoreColWidth = 40;
const double _kReviewColWidth = 104;
const double _kDateColWidth = 48;
const double _kLinkColWidth = 32;
const int _kPlayersFlex = 5;
const int _kPrepFlex = 4;

class _GamesHeaderRow extends StatelessWidget {
  const _GamesHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.body.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.onSurfaceMuted,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: _kTimeColWidth,
            child: Text('Time', style: style),
          ),
          Expanded(
            flex: _kPlayersFlex,
            child: Text('Players', style: style),
          ),
          SizedBox(
            width: _kScoreColWidth,
            child: Text('Result', style: style),
          ),
          SizedBox(
            width: _kReviewColWidth,
            child: Text('Review', style: style),
          ),
          Expanded(
            flex: _kPrepFlex,
            child: Text('Repertoire', style: style),
          ),
          SizedBox(
            width: _kDateColWidth,
            child: Text('Date', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: _kLinkColWidth),
        ],
      ),
    );
  }
}

class _GameRow extends StatelessWidget {
  const _GameRow({
    required this.game,
    required this.onOpen,
    required this.onOpenDeviation,
  });

  final RecentGame game;
  final VoidCallback onOpen;
  final VoidCallback onOpenDeviation;

  @override
  Widget build(BuildContext context) {
    final (whiteScore, blackScore) = game.scorePair;
    return InkWell(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            SizedBox(width: _kTimeColWidth, child: _buildTimeCell()),
            Expanded(flex: _kPlayersFlex, child: _buildPlayersCell()),
            SizedBox(
              width: _kScoreColWidth,
              child: _ScorePair(
                white: whiteScore,
                black: blackScore,
                outcome: game.myOutcome,
                meWhite: game.meWhite,
              ),
            ),
            SizedBox(
              width: _kReviewColWidth,
              child: _ReviewCell(game: game, onOpen: onOpen),
            ),
            Expanded(
              flex: _kPrepFlex,
              child: _DeviationCell(game: game, onOpen: onOpenDeviation),
            ),
            SizedBox(
              width: _kDateColWidth,
              child: Text(
                game.dateDisplayShort,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                  fontSize: 12,
                  color: AppColors.onSurfaceSoft,
                ),
              ),
            ),
            SizedBox(
              width: _kLinkColWidth,
              child: game.gameUrl == null
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(Icons.open_in_new, size: 16),
                      tooltip:
                          'Open on ${game.platform.name == 'chesscom' ? 'Chess.com' : 'Lichess'}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => launchUrl(Uri.parse(game.gameUrl!)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeCell() {
    return Row(
      children: [
        Icon(
          _speedIcon(game.record.speed),
          size: 16,
          color: AppColors.onSurfaceMuted,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            game.timeControlDisplay,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayersCell() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PlayerLine(
          name: game.white,
          elo: game.whiteElo,
          isWhitePiece: true,
          isMe: game.meWhite == true,
        ),
        const SizedBox(height: 2),
        _PlayerLine(
          name: game.black,
          elo: game.blackElo,
          isWhitePiece: false,
          isMe: game.meWhite == false,
        ),
      ],
    );
  }

  static IconData _speedIcon(GameSpeed speed) => switch (speed) {
    GameSpeed.ultraBullet || GameSpeed.bullet => Icons.rocket_launch,
    GameSpeed.blitz => Icons.bolt,
    GameSpeed.rapid => Icons.timer,
    GameSpeed.classical => Icons.hourglass_bottom,
    GameSpeed.correspondence => Icons.mail_outline,
    GameSpeed.unknown => Icons.help_outline,
  };
}

/// The Review column: a "Review" button until the game has stored evals,
/// then the analysis verdict — worst mistake category with its count (full
/// breakdown in the tooltip). Both forms open the game; the verdict text is
/// what makes "where did I go wrong?" answerable from the list.
class _ReviewCell extends StatelessWidget {
  const _ReviewCell({required this.game, required this.onOpen});

  final RecentGame game;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final summary = game.summary;
    if (summary == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: onOpen,
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: const Text('Review'),
        ),
      );
    }
    final Color color;
    if (summary.blunders > 0) {
      color = AppColors.danger;
    } else if (summary.mistakes > 0) {
      color = AppColors.warning;
    } else if (summary.inaccuracies > 0) {
      color = AppColors.info;
    } else {
      color = AppColors.successMuted;
    }
    return Tooltip(
      message: summary.breakdown,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(4),
        child: Text(
          summary.chipLabel,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _PlayerLine extends StatelessWidget {
  const _PlayerLine({
    required this.name,
    required this.elo,
    required this.isWhitePiece,
    required this.isMe,
  });

  final String name;
  final String? elo;
  final bool isWhitePiece;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: isWhitePiece ? AppColors.ink : AppColors.surface,
            border: Border.all(color: AppColors.outline),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            elo == null ? name : '$name ($elo)',
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              fontWeight: isMe ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

class _ScorePair extends StatelessWidget {
  const _ScorePair({
    required this.white,
    required this.black,
    required this.outcome,
    required this.meWhite,
  });

  final String white;
  final String black;
  final MyGameOutcome outcome;
  final bool? meWhite;

  @override
  Widget build(BuildContext context) {
    Color colorFor({required bool whiteLine}) {
      if (meWhite == null || meWhite != whiteLine) {
        return AppColors.onSurfaceSoft;
      }
      return switch (outcome) {
        MyGameOutcome.win => AppColors.success,
        MyGameOutcome.loss => AppColors.danger,
        MyGameOutcome.draw => AppColors.onSurfaceSoft,
        MyGameOutcome.unknown => AppColors.onSurfaceSoft,
      };
    }

    TextStyle styleFor({required bool whiteLine}) =>
        AppTextStyles.body.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colorFor(whiteLine: whiteLine),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(white, style: styleFor(whiteLine: true)),
        const SizedBox(height: 2),
        Text(black, style: styleFor(whiteLine: false)),
      ],
    );
  }
}

class _DeviationCell extends StatelessWidget {
  const _DeviationCell({required this.game, required this.onOpen});

  final RecentGame game;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final muted = AppTextStyles.body.copyWith(
      fontSize: 12,
      color: AppColors.onSurfaceMuted,
    );
    if (!game.deviationComputed) {
      return Text('…', style: muted);
    }
    final report = game.deviation;
    if (report == null) {
      final String message;
      if (game.meWhite == null) {
        message = 'Could not tell which side you played';
      } else if (!game.bookDesignated) {
        message =
            'No repertoire designated for this color '
            '(Settings → My repertoires)';
      } else {
        message =
            'The designated repertoire has no usable chapters '
            '(folder missing or empty?)';
      }
      return Tooltip(
        message: message,
        child: Text('—', style: muted),
      );
    }
    if (report.inBook) {
      return Text(
        'In book',
        style: AppTextStyles.body.copyWith(
          fontSize: 12,
          color: AppColors.successMuted,
        ),
      );
    }
    if (report.bookEnded) {
      // The prep simply ran out — nobody "left" anything; offer to extend.
      return Tooltip(
        message:
            'Your prep ends here — ${report.chapterName} has no moves past '
            'this point.\nClick to open it at this position and extend it.',
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(4),
          child: Text(
            'Book ends: move ${report.moveNumber}',
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.onSurfaceSoft,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.onSurfaceDim,
            ),
          ),
        ),
      );
    }
    final who = report.byMe == true ? 'you' : 'them';
    return Tooltip(
      message:
          'Played ${report.playedSan} — expected '
          '${report.expectedSans.join(' / ')}.\n'
          'Click to open ${report.chapterName} at this position.',
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(4),
        child: Text(
          'Left book: move ${report.moveNumber} ($who)',
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body.copyWith(
            fontSize: 12,
            color: report.byMe == true ? AppColors.warning : AppColors.info,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.onSurfaceDim,
          ),
        ),
      ),
    );
  }
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

class _GamesFilterDialog extends StatefulWidget {
  const _GamesFilterDialog({required this.initial});

  final GamesListFilters initial;

  @override
  State<_GamesFilterDialog> createState() => _GamesFilterDialogState();
}

class _GamesFilterDialogState extends State<_GamesFilterDialog> {
  late Set<GameSpeed> _speeds;
  late final TextEditingController _maxGames;
  late final TextEditingController _sinceDays;
  late bool _autoAnalyze;

  static const _speedLabels = {
    GameSpeed.ultraBullet: 'UltraBullet',
    GameSpeed.bullet: 'Bullet',
    GameSpeed.blitz: 'Blitz',
    GameSpeed.rapid: 'Rapid',
    GameSpeed.classical: 'Classical',
    GameSpeed.correspondence: 'Correspondence',
  };

  @override
  void initState() {
    super.initState();
    _speeds = {...widget.initial.speeds};
    _maxGames = TextEditingController(text: '${widget.initial.maxGames}');
    _sinceDays = TextEditingController(text: '${widget.initial.sinceDays}');
    _autoAnalyze = widget.initial.autoAnalyze;
  }

  @override
  void dispose() {
    _maxGames.dispose();
    _sinceDays.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Game list filters'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in _speedLabels.entries)
              AppCheckbox(
                label: entry.value,
                value: _speeds.contains(entry.key),
                onChanged: (checked) => setState(() {
                  if (checked == true) {
                    _speeds.add(entry.key);
                  } else {
                    _speeds.remove(entry.key);
                  }
                }),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _sinceDays,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Show games from the last N days (0 = any time)',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _maxGames,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Maximum games per site',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            AppCheckbox(
              label: 'Analyze new games automatically',
              value: _autoAnalyze,
              onChanged: (checked) => setState(() => _autoAnalyze = checked),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final max = int.tryParse(_maxGames.text.trim());
            final since = int.tryParse(_sinceDays.text.trim());
            Navigator.of(context).pop(
              GamesListFilters(
                speeds: _speeds,
                maxGames: (max == null || max < 1)
                    ? widget.initial.maxGames
                    : max.clamp(1, 1000),
                sinceDays: (since == null || since < 0)
                    ? widget.initial.sinceDays
                    : since.clamp(0, 3650),
                autoAnalyze: _autoAnalyze,
              ),
            );
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
