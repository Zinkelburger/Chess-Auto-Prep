/// Solitaire-mode strips shown above the movetext in the PGN viewer's game
/// tab: the setup strip (side, start point, sidelines, delay), the in-progress
/// status bar (turn cue, progress, first-try tally) and the end-of-game
/// completion banner.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// The choices offered before a session starts. Replaces the status bar while
/// open; Start begins the game, the close button (or Esc) leaves.
class SolitaireSetupStrip extends StatelessWidget {
  final PgnViewerController controller;

  const SolitaireSetupStrip({super.key, required this.controller});

  static const _delays = [0, 15, 30, 60, 90, 120];

  @override
  Widget build(BuildContext context) {
    final setup = controller.solitaireSetup;
    if (setup == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final delay = controller.solitaire.revealDelaySec;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.psychology, size: 16, color: primary),
              const SizedBox(width: 8),
              Text(
                'Solitaire',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Guess the moves of one side; the game unfolds as you get '
                  'them right.',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.onSurfaceMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: controller.cancelSolitaireSetup,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Cancel (Esc)',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Field(
                label: 'Guess for',
                tooltip:
                    'Whose moves you guess. Starts as the side at the bottom '
                    'of the board; flipping the board later does not change it.',
                child: _Segmented<bool>(
                  segments: const [
                    (value: true, label: 'White'),
                    (value: false, label: 'Black'),
                  ],
                  selected: setup.userIsWhite,
                  onChanged: (v) =>
                      controller.updateSolitaireSetup(userIsWhite: v),
                ),
              ),
              if (setup.canStartHere)
                _Field(
                  label: 'Start',
                  tooltip:
                      'From here skips the opening: the moves up to the one on '
                      'screen stay visible and guessing begins from this '
                      'position.',
                  child: _Segmented<bool>(
                    segments: [
                      (value: false, label: 'Game start'),
                      (
                        value: true,
                        label: setup.startHereLabel.isEmpty
                            ? 'From here'
                            : 'From here (${setup.startHereLabel})',
                      ),
                    ],
                    selected: setup.fromCurrentMove,
                    onChanged: (v) =>
                        controller.updateSolitaireSetup(fromCurrentMove: v),
                  ),
                ),
              if (setup.hasSidelines)
                Tooltip(
                  message:
                      'Also drill the saved sidelines, in the order they '
                      'appear. Each line opens by showing its first move; '
                      'you guess your side from there.',
                  waitDuration: const Duration(milliseconds: 500),
                  child: FilterChip(
                    label: const Text('Include variations'),
                    selected: setup.includeVariations,
                    onSelected: (v) =>
                        controller.updateSolitaireSetup(includeVariations: v),
                    visualDensity: VisualDensity.compact,
                    labelStyle: AppTextStyles.caption,
                  ),
                ),
              _Field(
                label: 'Hint and reveal after',
                tooltip:
                    'How long each move must be thought about before Hint '
                    'and Reveal become available.',
                child: DropdownButton<int>(
                  value: _delays.contains(delay) ? delay : 60,
                  isDense: true,
                  style: AppTextStyles.caption.copyWith(color: AppColors.ink),
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final sec in _delays)
                      DropdownMenuItem(
                        value: sec,
                        child: Text(sec == 0 ? 'No delay' : '$sec s'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      unawaited(controller.setSolitaireRevealDelay(v));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Tooltip(
                message: 'Start (Enter)',
                waitDuration: const Duration(milliseconds: 500),
                child: FilledButton.icon(
                  onPressed: controller.beginSolitaire,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Start'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: AppTextStyles.caption,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String tooltip;
  final Widget child;

  const _Field({
    required this.label,
    required this.tooltip,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.onSurfaceMuted,
            ),
          ),
          const SizedBox(width: 8),
          child,
        ],
      ),
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  final List<({T value, String label})> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  const _Segmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<T>(
      segments: [
        for (final s in segments)
          ButtonSegment(value: s.value, label: Text(s.label)),
      ],
      selected: {selected},
      onSelectionChanged: (set) => onChanged(set.first),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(AppTextStyles.caption),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      ),
    );
  }
}

/// Compact end-of-game strip shown above the movetext instead of a modal
/// overlay: the user is left freely browsing their fully annotated game.
class SolitaireCompleteBanner extends StatelessWidget {
  final PgnViewerController controller;

  /// Copies the current game's annotated PGN (with guess notes) to the clipboard.
  final VoidCallback onCopyPgn;

  /// Opens the "Add game to study" picker for the annotated game.
  final VoidCallback onAddToStudy;

  /// Leaves solitaire and runs the engine over the game, which is what turns
  /// a wrong try that was actually better than the game move into a trophy.
  final VoidCallback onAnalyse;

  const SolitaireCompleteBanner({
    super.key,
    required this.controller,
    required this.onCopyPgn,
    required this.onAddToStudy,
    required this.onAnalyse,
  });

  @override
  Widget build(BuildContext context) {
    final s = controller.solitaire;
    final parts = <String>[
      '${s.correctFirstTry}/${s.totalUserMoves} first-try',
      if (s.hintedCount > 0) '${s.hintedCount} hinted',
      if (s.revealedCount > 0) '${s.revealedCount} revealed',
    ];
    final hadWrongTries = s.guessLog.any((g) => g.wrongAttempts.isNotEmpty);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: AppColors.success.withValues(alpha: 0.12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.flag, size: 16, color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Complete — ${parts.join(', ')}.',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
            ],
          ),
          if (hadWrongTries) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(
                'Analyse the game to check whether any of your other tries '
                'beat the move played — those earn trophies.',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          // Actions wrap when the panel is narrow so nothing clips.
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: onCopyPgn,
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Copy PGN'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: onAddToStudy,
                icon: const Icon(Icons.menu_book_outlined, size: 16),
                label: const Text('Add to study…'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              if (hadWrongTries)
                FilledButton.tonalIcon(
                  onPressed: onAnalyse,
                  icon: const Icon(Icons.emoji_events_outlined, size: 16),
                  label: const Text('Analyse for trophies'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              FilledButton.tonal(
                onPressed: controller.nextGame,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('Next game (↓)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Solitaire progress strip: side being guessed, whose turn it is, progress
/// bar and first-try tally.
class SolitaireStatusBar extends StatelessWidget {
  final PgnViewerController controller;

  const SolitaireStatusBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = controller.solitaire;
    final progress = s.totalSteps > 0 ? s.completedSteps / s.totalSteps : 0.0;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(Icons.psychology, size: 16, color: primary),
          const SizedBox(width: 8),
          Text(
            'Solitaire · ${s.userIsWhite ? "White" : "Black"}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: primary,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _cue(s),
            style: AppTextStyles.caption.copyWith(
              color: s.waitingForUser
                  ? AppColors.ink
                  : AppColors.onSurfaceMuted,
              fontWeight: s.waitingForUser ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${s.completedSteps}/${s.totalSteps}',
            style: const TextStyle(fontSize: 12),
          ),
          if (s.totalUserMoves > 0) ...[
            const SizedBox(width: 8),
            Text(
              '${s.correctFirstTry}/${s.totalUserMoves} first-try',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceSoft,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// What is happening right now, in the user's terms.
  String _cue(SolitaireController s) {
    if (s.isComplete) return 'Complete';
    final step = s.currentStep;
    if (step == null) return '';
    final sideline = step.node != null;
    if (s.waitingForUser) {
      final tries = s.currentAttempts;
      final where = sideline ? 'Sideline · ' : '';
      final count = tries == 0 ? '' : ' · $tries wrong';
      return '${where}Your move$count';
    }
    if (step.isPremise) return 'Sideline: ${_moveText(step)}';
    final premise = s.lastPremise;
    final where = sideline && premise != null
        ? 'Sideline ${_moveText(premise)} · '
        : '';
    return '$where${step.isWhiteMove ? 'White' : 'Black'} replies…';
  }

  static String _moveText(SolitaireStep step) {
    final n = step.before.fullmoves;
    return step.isWhiteMove ? '$n. ${step.san}' : '$n… ${step.san}';
  }
}
