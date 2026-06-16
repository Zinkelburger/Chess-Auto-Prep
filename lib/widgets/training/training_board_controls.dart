import 'package:flutter/material.dart';

import '../shortcut_tooltip.dart';

import '../../core/repertoire_controller.dart';
import '../../models/repertoire_line.dart';
import '../../services/training/training_phase.dart';
import '../../services/training/training_session_controller.dart';
import '../../widgets/chess_board_widget.dart';
import 'move_input_widget.dart';

/// Chess board area for active training (learn / drill / replay).
class TrainingBoardPane extends StatelessWidget {
  final RepertoireController session;
  final bool boardFlipped;
  final bool waitingForUser;
  final void Function(CompletedMove move) onMove;
  final GlobalKey<MoveInputWidgetState>? moveInputKey;

  const TrainingBoardPane({
    super.key,
    required this.session,
    required this.boardFlipped,
    required this.waitingForUser,
    required this.onMove,
    this.moveInputKey,
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
                  onMove: onMove,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: MoveInputWidget(
              key: moveInputKey,
              position: session.position,
              enabled: waitingForUser,
              onMove: onMove,
            ),
          ),
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
    required this.moveDifficulty,
    required this.onLearnAcknowledged,
    required this.onOpponentAcknowledged,
  });

  @override
  Widget build(BuildContext context) {
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
    final sideLabel = display.isWhiteMove ? "White's" : "Black's";
    final headerText = isOpponent
        ? '$sideLabel move ${display.notation}'
        : 'Your move ${display.notation}';
    final headerColor =
        isOpponent ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headerText,
          style: theme.textTheme.titleSmall?.copyWith(
            color: headerColor,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
        if (showComment &&
            display.comment != null &&
            display.comment!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            display.comment!,
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
// MOVE PAIR CARD — wraps opponent + user move in one styled container
// ---------------------------------------------------------------------------

class _MovePairCard extends StatelessWidget {
  final MoveDisplayInfo? opponent;
  final MoveDisplayInfo? user;
  final bool showOpponentComment;

  const _MovePairCard({
    this.opponent,
    this.user,
    this.showOpponentComment = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          if (opponent != null) ...[
            _MoveLine(display: opponent!, showComment: showOpponentComment),
          ],
          if (opponent != null && user != null) ...[
            Divider(
              height: 20,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ],
          if (user != null) ...[
            _MoveLine(display: user!),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// NEXT BUTTON (shared between learn and drill)
// ---------------------------------------------------------------------------

class _NextButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _NextButton({required this.onPressed});

  @override
  State<_NextButton> createState() => _NextButtonState();
}

class _NextButtonState extends State<_NextButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        final glow = _pulseAnimation.value * 0.5;
        return SizedBox(
          width: double.infinity,
          child: ShortcutTooltip(
            description: 'Next',
            shortcut: 'Space',
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary
                        .withValues(alpha: 0.25 + glow * 0.3),
                    blurRadius: 8 + glow * 8,
                    spreadRadius: glow * 3,
                  ),
                ],
              ),
              child: FilledButton.icon(
                onPressed: widget.onPressed,
                icon: const Icon(Icons.arrow_forward, size: 20),
                label: const Text(
                  'Next',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// YOUR MOVE PROMPT
// ---------------------------------------------------------------------------

class _YourMovePrompt extends StatelessWidget {
  final MoveDisplayInfo? opponentContext;
  final int currentMoveIndex;
  final RepertoireLine? currentLine;
  final double Function(RepertoireLine, int)? moveDifficulty;

  const _YourMovePrompt({
    this.opponentContext,
    required this.currentMoveIndex,
    this.currentLine,
    this.moveDifficulty,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          if (opponentContext != null) ...[
            _MoveLine(display: opponentContext!, showComment: false),
            Divider(
              height: 20,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ],
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
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              if (currentLine != null &&
                  moveDifficulty != null &&
                  currentMoveIndex < currentLine!.moves.length)
                TrainingMoveDifficultyChip(
                  difficulty: moveDifficulty!(currentLine!, currentMoveIndex),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LEARN PHASE CONTENT (Chessable-style pairs)
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
    final theme = Theme.of(context);

    if (learnQuizzing) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show opponent context above the quiz prompt
            if (currentPairOpponent != null) ...[
              _MovePairCard(
                opponent: currentPairOpponent,
                showOpponentComment: false,
              ),
              const SizedBox(height: 12),
            ],
            Text(
              feedback ?? 'Your move',
              style: theme.textTheme.titleSmall?.copyWith(
                color: feedback != null && feedback!.startsWith('Wrong')
                    ? theme.colorScheme.error
                    : feedback == 'Correct!'
                        ? Colors.green
                        : null,
              ),
            ),
          ],
        ),
      );
    }

    // Opponent move with comment → waiting for Next
    if (opponentWaitingForAck && currentPairOpponent != null) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MovePairCard(opponent: currentPairOpponent),
            const SizedBox(height: 12),
            _NextButton(onPressed: onOpponentAcknowledged),
          ],
        ),
      );
    }

    // User's move shown, waiting for learn-ack
    if (learnWaitingForAck && currentPairUser != null) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MovePairCard(
              opponent: currentPairOpponent,
              user: currentPairUser,
            ),
            const SizedBox(height: 12),
            _NextButton(onPressed: onLearnAcknowledged),
          ],
        ),
      );
    }

    // Showing a move (opponent or user) briefly before auto-advancing
    if (currentPairOpponent != null || currentPairUser != null) {
      return SingleChildScrollView(
        child: _MovePairCard(
          opponent: currentPairOpponent,
          user: currentPairUser,
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

// ---------------------------------------------------------------------------
// DRILL PHASE CONTENT (Chessable-style pairs)
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
    // Waiting for user to play their move
    if (waitingForUser) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (feedback != null && feedback!.isNotEmpty) ...[
              TrainingFeedbackText(feedback: feedback!),
              const SizedBox(height: 8),
            ],
            _YourMovePrompt(
              opponentContext: currentPairOpponent,
              currentMoveIndex: currentMoveIndex,
              currentLine: currentLine,
              moveDifficulty: moveDifficulty,
            ),
          ],
        ),
      );
    }

    // Showing opponent move (with comment) or completed pair while auto-advancing
    if (currentPairOpponent != null || currentPairUser != null) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (feedback != null && feedback!.isNotEmpty) ...[
              TrainingFeedbackText(feedback: feedback!),
              const SizedBox(height: 8),
            ],
            _MovePairCard(
              opponent: currentPairOpponent,
              user: currentPairUser,
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
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
            color: Colors.orange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Replaying missed moves',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: Colors.orange[700]),
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
      color = Colors.green;
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
      color = Colors.green;
    } else if (difficulty > 0) {
      final pct = (difficulty * 100).round();
      label = '$pct% learned';
      color = Colors.orange;
    } else {
      label = 'New move';
      color = theme.colorScheme.onSurfaceVariant;
    }

    return Text(label, style: TextStyle(color: color, fontSize: 12));
  }
}
