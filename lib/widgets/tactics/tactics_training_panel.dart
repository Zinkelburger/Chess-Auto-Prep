import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../models/tactics_position.dart';
import '../../services/tactics_engine.dart';
import 'tactics_delayed_tooltip.dart';

/// Puzzle-solving controls shown during an active tactics session.
class TacticsTrainingPanel extends StatelessWidget {
  const TacticsTrainingPanel({
    super.key,
    required this.position,
    required this.engine,
    required this.currentMoveIndex,
    required this.positionSolved,
    required this.showSolution,
    required this.feedback,
    required this.autoAdvance,
    required this.onToggleSolution,
    required this.onAnalyze,
    required this.onResetAnalysis,
    required this.onPreviousPosition,
    required this.onSkipPosition,
    required this.onAutoAdvanceChanged,
    required this.onCopyFen,
  });

  final TacticsPosition position;
  final TacticsEngine engine;
  final int currentMoveIndex;
  final bool positionSolved;
  final bool showSolution;
  final String feedback;
  final bool autoAdvance;
  final VoidCallback onToggleSolution;
  final VoidCallback onAnalyze;
  final VoidCallback onResetAnalysis;
  final VoidCallback onPreviousPosition;
  final VoidCallback onSkipPosition;
  final ValueChanged<bool> onAutoAdvanceChanged;
  final VoidCallback onCopyFen;

  Color _feedbackColor() {
    if (feedback.contains('Correct')) return Colors.green;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TacticsPositionInfo(position: position, engine: engine),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: tacticsShortcutTooltip(
                message: 'space',
                child: ElevatedButton(
                  onPressed: onToggleSolution,
                  child: Text(showSolution ? 'Hide Solution' : 'Show Solution'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Builder(
                builder: (context) {
                  final appState = context.watch<AppState>();
                  final isAtStartingPosition = positionSolved ||
                      appState.currentPosition.fen == position.fen;
                  if (isAtStartingPosition) {
                    return tacticsShortcutTooltip(
                      message: 'a',
                      child: ElevatedButton(
                        onPressed: onAnalyze,
                        child: const Text('Analyze'),
                      ),
                    );
                  } else {
                    return tacticsShortcutTooltip(
                      message: 'a',
                      child: ElevatedButton.icon(
                        onPressed: onResetAnalysis,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Reset'),
                      ),
                    );
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: tacticsShortcutTooltip(
                message: 'b',
                child: ElevatedButton(
                  onPressed: onPreviousPosition,
                  child: const Text('Previous'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: tacticsShortcutTooltip(
                message: 'n',
                child: ElevatedButton(
                  onPressed: onSkipPosition,
                  child: const Text('Skip'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          value: autoAdvance,
          onChanged: (value) => onAutoAdvanceChanged(value ?? true),
          title: const Text('Auto-advance to next position'),
          contentPadding: EdgeInsets.zero,
        ),
        Stack(
          children: [
            Visibility(
              visible: showSolution && feedback.isEmpty,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'Solution: ${engine.getSolution(position, fromIndex: currentMoveIndex)}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: showSolution ? onCopyFen : null,
                      child: const Text('Copy FEN'),
                    ),
                  ],
                ),
              ),
            ),
            if (feedback.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _feedbackColor().withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _feedbackColor()),
                ),
                child: Text(
                  feedback,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _feedbackColor(),
                    fontSize: 16,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Context and game info for the current tactic position.
class TacticsPositionInfo extends StatelessWidget {
  const TacticsPositionInfo({
    super.key,
    required this.position,
    required this.engine,
  });

  final TacticsPosition position;
  final TacticsEngine engine;

  @override
  Widget build(BuildContext context) {
    final pos = position;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          pos.positionContext,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 12),
        Text('Game: ${pos.gameWhite} vs ${pos.gameBlack}',
            style: const TextStyle(fontSize: 14)),
        if (pos.userMove.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'You played: ${pos.userMove}${pos.mistakeType}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          if (pos.opponentBestResponse.isNotEmpty)
            Text(
              'Allows: ${pos.opponentBestResponse}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
        ],
        if (engine.userMoveCount(pos) > 1) ...[
          const SizedBox(height: 4),
          Text(
            'Multi-move tactic (${engine.userMoveCount(pos)} moves)',
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ],
    );
  }
}
