import 'package:flutter/material.dart';

import '../../models/tactics_position.dart';
import '../../services/tactics_engine.dart';
import '../../utils/pgn_comment_utils.dart' show filterDisplayComment;
import '../clickable_move_line.dart';
import '../shortcut_tooltip.dart';

/// Puzzle-solving controls shown during an active tactics session.
class TacticsTrainingPanel extends StatelessWidget {
  const TacticsTrainingPanel({
    super.key,
    required this.position,
    required this.engine,
    required this.currentMoveIndex,
    required this.positionSolved,
    required this.showSolution,
    required this.isAtStartingPosition,
    required this.feedback,
    required this.autoAdvance,
    required this.onToggleSolution,
    required this.onAnalyze,
    required this.onResetAnalysis,
    required this.onPreviousPosition,
    required this.onSkipPosition,
    required this.onAutoAdvanceChanged,
    required this.onCopyFen,
    required this.onSetRating,
    this.solutionSanMoves = const [],
    this.solutionStartPly = 0,
    this.activeSolutionMoveIndex,
    this.onSolutionMoveTapped,
  });

  final TacticsPosition position;
  final TacticsEngine engine;
  final int currentMoveIndex;
  final bool positionSolved;
  final bool showSolution;
  final bool isAtStartingPosition;
  final String feedback;
  final bool autoAdvance;
  final VoidCallback onToggleSolution;
  final VoidCallback onAnalyze;
  final VoidCallback onResetAnalysis;
  final VoidCallback onPreviousPosition;
  final VoidCallback onSkipPosition;
  final ValueChanged<bool> onAutoAdvanceChanged;
  final VoidCallback onCopyFen;
  final ValueChanged<int> onSetRating;
  final List<String> solutionSanMoves;
  final int solutionStartPly;
  final int? activeSolutionMoveIndex;
  final void Function(List<String> sanMoves, int clickedIndex)?
      onSolutionMoveTapped;

  bool get _showRating => !autoAdvance && (positionSolved || showSolution);

  bool get _useNextLabel => positionSolved || showSolution;

  /// The puzzle's note (annotation / mistake analysis) is the flashcard
  /// "back": revealed once the puzzle is solved or the solution shown.
  bool get _showNote =>
      (positionSolved || showSolution) &&
      filterDisplayComment(position.mistakeAnalysis).isNotEmpty;

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
              child: shortcutTooltip(
                description: showSolution ? 'Hide solution' : 'Show solution',
                shortcut: 'Space',
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onToggleSolution,
                    child:
                        Text(showSolution ? 'Hide Solution' : 'Show Solution'),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: isAtStartingPosition
                  ? shortcutTooltip(
                      description: 'Analyze',
                      shortcut: 'A',
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: onAnalyze,
                          child: const Text('Analyze'),
                        ),
                      ),
                    )
                  : shortcutTooltip(
                      description: 'Reset analysis',
                      shortcut: 'A',
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: onResetAnalysis,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Reset'),
                        ),
                      ),
                    ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: shortcutTooltip(
                description: 'Previous position',
                shortcut: 'P',
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onPreviousPosition,
                    child: const Text('Previous'),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: shortcutTooltip(
                description: _useNextLabel ? 'Next position' : 'Skip position',
                shortcut: 'N',
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onSkipPosition,
                    child: Text(_useNextLabel ? 'Next' : 'Skip'),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ShortcutTooltip(
          description: 'Toggle auto-advance to next position',
          shortcut: 'J',
          child: CheckboxListTile(
            value: autoAdvance,
            onChanged: (value) => onAutoAdvanceChanged(value ?? true),
            title: const Text('Auto-advance to next position'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (feedback.isNotEmpty) ...[
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
          if (showSolution) const SizedBox(height: 8),
        ],
        if (_showNote) ...[
          _NoteCard(note: position.mistakeAnalysis),
          const SizedBox(height: 8),
        ],
        _buildPlayedMoves(),
        if (showSolution)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildSolutionLine(context)),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: onCopyFen,
                      child: const Text('Copy FEN'),
                    ),
                  ],
                ),
                if (solutionSanMoves.isEmpty &&
                    position.correctLine.isEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'No solution available',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),
                ],
              ],
            ),
          ),
        if (_showRating) ...[
          const SizedBox(height: 12),
          _TacticsStarRating(
            rating: position.rating,
            onSetRating: onSetRating,
          ),
        ],
      ],
    );
  }

  Widget _buildPlayedMoves() {
    if (currentMoveIndex == 0) return const SizedBox.shrink();
    final totalUserMoves = engine.userMoveCount(position);
    if (totalUserMoves <= 1) return const SizedBox.shrink();

    final played = position.correctLine.sublist(
      0,
      currentMoveIndex.clamp(0, position.correctLine.length),
    );
    if (played.isEmpty) return const SizedBox.shrink();

    final buf = StringBuffer();
    var moveNum = (solutionStartPly ~/ 2) + 1;
    var isWhite = solutionStartPly % 2 == 0;

    for (int i = 0; i < played.length; i++) {
      if (isWhite) {
        buf.write('$moveNum. ');
      } else if (i == 0) {
        buf.write('$moveNum... ');
      }
      buf.write(played[i]);
      if (!isWhite) moveNum++;
      isWhite = !isWhite;
      if (i < played.length - 1) buf.write(' ');
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        buf.toString(),
        style: TextStyle(fontSize: 14, color: Colors.grey[400]),
      ),
    );
  }

  Widget _buildSolutionLine(BuildContext context) {
    final san = solutionSanMoves;
    if (san.isEmpty) {
      final fallback = engine.getSolution(position, fromIndex: 0);
      if (fallback == 'No solution available') {
        return Text(
          fallback,
          style: TextStyle(fontSize: 13, color: Colors.grey[500]),
        );
      }
      return Text(
        fallback,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
      );
    }

    final trainablePlies = position.correctLine.length;
    final highlightIndex = activeSolutionMoveIndex ??
        (currentMoveIndex < trainablePlies ? currentMoveIndex : null);

    return ClickableMoveLineWidget(
      key: const Key('tactic-solution-line'),
      sanMoves: san,
      startPly: solutionStartPly,
      maxMoves: san.length,
      singleLine: false,
      fontSize: 14,
      movePadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      activeMoveIndex: highlightIndex,
      onMoveTapped: onSolutionMoveTapped != null
          ? (idx) => onSolutionMoveTapped!(san, idx)
          : null,
    );
  }
}

/// The puzzle's annotation, shown after solving (flashcard back).
class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sticky_note_2_outlined,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // Notes come from scraped PGN comments — strip engine tokens and
              // collapse stray double spaces into readable prose.
              filterDisplayComment(note),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact 1-5 star rating row for tactic quality.
class _TacticsStarRating extends StatelessWidget {
  const _TacticsStarRating({
    required this.rating,
    required this.onSetRating,
  });

  final int rating;
  final ValueChanged<int> onSetRating;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'Rate:',
          style: TextStyle(fontSize: 13, color: Colors.grey[400]),
        ),
        const SizedBox(width: 8),
        for (int star = 1; star <= 5; star++)
          Tooltip(
            message: 'Rate $star star${star > 1 ? 's' : ''}',
            child: GestureDetector(
              onTap: () => onSetRating(rating == star ? 0 : star),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  star <= rating ? Icons.star : Icons.star_border,
                  size: 24,
                  color: star <= rating ? Colors.amber : Colors.grey[600],
                ),
              ),
            ),
          ),
        if (rating > 0)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              rating == 1 ? '(hidden from training)' : '',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
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
            '${engine.userMoveCount(pos)}-move tactic',
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ],
    );
  }
}
