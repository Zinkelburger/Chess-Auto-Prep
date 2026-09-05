import 'package:flutter/material.dart';

import '../../core/repertoire_controller.dart';
import '../../models/repertoire_line.dart';
import '../../services/training/training_phase.dart';
import '../../services/training/training_session_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_shortcuts.dart';
import '../../utils/pgn_comment_utils.dart' show filterDisplayComment;
import '../chess_board_widget.dart';
import '../shortcut_tooltip.dart';
import 'move_input_widget.dart';

/// Chess board area for the trainer.
///
/// Used for active training (learn / drill / replay) and — with
/// [showMoveInput] off — as the idle board that keeps the browse screens
/// looking like the rest of the app instead of a bare list.
class TrainingBoardPane extends StatelessWidget {
  final RepertoireController session;
  final bool boardFlipped;
  final bool waitingForUser;
  final void Function(CompletedMove move)? onMove;
  final GlobalKey<MoveInputWidgetState>? moveInputKey;

  /// False while nothing is being trained: a field that can only reject what
  /// you type is worse than no field at all.
  final bool showMoveInput;

  /// Forwarded to [MoveInputWidget.onNavigationKey] so non-move shortcut
  /// keys (S, J, …) keep working while a move is being typed.
  final bool Function(KeyEvent event)? onNavigationKey;

  const TrainingBoardPane({
    super.key,
    required this.session,
    required this.boardFlipped,
    required this.waitingForUser,
    this.onMove,
    this.moveInputKey,
    this.showMoveInput = true,
    this.onNavigationKey,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  key: ValueKey(session.fen),
                  position: session.position,
                  flipped: boardFlipped,
                  enableUserMoves: waitingForUser,
                  // Two half-moves while training (your move plus the reply);
                  // the idle browse board gets plain single-move highlighting
                  // like the rest of the app.
                  recentMoveSquares: session.recentMoveTrail(
                    lastN: showMoveInput ? 2 : 1,
                  ),
                  onMove: onMove,
                ),
              ),
            ),
          ),
          if (showMoveInput) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: MoveInputWidget(
                key: moveInputKey,
                position: session.position,
                enabled: waitingForUser,
                onMove: onMove ?? (_) {},
                onNavigationKey: onNavigationKey,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Phase-specific training content shown beside the board (not finished/rating).
class TrainingPhasePanel extends StatelessWidget {
  final TrainingPhase phase;
  final String? feedback;
  final String? currentAnnotation;
  final bool learnQuizzing;
  final bool learnWaitingForAck;
  final bool opponentWaitingForAck;
  final MoveDisplayInfo? currentPairOpponent;
  final MoveDisplayInfo? currentPairUser;
  final int replayIndex;
  final int wrongMoveCount;
  final RepertoireLine? currentLine;
  final int currentMoveIndex;
  final bool waitingForUser;
  final bool isWhiteLine;
  final bool playingIntro;
  final double Function(RepertoireLine line, int moveIndex) moveDifficulty;
  final VoidCallback onLearnAcknowledged;
  final VoidCallback onOpponentAcknowledged;

  const TrainingPhasePanel({
    super.key,
    required this.phase,
    this.feedback,
    this.currentAnnotation,
    required this.learnQuizzing,
    required this.learnWaitingForAck,
    required this.opponentWaitingForAck,
    this.currentPairOpponent,
    this.currentPairUser,
    required this.replayIndex,
    required this.wrongMoveCount,
    this.currentLine,
    required this.currentMoveIndex,
    required this.waitingForUser,
    required this.isWhiteLine,
    this.playingIntro = false,
    required this.moveDifficulty,
    required this.onLearnAcknowledged,
    required this.onOpponentAcknowledged,
  });

  @override
  Widget build(BuildContext context) {
    if (playingIntro) {
      return _IntroContent(
        opponent: currentPairOpponent,
        user: currentPairUser,
      );
    }
    switch (phase) {
      case TrainingPhase.learning:
        return _LearnContent(
          feedback: feedback,
          learnQuizzing: learnQuizzing,
          learnWaitingForAck: learnWaitingForAck,
          opponentWaitingForAck: opponentWaitingForAck,
          currentPairOpponent: currentPairOpponent,
          currentPairUser: currentPairUser,
          onLearnAcknowledged: onLearnAcknowledged,
          onOpponentAcknowledged: onOpponentAcknowledged,
        );
      case TrainingPhase.drilling:
        return _DrillContent(
          feedback: feedback,
          currentAnnotation: currentAnnotation,
          currentPairOpponent: currentPairOpponent,
          currentPairUser: currentPairUser,
          waitingForUser: waitingForUser,
          currentLine: currentLine,
          currentMoveIndex: currentMoveIndex,
          moveDifficulty: moveDifficulty,
        );
      case TrainingPhase.replaying:
        return _ReplayContent(
          feedback: feedback,
          replayIndex: replayIndex,
          wrongMoveCount: wrongMoveCount,
        );
      case TrainingPhase.finished:
        return const SizedBox.shrink();
    }
  }
}

// ---------------------------------------------------------------------------
// INTRO CONTENT — auto-playing the moves before the first comment
// ---------------------------------------------------------------------------

class _IntroContent extends StatelessWidget {
  final MoveDisplayInfo? opponent;
  final MoveDisplayInfo? user;

  const _IntroContent({this.opponent, this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.play_circle_outline,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Watch — playing the opening moves. Training starts '
                    'at the first comment.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          if (opponent != null || user != null) ...[
            const SizedBox(height: 12),
            _MovePairCard(opponent: opponent, user: user),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CHESSABLE-STYLE MOVE LINE — shows a single move header + comment
// ---------------------------------------------------------------------------

class _MoveLine extends StatelessWidget {
  final MoveDisplayInfo display;
  final bool showComment;

  const _MoveLine({required this.display, this.showComment = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOpponent = display.isOpponentMove;
    // Scraped PGNs carry engine tokens and stray double spaces — show prose only.
    final comment = display.comment == null
        ? ''
        : filterDisplayComment(display.comment!);
    final headerText = isOpponent ? display.moveLabel : display.yourMoveLabel;
    final headerColor = isOpponent
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headerText,
          style: theme.textTheme.titleSmall?.copyWith(
            color: headerColor,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (showComment && comment.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            comment,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// MOVE PAIR CARD — one stable container for a move pair in every phase:
// opponent context on top, your move (or the "Your move" prompt) below.
// Layout stays put between states so nothing jumps around, and the learn
// walkthrough and the drill that follows it look like the same thing.
// ---------------------------------------------------------------------------

class _MovePairCard extends StatelessWidget {
  final MoveDisplayInfo? opponent;
  final MoveDisplayInfo? user;

  /// Off while the learn walkthrough is quizzing: the note on the reply you
  /// just read can give the answer away.
  final bool showOpponentComment;

  /// Show the "Your move" row in the user slot instead of a move.
  final bool showPrompt;

  /// Right-aligned extra on the prompt row (the drill's difficulty chip).
  final Widget? promptTrailing;

  const _MovePairCard({
    this.opponent,
    this.user,
    this.showOpponentComment = true,
    this.showPrompt = false,
    this.promptTrailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUserRow = user != null || showPrompt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (opponent != null)
            _MoveLine(display: opponent!, showComment: showOpponentComment),
          if (opponent != null && hasUserRow)
            Divider(
              height: 20,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          if (user != null)
            _MoveLine(display: user!)
          else if (showPrompt)
            Row(
              children: [
                Icon(
                  Icons.touch_app_outlined,
                  size: 16,
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 6),
                Text(
                  'Your move',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                ?promptTrailing,
              ],
            ),
        ],
      ),
    );
  }
}

/// Fixed-height line above the card: the verdict fades in and out without
/// shifting the card below.
class _FeedbackSlot extends StatelessWidget {
  final String? feedback;

  const _FeedbackSlot({this.feedback});

  @override
  Widget build(BuildContext context) {
    final text = feedback;
    return SizedBox(
      height: 28,
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: text == null || text.isEmpty
              ? const SizedBox.shrink()
              : TrainingFeedbackText(key: ValueKey(text), feedback: text),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// NEXT BUTTON — the learn walkthrough's one gate
// ---------------------------------------------------------------------------

class _NextButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _NextButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ShortcutTooltip(
        description: 'Next',
        shortcut: AppShortcut.toggleSolution,
        child: FilledButton.icon(
          onPressed: onPressed,
          // Self-focus so Space activates "Next" no matter where focus was.
          autofocus: true,
          icon: const Icon(Icons.arrow_forward, size: 18),
          label: const Text('Next'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LEARN PHASE CONTENT — the walkthrough card, with Next when it is waiting
// ---------------------------------------------------------------------------

class _LearnContent extends StatelessWidget {
  final String? feedback;
  final bool learnQuizzing;
  final bool learnWaitingForAck;
  final bool opponentWaitingForAck;
  final MoveDisplayInfo? currentPairOpponent;
  final MoveDisplayInfo? currentPairUser;
  final VoidCallback onLearnAcknowledged;
  final VoidCallback onOpponentAcknowledged;

  const _LearnContent({
    this.feedback,
    required this.learnQuizzing,
    required this.learnWaitingForAck,
    required this.opponentWaitingForAck,
    this.currentPairOpponent,
    this.currentPairUser,
    required this.onLearnAcknowledged,
    required this.onOpponentAcknowledged,
  });

  @override
  Widget build(BuildContext context) {
    if (!learnQuizzing &&
        currentPairOpponent == null &&
        currentPairUser == null) {
      return const SizedBox.shrink();
    }
    final onNext = learnWaitingForAck
        ? onLearnAcknowledged
        : opponentWaitingForAck
        ? onOpponentAcknowledged
        : null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FeedbackSlot(feedback: feedback),
          _MovePairCard(
            opponent: currentPairOpponent,
            // While quizzing, your move is the answer: hide it, and the note
            // on the reply that could give it away.
            user: learnQuizzing ? null : currentPairUser,
            showOpponentComment: !learnQuizzing,
            showPrompt: learnQuizzing,
          ),
          if (onNext != null) ...[
            const SizedBox(height: 12),
            _NextButton(onPressed: onNext),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DRILL PHASE CONTENT
// ---------------------------------------------------------------------------

class _DrillContent extends StatelessWidget {
  final String? feedback;
  final String? currentAnnotation;
  final MoveDisplayInfo? currentPairOpponent;
  final MoveDisplayInfo? currentPairUser;
  final bool waitingForUser;
  final RepertoireLine? currentLine;
  final int currentMoveIndex;
  final double Function(RepertoireLine line, int moveIndex) moveDifficulty;

  const _DrillContent({
    this.feedback,
    this.currentAnnotation,
    this.currentPairOpponent,
    this.currentPairUser,
    required this.waitingForUser,
    this.currentLine,
    required this.currentMoveIndex,
    required this.moveDifficulty,
  });

  @override
  Widget build(BuildContext context) {
    // Keep the prompt row during wrong-move feedback (input is off, but the
    // user slot shouldn't collapse while the correction is pending).
    final wrongPending =
        currentPairUser == null && (feedback?.startsWith('Wrong') ?? false);
    final showPrompt = waitingForUser || wrongPending;

    if (!showPrompt && currentPairOpponent == null && currentPairUser == null) {
      return const SizedBox.shrink();
    }

    final line = currentLine;
    final chip =
        showPrompt && line != null && currentMoveIndex < line.moves.length
        ? TrainingMoveDifficultyChip(
            difficulty: moveDifficulty(line, currentMoveIndex),
          )
        : null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FeedbackSlot(feedback: feedback),
          _MovePairCard(
            opponent: currentPairOpponent,
            user: currentPairUser,
            showPrompt: showPrompt,
            promptTrailing: chip,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// REPLAY CONTENT
// ---------------------------------------------------------------------------

class _ReplayContent extends StatelessWidget {
  final String? feedback;
  final int replayIndex;
  final int wrongMoveCount;

  const _ReplayContent({
    this.feedback,
    required this.replayIndex,
    required this.wrongMoveCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (feedback != null && feedback!.isNotEmpty) ...[
          TrainingFeedbackText(feedback: feedback!),
          const SizedBox(height: 12),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Replaying missed moves',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.warning,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${replayIndex + 1} of $wrongMoveCount',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Colored feedback line (Correct / Wrong / Try again).
class TrainingFeedbackText extends StatelessWidget {
  final String feedback;

  const TrainingFeedbackText({super.key, required this.feedback});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color color = theme.colorScheme.onSurfaceVariant;
    if (feedback.startsWith('Correct')) {
      color = AppColors.success;
    } else if (feedback.startsWith('Wrong') || feedback.startsWith('Try')) {
      color = theme.colorScheme.error;
    }
    return Text(
      feedback,
      style: theme.textTheme.titleSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class TrainingMoveDifficultyChip extends StatelessWidget {
  final double difficulty;

  const TrainingMoveDifficultyChip({super.key, required this.difficulty});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    String label;
    Color color;
    if (difficulty >= 1.0) {
      label = 'Memorized';
      color = AppColors.success;
    } else if (difficulty > 0) {
      final pct = (difficulty * 100).round();
      label = '$pct% learned';
      color = AppColors.warning;
    } else {
      label = 'New move';
      color = theme.colorScheme.onSurfaceVariant;
    }

    return Text(label, style: AppTextStyles.caption.copyWith(color: color));
  }
}
