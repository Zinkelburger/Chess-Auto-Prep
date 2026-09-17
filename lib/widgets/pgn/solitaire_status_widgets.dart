/// Solitaire-mode strips shown above the movetext in the PGN viewer's game
/// tab: the setup strip (side, start point, sidelines, delay), the in-progress
/// status bar (turn cue, progress, hint/reveal) and the completion banner.
///
/// One strip at a time — setup, then status, then completion — so the mode
/// owns a single band of the pane instead of scattering its controls between
/// the top of the movetext and the game nav bar at the bottom.
library;

import 'package:flutter/material.dart';

import '../../features/documents/controllers/solitaire_controller.dart';
import '../common/number_stepper.dart';
import '../common/horizontal_wheel_scroll.dart';
import '../../design_system/theme/app_typography.dart';
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';

/// The choices offered before a session starts. Replaces the status bar while
/// open; Start begins the game, the close button (or Esc) leaves.
class SolitaireSetupStrip extends StatelessWidget {
  const SolitaireSetupStrip({
    super.key,
    required this.userIsWhite,
    required this.fromCurrentMove,
    required this.includeVariations,
    required this.canStartHere,
    required this.hasSidelines,
    required this.startHereLabel,
    required this.userMovesToGuess,
    required this.revealDelaySeconds,
    required this.onUserSideChanged,
    required this.onFromCurrentMoveChanged,
    required this.onIncludeVariationsChanged,
    required this.onRevealDelayChanged,
    required this.onCancel,
    required this.onBegin,
  });

  final bool userIsWhite;
  final bool fromCurrentMove;
  final bool includeVariations;
  final bool canStartHere;
  final bool hasSidelines;
  final String startHereLabel;
  final int userMovesToGuess;
  final int revealDelaySeconds;
  final ValueChanged<bool> onUserSideChanged;
  final ValueChanged<bool> onFromCurrentMoveChanged;
  final ValueChanged<bool> onIncludeVariationsChanged;
  final ValueChanged<int> onRevealDelayChanged;
  final VoidCallback onCancel;
  final VoidCallback onBegin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final delay = revealDelaySeconds;
    final count = userMovesToGuess;
    final side = userIsWhite ? 'White' : 'Black';

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
                style: AppTypography.secondary(
                  context,
                ).copyWith(fontWeight: FontWeight.bold, color: primary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Guess the moves of one side; the game unfolds as you get '
                  'them right.',
                  style: AppTypography.caption(context).copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 18),
                tooltip: actionTooltip('Cancel', shortcut: AppShortcut.leave),
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
                  selected: userIsWhite,
                  onChanged: (v) => onUserSideChanged(v),
                ),
              ),
              if (canStartHere)
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
                        label: startHereLabel.isEmpty
                            ? 'From here'
                            : 'From here ($startHereLabel)',
                      ),
                    ],
                    selected: fromCurrentMove,
                    onChanged: (v) => onFromCurrentMoveChanged(v),
                  ),
                ),
              if (hasSidelines)
                Tooltip(
                  message:
                      'Also drill the saved sidelines, in the order they '
                      'appear. Each line opens by showing its first move; '
                      'you guess your side from there.',
                  waitDuration: const Duration(milliseconds: 500),
                  child: FilterChip(
                    label: const Text('Include variations'),
                    selected: includeVariations,
                    onSelected: (v) => onIncludeVariationsChanged(v),
                    visualDensity: VisualDensity.compact,
                    selectedColor: theme.colorScheme.primaryContainer,
                    backgroundColor: theme.colorScheme.surfaceContainerLow,
                    checkmarkColor: theme.colorScheme.onPrimaryContainer,
                    labelStyle: AppTypography.caption(context).copyWith(
                      color: includeVariations
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              _Field(
                label: 'Reveal after',
                tooltip:
                    'How long each move must be thought about before Reveal '
                    'unlocks. Hint unlocks at half that.',
                child: NumberStepper(
                  value: delay,
                  min: 0,
                  max: 600,
                  step: 15,
                  suffix: 's',
                  bordered: false,
                  fieldWidth: 36,
                  onChanged: (v) => onRevealDelayChanged(v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // How big the drill is, before you commit to it — a variations
              // pass over a repertoire chapter is a different afternoon from
              // the mainline of one game.
              Expanded(
                child: Text(
                  count == 0
                      ? 'No $side moves to guess with these choices.'
                      : '$count $side move${count == 1 ? '' : 's'} to guess.',
                  style: AppTypography.caption(context).copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: count == 0
                    ? 'Pick the other side, or start from the game start'
                    : actionTooltip(
                        'Start',
                        shortcut: AppShortcut.startSolitaire,
                      ),
                waitDuration: const Duration(milliseconds: 500),
                child: FilledButton.icon(
                  onPressed: count == 0 ? null : onBegin,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Start'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: AppTypography.caption(context),
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
      child: IntrinsicWidth(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppTypography.caption(
                context,
              ).copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Flexible(child: HorizontalWheelScroll(child: child)),
          ],
        ),
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
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(AppTypography.caption(context)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10),
        ),
      ),
    );
  }
}

/// Compact end-of-game strip shown above the movetext instead of a modal
/// overlay: the user is left freely browsing their fully annotated game.
class SolitaireCompleteBanner extends StatelessWidget {
  final SolitaireController controller;
  final VoidCallback onNextGame;

  /// Copies the current game's annotated PGN (with guess notes) to the clipboard.
  final VoidCallback onCopyPgn;

  /// Opens the "Add game to study" picker for the annotated game.
  final VoidCallback onAddToStudy;

  /// Leaves solitaire and runs the engine over the game, which is what turns
  /// a wrong try that was actually better than the game move into a trophy.
  final VoidCallback onAnalyse;

  /// Leaves solitaire, leaving the annotated game on screen.
  final VoidCallback onExit;

  const SolitaireCompleteBanner({
    super.key,
    required this.controller,
    required this.onNextGame,
    required this.onCopyPgn,
    required this.onAddToStudy,
    required this.onAnalyse,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    final s = controller;
    final parts = <String>[
      '${s.correctFirstTry}/${s.totalUserMoves} first try',
      if (s.hintedCount > 0) '${s.hintedCount} hinted',
      if (s.revealedCount > 0) '${s.revealedCount} revealed',
    ];
    final hadWrongTries = s.guessLog.any((g) => g.wrongAttempts.isNotEmpty);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.flag,
                size: 16,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Complete — ${parts.join(', ')}.',
                  style: AppTypography.caption(context),
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
                style: AppTypography.caption(context).copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                onPressed: onExit,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Exit solitaire'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: AppTypography.caption(context),
                ),
              ),
              TextButton.icon(
                onPressed: onCopyPgn,
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Copy PGN'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: AppTypography.caption(context),
                ),
              ),
              TextButton.icon(
                onPressed: onAddToStudy,
                icon: const Icon(Icons.menu_book_outlined, size: 16),
                label: const Text('Add to study…'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: AppTypography.caption(context),
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
                    textStyle: AppTypography.caption(context),
                  ),
                ),
              FilledButton.tonal(
                onPressed: onNextGame,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: AppTypography.caption(context),
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
/// through your own moves, and the two ways out of a move you are stuck on.
///
/// Hint and Reveal live here — beside the cue that says it is your move —
/// rather than in the game nav bar at the far end of the pane.
class SolitaireStatusBar extends StatelessWidget {
  final SolitaireController controller;
  final VoidCallback onHint;
  final VoidCallback onReveal;

  /// Leaves solitaire (asking first when guesses would be lost).
  final VoidCallback onExit;

  const SolitaireStatusBar({
    super.key,
    required this.controller,
    required this.onHint,
    required this.onReveal,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    final s = controller;
    final done = s.totalUserMoves;
    final total = s.userMovesInScript;
    final progress = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
      color: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.psychology, size: 16, color: primary),
              const SizedBox(width: 8),
              Text(
                'Solitaire · ${s.userIsWhite ? "White" : "Black"}',
                style: AppTypography.secondary(
                  context,
                ).copyWith(fontWeight: FontWeight.bold, color: primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _cue(s),
                  style: AppTypography.caption(context).copyWith(
                    color: s.waitingForUser
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: s.waitingForUser
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: onExit,
                icon: const Icon(Icons.close, size: 18),
                tooltip: actionTooltip(
                  'Leave solitaire',
                  shortcut: AppShortcut.leave,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 2),
          // Progress on the left, the two forms of help on the right. Wraps
          // rather than clips when the side panel is narrow.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              SizedBox(
                width: 190,
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      total > 0 ? '$done/$total' : '$done',
                      style: AppTypography.caption(context).copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    if (done > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '· ${s.correctFirstTry} first try',
                        style: AppTypography.caption(context),
                      ),
                    ],
                  ],
                ),
              ),
              _HelpControls(
                controller: controller,
                onHint: onHint,
                onReveal: onReveal,
              ),
            ],
          ),
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
      // The first ask of a session says where the answer goes; nothing else
      // on screen tells a first-time solver that the board is the input.
      if (s.totalUserMoves == 0 && tries == 0) {
        return '${where}Your move — play it on the board';
      }
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

/// Hint and Reveal, with the countdown that gates them.
///
/// Both are always on screen so they are discoverable, and disabled until
/// their timer runs out — Hint at half the reveal delay, so help escalates
/// (a nudge, then giving up) instead of arriving all at once.
class _HelpControls extends StatelessWidget {
  const _HelpControls({
    required this.controller,
    required this.onHint,
    required this.onReveal,
  });

  final VoidCallback onHint;
  final VoidCallback onReveal;

  final SolitaireController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller;
    final canHint = s.canHint;
    final canReveal = s.canReveal;
    final hintWait = s.waitingForUser ? s.hintCountdownSec : 0;
    final revealWait = s.waitingForUser ? s.revealCountdownSec : 0;
    // One countdown slot, showing whichever unlock is next. Fixed width and
    // tabular figures so the chips beside it never shift as it ticks.
    final next = hintWait > 0 ? hintWait : revealWait;

    String waitLabel(int seconds) => !s.waitingForUser
        ? 'Available on your turn'
        : seconds > 0
        ? 'Available in ${seconds}s'
        : 'Already used on this move';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 30,
          child: Text(
            next > 0 ? '${next}s' : '',
            textAlign: TextAlign.right,
            style: AppTypography.caption(
              context,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        const SizedBox(width: 6),
        ShortcutTooltip(
          description: canHint
              ? 'Highlight the piece that moves (costs your first try)'
              : waitLabel(hintWait),
          shortcut: AppShortcut.hintMove,
          child: ActionChip(
            onPressed: canHint ? onHint : null,
            avatar: Icon(
              Icons.lightbulb_outline,
              size: 16,
              color: canHint
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.38),
            ),
            label: Text(
              'Hint',
              style: AppTypography.caption(context).copyWith(
                color: canHint
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.38),
              ),
            ),
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 6),
        ShortcutTooltip(
          description: canReveal
              ? 'Give up and show the move played'
              : waitLabel(revealWait),
          shortcut: AppShortcut.revealMove,
          child: ActionChip(
            onPressed: canReveal ? onReveal : null,
            avatar: Icon(
              Icons.visibility_outlined,
              size: 16,
              color: canReveal
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.38),
            ),
            label: Text(
              'Reveal',
              style: AppTypography.caption(context).copyWith(
                color: canReveal
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.38),
              ),
            ),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }
}
