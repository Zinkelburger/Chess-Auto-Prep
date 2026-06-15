import 'package:flutter/material.dart';

import '../shortcut_tooltip.dart';

import '../../core/repertoire_controller.dart';
import '../../models/repertoire_line.dart';
import '../../services/training/training_phase.dart';
import '../../widgets/chess_board_widget.dart';

/// Chess board area for active training (learn / drill / replay).
class TrainingBoardPane extends StatelessWidget {
  final RepertoireController session;
  final bool boardFlipped;
  final bool waitingForUser;
  final void Function(CompletedMove move) onMove;

  const TrainingBoardPane({
    super.key,
    required this.session,
    required this.boardFlipped,
    required this.waitingForUser,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
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
  final int replayIndex;
  final int wrongMoveCount;
  final RepertoireLine? currentLine;
  final int currentMoveIndex;
  final double Function(RepertoireLine line, int moveIndex) moveDifficulty;
  final VoidCallback onLearnAcknowledged;

  const TrainingPhasePanel({
    super.key,
    required this.phase,
    this.feedback,
    this.currentAnnotation,
    required this.learnQuizzing,
    required this.learnWaitingForAck,
    required this.replayIndex,
    required this.wrongMoveCount,
    this.currentLine,
    required this.currentMoveIndex,
    required this.moveDifficulty,
    required this.onLearnAcknowledged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (phase) {
      case TrainingPhase.learning:
        return _LearnContent(
          theme: theme,
          feedback: feedback,
          currentAnnotation: currentAnnotation,
          learnQuizzing: learnQuizzing,
          learnWaitingForAck: learnWaitingForAck,
          onLearnAcknowledged: onLearnAcknowledged,
        );
      case TrainingPhase.drilling:
        return _DrillContent(
          theme: theme,
          feedback: feedback,
          currentAnnotation: currentAnnotation,
          currentLine: currentLine,
          currentMoveIndex: currentMoveIndex,
          moveDifficulty: moveDifficulty,
        );
      case TrainingPhase.replaying:
        return _ReplayContent(
          theme: theme,
          feedback: feedback,
          replayIndex: replayIndex,
          wrongMoveCount: wrongMoveCount,
        );
      case TrainingPhase.finished:
        return const SizedBox.shrink();
    }
  }
}

class _LearnContent extends StatelessWidget {
  final ThemeData theme;
  final String? feedback;
  final String? currentAnnotation;
  final bool learnQuizzing;
  final bool learnWaitingForAck;
  final VoidCallback onLearnAcknowledged;

  const _LearnContent({
    required this.theme,
    this.feedback,
    this.currentAnnotation,
    required this.learnQuizzing,
    required this.learnWaitingForAck,
    required this.onLearnAcknowledged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (learnQuizzing) ...[
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
          ] else ...[
            if (currentAnnotation != null && currentAnnotation!.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  currentAnnotation!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (learnWaitingForAck) ...[
              SizedBox(
                width: double.infinity,
                child: ShortcutTooltip(
                  description: 'Next',
                  shortcut: 'Space',
                  child: FilledButton.icon(
                    onPressed: onLearnAcknowledged,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('Next'),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _DrillContent extends StatelessWidget {
  final ThemeData theme;
  final String? feedback;
  final String? currentAnnotation;
  final RepertoireLine? currentLine;
  final int currentMoveIndex;
  final double Function(RepertoireLine line, int moveIndex) moveDifficulty;

  const _DrillContent({
    required this.theme,
    this.feedback,
    this.currentAnnotation,
    this.currentLine,
    required this.currentMoveIndex,
    required this.moveDifficulty,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (feedback != null && feedback!.isNotEmpty) ...[
            TrainingFeedbackText(feedback: feedback!),
            const SizedBox(height: 12),
          ],
          if (currentAnnotation != null && currentAnnotation!.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                currentAnnotation!,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (currentLine != null &&
              currentMoveIndex < currentLine!.moves.length) ...[
            TrainingMoveDifficultyChip(
              difficulty: moveDifficulty(currentLine!, currentMoveIndex),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReplayContent extends StatelessWidget {
  final ThemeData theme;
  final String? feedback;
  final int replayIndex;
  final int wrongMoveCount;

  const _ReplayContent({
    required this.theme,
    this.feedback,
    required this.replayIndex,
    required this.wrongMoveCount,
  });

  @override
  Widget build(BuildContext context) {
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
