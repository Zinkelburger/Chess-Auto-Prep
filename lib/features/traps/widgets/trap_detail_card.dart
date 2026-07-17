/// Rich narrative presentation of a trap position.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/models/trap_reply.dart';
import '../../../constants/chess_constants.dart';
import '../../../theme/app_colors.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../../utils/chess_utils.dart';
import '../../../widgets/clickable_move_line.dart';

class TrapDetailCard extends StatelessWidget {
  final TrapLineInfo trap;
  final int? index;
  final VoidCallback? onShowRefutation;
  final VoidCallback? onShowPath;
  final VoidCallback? onTrainLine;
  final BoardPreviewController boardPreview;

  /// Tap on a specific move in the path — jump to that ply. Falls back to
  /// [onShowPath] (whole line) when null.
  final void Function(int ply)? onMoveTapped;

  const TrapDetailCard({
    super.key,
    required this.trap,
    this.index,
    this.onShowRefutation,
    this.onShowPath,
    this.onTrainLine,
    required this.boardPreview,
    this.onMoveTapped,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(theme),
            const SizedBox(height: 8),
            _buildMovePath(),
            const SizedBox(height: 12),
            _buildNarrative(theme),
            const SizedBox(height: 12),
            _buildComparison(theme),
            if (trap.refutationMove != null) ...[
              const SizedBox(height: 12),
              _buildRefutation(theme),
            ],
            const Divider(height: 24),
            _buildStatRow(theme),
            const Divider(height: 24),
            if (trap.allReplies != null && trap.allReplies!.isNotEmpty)
              _buildRepliesTable(theme),
            const SizedBox(height: 8),
            _buildWinProbLine(theme),
            const SizedBox(height: 12),
            _buildActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      children: [
        if (index != null) ...[
          Text(
            'Trap #${index! + 1}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
        ],
        if (trap.openingName != null)
          Text(
            trap.openingName!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
      ],
    );
  }

  Widget _buildMovePath() {
    return ClickableMoveLineWidget(
      sanMoves: trap.movesSan,
      startPly: 0,
      maxMoves: trap.movesSan.length,
      onMoveTapped:
          onMoveTapped ?? (onShowPath != null ? (_) => onShowPath!() : null),
      onMoveHovered: (idx, _) {
        final fen = fenAfterMoves(kStandardStartFen, trap.movesSan, idx);
        boardPreview.setPreview(fen);
      },
      onHoverExit: () => boardPreview.clearPreview(),
    );
  }

  Widget _buildNarrative(ThemeData theme) {
    final probPct = (trap.popularProb * 100).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$probPct% of opponents play ${trap.popularMove} here',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComparison(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: _ComparisonBox(
            title: 'HUMAN MOVE',
            move: trap.popularMove,
            evalText: trap.formatEval(trap.popularEvalCp),
            probText: '${(trap.popularProb * 100).toStringAsFixed(0)}%',
            classification: 'BLUNDER',
            classColor: AppColors.danger,
            icon: Icons.close,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ComparisonBox(
            title: 'BEST MOVE',
            move: trap.bestMove,
            evalText: trap.formatEval(trap.bestEvalCp),
            probText: _bestMoveProb(),
            classification: 'BEST',
            classColor: AppColors.success,
            icon: Icons.check,
          ),
        ),
      ],
    );
  }

  Widget _buildRefutation(ThemeData theme) {
    final evalText = trap.refutationEvalCp != null
        ? trap.formatEval(trap.refutationEvalCp!)
        : '?';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.success.withAlpha(60)),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 18, color: AppColors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOUR REPLY',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'After ${trap.popularMove}, play ',
                        style: const TextStyle(fontSize: 13),
                      ),
                      TextSpan(
                        text: trap.refutationMove!,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextSpan(
                        text: ' (eval $evalText)',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _bestMoveProb() {
    if (trap.allReplies == null) return '?';
    final best = trap.allReplies!.where(
      (r) => r.classification == TrapReplyClass.good,
    );
    if (best.isEmpty) return '?';
    return '${(best.first.probability * 100).toStringAsFixed(0)}%';
  }

  Widget _buildStatRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _StatChip(
          label: 'YOU GAIN',
          value: '+${trap.evalDiffCp}cp',
          color: AppColors.success,
        ),
        _StatChip(
          label: 'REACH',
          value: '${(trap.cumulativeProb * 100).toStringAsFixed(2)}%',
          color: theme.colorScheme.primary,
        ),
        _StatChip(
          label: 'SURPLUS',
          value: '${(trap.trickSurplus * 100).toStringAsFixed(1)}%',
          color: AppColors.warning,
        ),
      ],
    );
  }

  Widget _buildRepliesTable(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ALL OPPONENT RESPONSES',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(2),
            1: FlexColumnWidth(1.2),
            2: FlexColumnWidth(1.5),
            3: FlexColumnWidth(2),
          },
          children: [
            TableRow(
              children: [
                _headerCell('Move'),
                _headerCell('Prob'),
                _headerCell('Eval'),
                _headerCell('Class'),
              ],
            ),
            ...trap.allReplies!.map((r) => _buildReplyRow(r, theme)),
          ],
        ),
      ],
    );
  }

  TableRow _buildReplyRow(TrapReply reply, ThemeData theme) {
    final classInfo = _classInfo(reply.classification);
    return TableRow(
      children: [
        MouseRegion(
          onEnter: (_) {
            if (trap.fen != null) {
              final fen = fenAfterMoves(trap.fen!, [reply.san], 0);
              boardPreview.setPreview(fen);
            }
          },
          onExit: (_) => boardPreview.clearPreview(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              reply.san,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('${(reply.probability * 100).toStringAsFixed(0)}%'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(trap.formatEval(reply.evalAfterCp)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(classInfo.$2, size: 14, color: classInfo.$3),
              const SizedBox(width: 4),
              Text(
                classInfo.$1,
                style: TextStyle(fontSize: 11, color: classInfo.$3),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _headerCell(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: AppColors.onSurfaceMuted,
        ),
      ),
    );
  }

  (String, IconData, Color) _classInfo(TrapReplyClass c) {
    return switch (c) {
      TrapReplyClass.blunder => (
        'BLUNDER',
        Icons.close,
        AppColors.replyBlunder,
      ),
      TrapReplyClass.mistake => (
        'MISTAKE',
        Icons.error_outline,
        AppColors.replyMistake,
      ),
      TrapReplyClass.inaccuracy => (
        'INACCURACY',
        Icons.warning_amber,
        AppColors.replyInaccuracy,
      ),
      TrapReplyClass.acceptable => (
        'ACCEPTABLE',
        Icons.remove,
        AppColors.replyAcceptable,
      ),
      TrapReplyClass.good => ('GOOD', Icons.check, AppColors.replyGood),
    };
  }

  Widget _buildWinProbLine(ThemeData theme) {
    final practicalPct = (trap.expectimaxValue * 100).toStringAsFixed(1);
    final rawPct = (trap.wpEval * 100).toStringAsFixed(1);
    final surplus = (trap.trickSurplus * 100).toStringAsFixed(1);
    return Text(
      'Practical win probability: $practicalPct% · raw eval equivalent: '
      '$rawPct% · difference: +$surplus%',
      style: theme.textTheme.bodySmall,
    );
  }

  Widget _buildActions() {
    return Wrap(
      spacing: 8,
      children: [
        if (onShowRefutation != null)
          TextButton.icon(
            onPressed: onShowRefutation,
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Show Refutation'),
          ),
        if (onShowPath != null)
          TextButton.icon(
            onPressed: onShowPath,
            icon: const Icon(Icons.route, size: 16),
            label: const Text('Show Full Line'),
          ),
        if (onTrainLine != null)
          TextButton.icon(
            onPressed: onTrainLine,
            icon: const Icon(Icons.school, size: 16),
            label: const Text('Train This Line'),
          ),
      ],
    );
  }
}

class _ComparisonBox extends StatelessWidget {
  final String title;
  final String move;
  final String evalText;
  final String probText;
  final String classification;
  final Color classColor;
  final IconData icon;

  const _ComparisonBox({
    required this.title,
    required this.move,
    required this.evalText,
    required this.probText,
    required this.classification,
    required this.classColor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: classColor.withAlpha(80)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: classColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            move,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Text('Eval: $evalText', style: const TextStyle(fontSize: 12)),
          Text('Probability: $probText', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: classColor),
              const SizedBox(width: 4),
              Text(
                classification,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: classColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: AppColors.onSurfaceMuted),
        ),
      ],
    );
  }
}
