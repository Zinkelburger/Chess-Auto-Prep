/// Traps Browser Widget
///
/// Displays trap lines extracted from a generated repertoire. Each trap shows
/// the move sequence leading to the trap position, the opponent's popular
/// (bad) move vs the best move, eval differences, trick surplus, and other
/// annotations matching the C output format.
///
/// Clicking a trap loads its move sequence onto the board, similar to the
/// lines browser.
library;

import 'package:flutter/material.dart';

import '../models/trap_line_info.dart';
import '../theme/app_colors.dart';

class TrapsBrowser extends StatefulWidget {
  final List<TrapLineInfo> traps;
  final List<String> currentMoveSequence;
  final void Function(TrapLineInfo trap)? onTrapSelected;

  const TrapsBrowser({
    super.key,
    required this.traps,
    this.currentMoveSequence = const [],
    this.onTrapSelected,
  });

  @override
  State<TrapsBrowser> createState() => _TrapsBrowserState();
}

class _TrapsBrowserState extends State<TrapsBrowser> {
  String _sortBy = 'surplus'; // 'surplus', 'trap', 'reach', 'eval'
  int? _expandedIndex;

  List<TrapLineInfo> get _sortedTraps {
    final sorted = List<TrapLineInfo>.from(widget.traps);
    switch (_sortBy) {
      case 'trap':
        sorted.sort((a, b) => b.trapScore.compareTo(a.trapScore));
      case 'reach':
        sorted.sort((a, b) => b.cumulativeProb.compareTo(a.cumulativeProb));
      case 'eval':
        sorted.sort((a, b) => b.evalDiffCp.compareTo(a.evalDiffCp));
      default:
        sorted.sort((a, b) => b.trickSurplus.compareTo(a.trickSurplus));
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedTraps;

    return Column(
      children: [
        _buildHeader(sorted.length),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: sorted.length,
            itemBuilder: (context, index) =>
                _buildTrapItem(sorted[index], index),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 16, color: AppColors.warning),
          const SizedBox(width: 8),
          Text(
            '$count trap${count == 1 ? '' : 's'}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _buildSortChip('Surplus', 'surplus'),
          const SizedBox(width: 4),
          _buildSortChip('Trap %', 'trap'),
          const SizedBox(width: 4),
          _buildSortChip('Reach', 'reach'),
          const SizedBox(width: 4),
          _buildSortChip('Eval', 'eval'),
        ],
      ),
    );
  }

  Widget _buildSortChip(String label, String value) {
    final selected = _sortBy == value;
    return GestureDetector(
      onTap: () => setState(() => _sortBy = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? AppColors.warningSurface : Colors.grey[800],
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? Colors.white : Colors.grey[400],
          ),
        ),
      ),
    );
  }

  Widget _buildTrapItem(TrapLineInfo trap, int index) {
    final isExpanded = _expandedIndex == index;
    final currentMoves = widget.currentMoveSequence;
    final matchDepth = _getMatchDepth(trap.movesSan, currentMoves);
    final isPositionMatch =
        matchDepth == currentMoves.length && currentMoves.isNotEmpty;

    return InkWell(
      onTap: () => widget.onTrapSelected?.call(trap),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isPositionMatch
              ? AppColors.warningSurface.withValues(alpha: 0.5)
              : (index % 2 == 0 ? Colors.grey[900] : Colors.grey[850]),
          border: Border(
            left: isPositionMatch
                ? const BorderSide(color: AppColors.warning, width: 3)
                : BorderSide.none,
            bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: rank + key stats
            Row(
              children: [
                // Rank number
                SizedBox(
                  width: 28,
                  child: Text(
                    '${index + 1}.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[500],
                    ),
                  ),
                ),

                // Trick surplus badge
                _buildStatBadge(
                  '${trap.trickSurplus >= 0 ? "+" : ""}${(trap.trickSurplus * 100).toStringAsFixed(1)}%',
                  AppColors.warning,
                  tooltip: 'Trick surplus',
                ),
                const SizedBox(width: 6),

                // Trap score
                _buildStatBadge(
                  '${(trap.trapScore * 100).toStringAsFixed(0)}%',
                  _trapScoreColor(trap.trapScore),
                  tooltip: 'Trap score',
                ),
                const SizedBox(width: 6),

                // Eval diff
                _buildStatBadge(
                  '+${trap.evalDiffCp}cp',
                  AppColors.evalPositive,
                  tooltip: 'Centipawn gain',
                ),

                const Spacer(),

                // Reach probability
                Text(
                  '${(trap.cumulativeProb * 100).toStringAsFixed(2)}% reach',
                  style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                ),

                // Expand/collapse
                IconButton(
                  icon: Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Colors.grey[500],
                  ),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () {
                    setState(() {
                      _expandedIndex = isExpanded ? null : index;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Move sequence with highlighting
            _buildMovesPreview(trap, matchDepth),

            const SizedBox(height: 6),

            // Mistake summary line
            RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                children: [
                  TextSpan(
                    text: trap.popularMove,
                    style: TextStyle(
                      color: AppColors.danger,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                  TextSpan(
                    text:
                        ' (${(trap.popularProb * 100).toStringAsFixed(0)}%) loses ${trap.evalDiffCp}cp vs best ',
                  ),
                  TextSpan(
                    text: trap.bestMove,
                    style: TextStyle(
                      color: AppColors.evalPositive,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),

            // Expanded detail panel
            if (isExpanded) ...[
              const SizedBox(height: 10),
              _buildDetailPanel(trap),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDetailPanel(TrapLineInfo trap) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[700]!, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header matching C PGN annotation format
          Text(
            trap.summary,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.warning,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 8),

          // Detail rows
          _buildDetailRow(
            'Expectimax (V)',
            '${(trap.expectimaxValue * 100).toStringAsFixed(1)}%',
            Icons.trending_up,
            AppColors.info,
          ),
          _buildDetailRow(
            'Win prob from eval',
            '${(trap.wpEval * 100).toStringAsFixed(1)}%',
            Icons.analytics,
            AppColors.maia,
          ),
          _buildDetailRow(
            'Trick surplus',
            '${trap.trickSurplus >= 0 ? "+" : ""}${(trap.trickSurplus * 100).toStringAsFixed(1)}%',
            Icons.auto_awesome,
            AppColors.warning,
          ),
          const SizedBox(height: 6),
          const Divider(height: 1),
          const SizedBox(height: 6),
          _buildDetailRow(
            'Popular move',
            '${trap.popularMove} (${(trap.popularProb * 100).toStringAsFixed(0)}%)',
            Icons.people,
            AppColors.danger,
          ),
          _buildDetailRow(
            'Eval after popular',
            trap.formatEval(trap.popularEvalCp),
            Icons.arrow_downward,
            AppColors.danger,
          ),
          _buildDetailRow(
            'Best move',
            trap.bestMove,
            Icons.star,
            AppColors.evalPositive,
          ),
          _buildDetailRow(
            'Eval after best',
            trap.formatEval(trap.bestEvalCp),
            Icons.arrow_upward,
            AppColors.evalPositive,
          ),
          _buildDetailRow(
            'Centipawn gain',
            '+${trap.evalDiffCp}cp',
            Icons.add_circle_outline,
            AppColors.difficulty,
          ),
          _buildDetailRow(
            'Reach probability',
            '${(trap.cumulativeProb * 100).toStringAsFixed(3)}%',
            Icons.route,
            AppColors.lichessDb,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(
      String label, String value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatBadge(String text, Color color, {String? tooltip}) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: badge) : badge;
  }

  Widget _buildMovesPreview(TrapLineInfo trap, int matchDepth) {
    final moves = trap.movesSan;
    const maxPreviewMoves = 12;

    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (int i = 0; i < moves.length && i < maxPreviewMoves; i++) ...[
          if (i % 2 == 0)
            Text(
              '${(i ~/ 2) + 1}.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                fontFamily: 'monospace',
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: i < matchDepth
                  ? AppColors.warningSurface.withValues(alpha: 0.7)
                  : null,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              moves[i],
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: i < matchDepth ? AppColors.warning : Colors.grey[300],
                fontWeight:
                    i < matchDepth ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
        if (moves.length > maxPreviewMoves)
          Text(
            '... +${moves.length - maxPreviewMoves}',
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
            ),
          ),
      ],
    );
  }

  int _getMatchDepth(List<String> trapMoves, List<String> currentMoves) {
    if (currentMoves.isEmpty) return 0;
    int depth = 0;
    for (int i = 0; i < currentMoves.length && i < trapMoves.length; i++) {
      if (trapMoves[i] != currentMoves[i]) break;
      depth++;
    }
    return depth;
  }

  Color _trapScoreColor(double score) => AppColors.trapScore(score);
}
