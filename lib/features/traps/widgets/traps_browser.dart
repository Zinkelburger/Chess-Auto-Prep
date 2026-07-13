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
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/models/trap_reply.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/pgn_comment_utils.dart' show nagColor;
import '../../../widgets/chess_board_widget.dart';
import '../../../theme/app_colors.dart';
import 'trap_detail_card.dart';
import 'trap_summary_header.dart';

enum TrapFilter { all, inRepertoire }

class TrapsBrowser extends StatefulWidget {
  final List<TrapLineInfo> traps;
  final List<String> currentMoveSequence;
  final BoardPreviewController? boardPreview;
  final void Function(TrapLineInfo trap)? onTrapSelected;

  /// Tap on a specific move inside the expanded detail card — load the trap
  /// line and jump to that ply.
  final void Function(TrapLineInfo trap, int ply)? onTrapMoveSelected;
  final TrapRepertoireMetrics? metrics;
  final VoidCallback? onStartTour;

  /// Repertoire line move lists for "In Repertoire" filtering.
  /// When non-empty, enables the filter toggle.
  final List<List<String>> repertoireLineMoves;

  const TrapsBrowser({
    super.key,
    required this.traps,
    this.currentMoveSequence = const [],
    this.boardPreview,
    this.onTrapSelected,
    this.onTrapMoveSelected,
    this.metrics,
    this.onStartTour,
    this.repertoireLineMoves = const [],
  });

  @override
  State<TrapsBrowser> createState() => _TrapsBrowserState();
}

class _TrapsBrowserState extends State<TrapsBrowser> {
  String _sortBy = 'eval'; // 'eval', 'reach', 'surplus', 'trap'
  String? _expandedTrapKey;
  TrapFilter _filter = TrapFilter.all;

  static String _trapKey(TrapLineInfo trap) =>
      trap.fen ?? trap.movesSan.join('/');

  bool _isTrapInRepertoire(TrapLineInfo trap) {
    for (final lineMoves in widget.repertoireLineMoves) {
      if (trap.movesSan.length <= lineMoves.length &&
          _isPrefix(trap.movesSan, lineMoves)) {
        return true;
      }
    }
    return false;
  }

  static bool _isPrefix(List<String> prefix, List<String> line) {
    for (int i = 0; i < prefix.length; i++) {
      if (prefix[i] != line[i]) return false;
    }
    return true;
  }

  List<TrapLineInfo> get _filteredTraps {
    if (_filter == TrapFilter.all || widget.repertoireLineMoves.isEmpty) {
      return widget.traps;
    }
    return widget.traps.where(_isTrapInRepertoire).toList();
  }

  static int _expectedGainCp(TrapLineInfo trap) =>
      (trap.evalDiffCp * trap.popularProb).round();

  List<TrapLineInfo> get _sortedTraps {
    final sorted = List<TrapLineInfo>.from(_filteredTraps);
    switch (_sortBy) {
      case 'expected':
        sorted.sort(
            (a, b) => _expectedGainCp(b).compareTo(_expectedGainCp(a)));
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
        if (widget.metrics != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TrapSummaryHeader(metrics: widget.metrics!),
          ),
        ],
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
    final hasRepertoireData = widget.repertoireLineMoves.isNotEmpty;
    final inRepCount = hasRepertoireData
        ? widget.traps.where(_isTrapInRepertoire).length
        : 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 16, color: AppColors.warning),
              const SizedBox(width: 8),
              Text(
                '$count trap${count == 1 ? '' : 's'}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.onStartTour != null && count > 0) ...[
                const SizedBox(width: 10),
                Tooltip(
                  message: 'Walk through every trap on the board, '
                      'one at a time (T)',
                  child: FilledButton.icon(
                    onPressed: widget.onStartTour,
                    icon: const Icon(Icons.tour, size: 16),
                    label: const Text('Start Trap Tour'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.warning,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (hasRepertoireData) ...[
                _buildFilterChip(
                  'All (${ widget.traps.length})',
                  TrapFilter.all,
                  tooltip: 'All traps found in the explored tree',
                ),
                const SizedBox(width: 4),
                _buildFilterChip(
                  'In Repertoire ($inRepCount)',
                  TrapFilter.inRepertoire,
                  tooltip: 'Traps along your chosen repertoire lines',
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _buildSortChip('Eval Drop', 'eval'),
              const SizedBox(width: 4),
              _buildSortChip('Most Common', 'reach'),
              const SizedBox(width: 4),
              _buildSortChip('Expected Gain', 'expected'),
              const SizedBox(width: 4),
              _buildSortChip('Surplus', 'surplus'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, TrapFilter value, {String? tooltip}) {
    final selected = _filter == value;
    final chip = GestureDetector(
      onTap: () => setState(() => _filter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? AppColors.warning.withValues(alpha: 0.2) : Colors.grey[800],
          borderRadius: BorderRadius.circular(10),
          border: selected
              ? Border.all(color: AppColors.warning.withValues(alpha: 0.5), width: 1)
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? AppColors.warning : Colors.grey[400],
          ),
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: chip) : chip;
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
    final key = _trapKey(trap);
    final isExpanded = _expandedTrapKey == key;
    final currentMoves = widget.currentMoveSequence;
    final matchDepth = _getMatchDepth(trap.movesSan, currentMoves);
    final isPositionMatch =
        matchDepth == currentMoves.length && currentMoves.isNotEmpty;
    final position = trap.fen != null ? tryParseFen(trap.fen!) : null;
    final replies = trap.allReplies ?? const [];
    final topReplies = replies.take(4).toList();

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
            // Header: rank + opening + reach + expand
            Row(
              children: [
                Text(
                  '#${index + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[500],
                  ),
                ),
                if (trap.openingName != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trap.openingName!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey[300],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else
                  const Spacer(),
                _buildStatBadge(
                  '${(trap.cumulativeProb * 100).toStringAsFixed(1)}% reach',
                  Colors.blueGrey,
                  tooltip: 'Probability of reaching this position',
                ),
                const SizedBox(width: 4),
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
                      _expandedTrapKey = isExpanded ? null : key;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Move sequence
            _buildMovesPreview(trap, matchDepth),
            const SizedBox(height: 8),

            // Main content: mini board + reply stats
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (position != null)
                  Container(
                    width: 120,
                    height: 120,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.grey[700]!,
                        width: 0.5,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IgnorePointer(
                      child: ChessBoardWidget(
                        position: position,
                        enableUserMoves: false,
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Opponent replies:',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[500],
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final reply in topReplies)
                        _buildReplyRow(reply, trap),
                      if (replies.length > 4)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '+${replies.length - 4} more',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[600],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Bottom stat badges
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildStatBadge(
                  '${(trap.popularProb * 100).toStringAsFixed(0)}% play '
                  '${trap.popularMove}',
                  _trapScoreColor(trap.trapScore),
                  tooltip:
                      'Share of opponents who play ${trap.popularMove} here',
                ),
                _buildStatBadge(
                  '+${_expectedGainCp(trap)}cp expected',
                  AppColors.evalPositive,
                  tooltip: 'Expected gain: +${trap.evalDiffCp}cp × '
                      '${(trap.popularProb * 100).toStringAsFixed(0)}% '
                      'chance they play ${trap.popularMove}',
                ),
                _buildStatBadge(
                  '+${(trap.trickSurplus * 100).toStringAsFixed(1)}% surplus',
                  AppColors.warning,
                  tooltip: 'Practical advantage beyond raw eval',
                ),
              ],
            ),

            // Expanded detail panel
            if (isExpanded && widget.boardPreview != null) ...[
              const SizedBox(height: 10),
              TrapDetailCard(
                trap: trap,
                index: index,
                boardPreview: widget.boardPreview!,
                onShowPath: () => widget.onTrapSelected?.call(trap),
                onMoveTapped: widget.onTrapMoveSelected == null
                    ? null
                    : (ply) => widget.onTrapMoveSelected!(trap, ply),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReplyRow(TrapReply reply, TrapLineInfo trap) {
    final evalDrop = (trap.positionEvalCp ?? 0) - reply.evalAfterCp;
    final isGood = reply.classification == TrapReplyClass.good;
    final isBad = reply.classification == TrapReplyClass.blunder ||
        reply.classification == TrapReplyClass.mistake;

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              reply.san,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                // NAG palette: brighter on dark than danger/evalPositive.
                color: isGood
                    ? nagColor(1)
                    : isBad
                        ? nagColor(4)
                        : Colors.orange[300],
              ),
            ),
          ),
          if (!isGood && evalDrop > 0)
            Text(
              'drops ${evalDrop}cp',
              style: TextStyle(
                fontSize: 10,
                color: isBad ? AppColors.danger : Colors.orange[300],
              ),
            )
          else if (isGood)
            const Text(
              'best move',
              style: TextStyle(
                fontSize: 10,
                color: AppColors.evalPositive,
              ),
            ),
          const Spacer(),
          Text(
            '${(reply.probability * 100).toStringAsFixed(0)}%',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.grey[400],
            ),
          ),
          const SizedBox(width: 6),
          _buildClassBadge(reply.classification),
        ],
      ),
    );
  }

  Widget _buildClassBadge(TrapReplyClass cls) {
    final (label, color) = switch (cls) {
      TrapReplyClass.blunder => ('BLUNDER', AppColors.danger),
      TrapReplyClass.mistake => ('MISTAKE', Colors.orange),
      TrapReplyClass.inaccuracy => ('INACCURACY', Colors.amber),
      TrapReplyClass.acceptable => ('OK', Colors.grey),
      TrapReplyClass.good => ('BEST', AppColors.evalPositive),
    };
    // Same contrast rule as _buildStatBadge: near-white text, colour only in
    // the tint/border.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: Color(0xFFE8E8E8),
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  /// Near-white text on a dim tint of [color]; the colour carries meaning via
  /// the tint/border only. (Coloured text on a same-colour wash — red on red,
  /// amber on amber — was unreadable.)
  Widget _buildStatBadge(String text, Color color, {String? tooltip}) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Color(0xFFE8E8E8),
          fontFamily: 'monospace',
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: badge) : badge;
  }

  /// Full line to the trap position, then the opponent's popular move (with
  /// its quality glyph) and our refutation — the whole trap in one line.
  Widget _buildMovesPreview(TrapLineInfo trap, int matchDepth) {
    final moves = trap.movesSan;

    TrapReply? popularReply;
    for (final r in trap.allReplies ?? const <TrapReply>[]) {
      if (r.san == trap.popularMove) {
        popularReply = r;
        break;
      }
    }
    final popularGlyph = switch (popularReply?.classification) {
      TrapReplyClass.mistake => '?',
      TrapReplyClass.inaccuracy => '?!',
      TrapReplyClass.acceptable || TrapReplyClass.good => '',
      // Blunder, or no reply data (legacy files treat the popular move as one).
      _ => '??',
    };

    // (text, color, bold) for every ply: lead-up, popular move, refutation.
    final plies = <(String, Color?, bool)>[
      for (int i = 0; i < moves.length; i++)
        (
          moves[i],
          i < matchDepth ? AppColors.warning : Colors.grey[300],
          i < matchDepth,
        ),
      ('${trap.popularMove}$popularGlyph', nagColor(4), true),
      if (trap.refutationMove != null) (trap.refutationMove!, nagColor(1), true),
    ];

    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (int i = 0; i < plies.length; i++) ...[
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
              plies[i].$1,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: plies[i].$2,
                fontWeight: plies[i].$3 ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
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
