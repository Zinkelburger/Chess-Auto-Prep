/// The Analysis and Openings blocks of the tactics home column.
///
/// This is what the old review strip became once the home was reorganised
/// around one narrow column: the engine job as one block with one button,
/// and the opening review as the block under it. Study tactics is not here
/// any more — the Play block above these is the one place that starts a
/// session.
///
/// Rules these encode:
///
/// * **The button says what pressing it will do**, count included: "Analyse
///   12 games", "Resume analysis", "Pause", "Check for new games". A count on
///   a button is the attention signal; the button does not glow or pulse.
/// * **Pause is the same button, and there is no cancel.** Nothing already
///   analysed is thrown away.
/// * **Settings are not on the block.** Auto-start, cores, depth, window and
///   time controls are one gear dialog. The block carries only what you can
///   do next and what is happening.
/// * **Static.** Every control is always present; labels, enabled states and
///   the progress bar change.
library;

import 'package:flutter/material.dart';

import '../../tactics/services/tactics_import_coordinator.dart';
import '../../../theme/app_colors.dart';
import '../services/opening_review.dart';
import '../../../theme/app_text_styles.dart';
import '../services/home_review_runner.dart';
import 'home_block.dart';

class AnalysisBlock extends StatelessWidget {
  const AnalysisBlock({
    super.key,
    required this.runner,
    required this.coordinator,
    required this.isLoadingGames,
    required this.gamesInWindow,
    required this.unreviewedCount,
    required this.windowLabel,
    required this.onStart,
    required this.onPause,
    required this.onSettings,
  });

  final HomeReviewRunner runner;

  /// Source of the per-game progress while the engine pass runs.
  final TacticsImportCoordinator coordinator;

  final bool isLoadingGames;
  final int gamesInWindow;

  /// Games in the window with no mistake counts yet — the work the button is
  /// offering to do.
  final int unreviewedCount;

  final String windowLabel;

  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final running = runner.isRunning;
    final failed = runner.stage == HomeReviewStage.failed;
    return HomeBlock(
      heading: 'Analysis',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: 'Analysis settings…',
            visualDensity: VisualDensity.compact,
            onPressed: onSettings,
          ),
        ],
      ),
      children: [
        Text(
          _headline(running),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodyStrong.copyWith(
            color: failed ? AppColors.danger : AppColors.ink,
          ),
        ),
        const SizedBox(height: 8),
        _buildTransportButton(running),
        const SizedBox(height: 8),
        _buildProgressBar(running),
        const SizedBox(height: 4),
        SizedBox(
          height: 18,
          child: Text(
            _detailLine(running),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.muted.copyWith(
              color: failed ? AppColors.danger : AppColors.onSurfaceMuted,
            ),
          ),
        ),
      ],
    );
  }

  /// Whether pressing the button carries on work already part-done — either
  /// the run was paused this session, or the app was closed with games
  /// downloaded and only some of them analysed.
  bool get _isResume =>
      runner.canResume ||
      (unreviewedCount > 0 && unreviewedCount < gamesInWindow);

  String _transportLabel(bool running) {
    if (running) return 'Pause';
    if (unreviewedCount > 0) {
      return _isResume
          ? 'Resume analysis'
          : 'Analyse $unreviewedCount ${_games(unreviewedCount)}';
    }
    return gamesInWindow > 0 ? 'Check for new games' : 'Download and analyse';
  }

  /// This is a background job, not an interactive review session. Match the
  /// icon to the work it will do so the triangle remains reserved for places
  /// where the user is about to play or step through something themselves.
  IconData _transportIcon(bool running) {
    if (running) return Icons.pause;
    if (unreviewedCount > 0) return Icons.analytics_outlined;
    if (gamesInWindow > 0) return Icons.refresh;
    return Icons.download_outlined;
  }

  Widget _buildTransportButton(bool running) {
    final enabled = running || runner.hasAnySource;
    return Tooltip(
      message: runner.hasAnySource
          ? (running
                ? 'Stop after the game being analysed; press again to carry on'
                : _isResume
                ? 'Carry on with the $unreviewedCount '
                      '${_games(unreviewedCount)} not analysed yet. Nothing '
                      'already analysed is repeated.'
                : 'Download your $windowLabel, run Stockfish over them, and '
                      'check them against your books')
          : 'Set a username first',
      child: SizedBox(
        width: double.infinity,
        height: 40,
        child: FilledButton.icon(
          key: const Key('review-transport-button'),
          onPressed: enabled ? (running ? onPause : onStart) : null,
          icon: Icon(_transportIcon(running), size: 20),
          label: Text(
            _transportLabel(running),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: FilledButton.styleFrom(
            backgroundColor: running
                ? AppColors.surfaceInset
                : AppColors.buttonSurface,
            foregroundColor: AppColors.ink,
          ),
        ),
      ),
    );
  }

  String _headline(bool running) {
    final stage = runner.stage;
    if (!runner.hasAnySource) return 'No account set';
    if (running) {
      if (stage == HomeReviewStage.reviewing && coordinator.gamesTotal > 0) {
        return 'Analysing game ${coordinator.gamesDone} of '
            '${coordinator.gamesTotal}';
      }
      return stage.label;
    }
    if (stage == HomeReviewStage.failed) return 'Analysis failed';
    if (stage == HomeReviewStage.paused) {
      return unreviewedCount > 0
          ? 'Paused — $unreviewedCount ${_games(unreviewedCount)} left'
          : 'Paused';
    }
    if (unreviewedCount > 0) {
      return '$unreviewedCount of $gamesInWindow ${_games(gamesInWindow)} '
          'not analysed';
    }
    if (gamesInWindow == 0) return 'No games yet';
    return 'Finished analysing $gamesInWindow ${_games(gamesInWindow)}';
  }

  String _detailLine(bool running) {
    if (runner.stage == HomeReviewStage.failed) {
      return runner.detail ?? 'Something went wrong';
    }
    if (!runner.hasAnySource) return 'Add a username below';
    if (running) {
      final found = coordinator.newPositionsFound;
      final site = runner.detail;
      return [
        ?site,
        '$found ${found == 1 ? 'puzzle' : 'puzzles'} found',
      ].join(' · ');
    }
    if (runner.stage == HomeReviewStage.paused) {
      return 'Press Resume to carry on where it stopped';
    }
    if (gamesInWindow == 0) return 'Your $windowLabel, from your accounts';
    if (unreviewedCount > 0) return '';
    final verb = windowLabel.endsWith('s') ? 'are' : 'is';
    return 'Your $windowLabel $verb downloaded and analysed';
  }

  static String _games(int n) => n == 1 ? 'game' : 'games';

  Widget _buildProgressBar(bool running) {
    final showBar = running || isLoadingGames;
    final determinate =
        running &&
        runner.stage == HomeReviewStage.reviewing &&
        coordinator.gamesTotal > 0;
    return SizedBox(
      height: 3,
      child: showBar
          ? LinearProgressIndicator(
              minHeight: 3,
              value: determinate ? coordinator.progressFraction : null,
            )
          : const ColoredBox(color: AppColors.divider),
    );
  }
}

/// Where the window left your books, and the button that reviews it.
class OpeningsBlock extends StatelessWidget {
  const OpeningsBlock({
    super.key,
    required this.openingIssueCount,
    required this.gamesInWindow,
    required this.windowLabel,
    required this.onOpeningReview,
    required this.masterGameCount,
    required this.onBrowseMasterGames,
    this.repeated = const [],
    this.onFixEntry,
  });

  /// Distinct opening leaks (mistakes + book ends) across the window. Zero is
  /// still openable: the dialog is also where "no book was designated for
  /// this game" gets explained.
  final int openingIssueCount;
  final int gamesInWindow;
  final String windowLabel;
  final VoidCallback onOpeningReview;

  /// Games in the local TWIC database; zero disables the browse button rather
  /// than hiding it, so the block keeps the same shape either way.
  final int masterGameCount;
  final VoidCallback onBrowseMasterGames;

  /// Deviation points more than one game walked into, most-repeated first
  /// (see `OpeningReviewData.repeated`). Listed under the buttons so the
  /// block grows into the column with the one list worth acting on; empty
  /// keeps the block exactly as it was.
  final List<OpeningReviewEntry> repeated;

  /// Opens the builder on one repeated entry's line.
  final void Function(OpeningReviewEntry entry)? onFixEntry;

  @override
  Widget build(BuildContext context) {
    final hasIssues = openingIssueCount > 0;
    final places = openingIssueCount == 1 ? 'place' : 'places';
    return HomeBlock(
      heading: 'Openings',
      children: [
        Text(
          gamesInWindow == 0
              ? 'No games to check'
              : hasIssues
              ? '$openingIssueCount $places your games left your books'
              : 'Your $windowLabel stayed in book',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodyStrong,
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: hasIssues
              ? 'Review the $openingIssueCount $places your $windowLabel left '
                    'your books, grouped by line'
              : 'Check your $windowLabel against your books',
          child: SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton(
              key: const Key('opening-review-button'),
              onPressed: gamesInWindow > 0 ? onOpeningReview : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.outline),
              ),
              child: Text(
                hasIssues
                    ? 'Opening review ($openingIssueCount)'
                    : 'Opening review',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Tooltip(
          message: masterGameCount > 0
              ? 'Search the master games on this machine, or see which of '
                    'them walked into your books'
              : 'Download The Week in Chess in settings first',
          child: SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton(
              key: const Key('master-games-browse-button'),
              onPressed: masterGameCount > 0 ? onBrowseMasterGames : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.outline),
              ),
              child: const Text(
                'Master games',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        if (repeated.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Keeps happening', style: AppTextStyles.caption),
          const SizedBox(height: 2),
          for (final entry in repeated)
            _RepeatedLeakRow(
              entry: entry,
              onTap: onFixEntry == null ? null : () => onFixEntry!(entry),
            ),
        ],
      ],
    );
  }
}

/// One repeated leak: how many games hit it, the chapter and the move, and
/// the verb for fixing it. The whole row opens the builder there.
class _RepeatedLeakRow extends StatelessWidget {
  const _RepeatedLeakRow({required this.entry, required this.onTap});

  final OpeningReviewEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final count = entry.games.length;
    final what = entry.isBookEnd
        ? 'book ends at move ${entry.moveNumber}'
        : entry.playedDisplay;
    return Tooltip(
      message: entry.isBookEnd
          ? '$count games ran past the end of ${entry.chapterName} at move '
                '${entry.moveNumber}.\nClick to extend the line in the builder.'
          : 'You played ${entry.playedDisplay} in $count games; '
                '${entry.chapterName} plays ${entry.expectedDisplay}.\n'
                'Click to open the line in the builder.',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  '$count×',
                  style: AppTextStyles.bodyStrong.copyWith(fontSize: 13),
                ),
              ),
              Expanded(
                child: Text(
                  '${entry.chapterName} · $what',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body.copyWith(fontSize: 13),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                entry.isBookEnd ? 'Extend' : 'Fix',
                style: AppTextStyles.body.copyWith(
                  fontSize: 13,
                  color: AppColors.onSurfaceMuted,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.onSurfaceDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
