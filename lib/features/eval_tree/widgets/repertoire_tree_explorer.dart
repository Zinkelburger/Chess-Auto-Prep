import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/ease_utils.dart' show winProbability;
import '../../../utils/chess_utils.dart' show formatPackedEval;
import '../tree_colors.dart';
import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';
import '../services/eval_tree_line_metrics.dart';
import '../../../utils/movetext_builder.dart';

/// Engine-style line browser for a generated repertoire [EvalTreeSnapshot].
///
/// Shows candidate moves at the current position with ease scores, expected
/// ease deeper in each line, and trap counts — and lets the user click through
/// to build their own exploration path.
class RepertoireTreeExplorer extends StatelessWidget {
  final EvalTreeSnapshot snapshot;
  final EvalTreeController controller;
  final EvalTreeLineMetricsCache metricsCache;
  final EvalTreeNodeSnapshot currentNode;

  const RepertoireTreeExplorer({
    super.key,
    required this.snapshot,
    required this.controller,
    required this.metricsCache,
    required this.currentNode,
  });

  @override
  Widget build(BuildContext context) {
    final isOurTurn = currentNode.sideToMoveIsWhite == snapshot.playAsWhite;
    final candidates = buildCandidateRows(
      snapshot: snapshot,
      metricsCache: metricsCache,
      currentNodeId: currentNode.id,
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _PositionHeader(
            snapshot: snapshot,
            currentNode: currentNode,
            isOurTurn: isOurTurn,
            onBack: currentNode.parentId != null ? controller.goParent : null,
            onRoot: controller.goRoot,
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverToBoxAdapter(child: _PositionStatsBar(currentNode: currentNode)),
        if (currentNode.evalForUsCp != null)
          SliverToBoxAdapter(
            child: _WinProbBar(evalCp: currentNode.evalForUsCp!),
          ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverToBoxAdapter(child: _CandidateTableHeader(isOurTurn: isOurTurn)),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        if (candidates.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LeafPlaceholder(currentNode: currentNode),
          )
        else
          SliverList.builder(
            itemCount: candidates.length,
            itemBuilder: (context, index) => _CandidateRow(
              row: candidates[index],
              isOurTurn: isOurTurn,
              onTap: () => controller.selectNode(
                candidates[index].node.id,
                requestFocus: false,
              ),
            ),
          ),
      ],
    );
  }
}

class _PositionHeader extends StatelessWidget {
  final EvalTreeSnapshot snapshot;
  final EvalTreeNodeSnapshot currentNode;
  final bool isOurTurn;
  final VoidCallback? onBack;
  final VoidCallback onRoot;

  const _PositionHeader({
    required this.snapshot,
    required this.currentNode,
    required this.isOurTurn,
    required this.onBack,
    required this.onRoot,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final movePath = _formatMovePath(snapshot, currentNode.id);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _RoleBadge(isOurTurn: isOurTurn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  movePath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.home_outlined, size: 18),
                tooltip: 'Back to root',
                onPressed: onRoot,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                tooltip: 'Previous move',
                onPressed: onBack,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            currentNode.fen,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'SourceCodePro',
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final bool isOurTurn;

  const _RoleBadge({required this.isOurTurn});

  @override
  Widget build(BuildContext context) {
    return Text(
      isOurTurn ? 'Our move' : 'Opponent',
      style: const TextStyle(
        fontSize: 12,
        color: AppColors.onSurfaceSoft,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _PositionStatsBar extends StatelessWidget {
  final EvalTreeNodeSnapshot currentNode;

  const _PositionStatsBar({required this.currentNode});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];

    final evalCp = currentNode.evalForUsCp;
    if (evalCp != null) {
      chips.add(_StatChip(label: 'Eval', value: _formatEval(evalCp)));
    }

    if (currentNode.ease != null) {
      chips.add(
        _StatChip(label: 'Ease', value: currentNode.ease!.toStringAsFixed(2)),
      );
    }

    if (currentNode.expectimaxValue != null) {
      chips.add(
        _StatChip(
          label: 'V',
          value: '${(currentNode.expectimaxValue! * 100).toStringAsFixed(1)}%',
        ),
      );
    }

    chips.add(
      _StatChip(
        label: 'Reach',
        value:
            '${(currentNode.cumulativeProbability * 100).toStringAsFixed(1)}%',
      ),
    );

    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(spacing: 12, runSpacing: 4, children: chips),
    );
  }
}

class _WinProbBar extends StatelessWidget {
  final int evalCp;

  const _WinProbBar({required this.evalCp});

  @override
  Widget build(BuildContext context) {
    final winProb = winProbability(evalCp);
    return Container(
      height: 8,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.outline, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Row(
          children: [
            Expanded(
              flex: (winProb * 1000).round().clamp(1, 999),
              child: Container(color: AppColors.sideWhite),
            ),
            Expanded(
              flex: ((1 - winProb) * 1000).round().clamp(1, 999),
              child: Container(color: AppColors.sideBlack),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateTableHeader extends StatelessWidget {
  final bool isOurTurn;

  const _CandidateTableHeader({required this.isOurTurn});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.onSurfaceMuted,
      letterSpacing: 0.4,
    );

    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 22, child: Text('#', style: style)),
          SizedBox(width: 54, child: Text('MOVE', style: style)),
          SizedBox(
            width: 52,
            child: Text('EVAL', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: 40,
            child: Text('EASE', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 40,
            child: Text('NATRL', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            child: Text('EXP EASE', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 44,
            child: Text('TRAPS', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 40,
            child: Text('DB%', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  final EvalTreeCandidateRow row;
  final bool isOurTurn;
  final VoidCallback onTap;

  const _CandidateRow({
    required this.row,
    required this.isOurTurn,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final node = row.node;
    final evalCp = node.evalForUsCp;
    final isRepertoire = node.isRepertoireMove;
    final positionEase = node.ease;
    final deepEase = row.lineMetrics.expectedEaseDeep;
    final trapCount = row.lineMetrics.subtreeTrapCount;

    return Material(
      color: isRepertoire
          ? kNodeColorOurMove.withValues(alpha: 0.12)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            border: Border(
              bottom: const BorderSide(color: AppColors.divider, width: 0.5),
              left: isRepertoire
                  ? const BorderSide(color: kNodeAccentRepertoire, width: 3)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${row.rank}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.onSurfaceMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                width: 54,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isRepertoire)
                      const Padding(
                        padding: EdgeInsets.only(right: 2),
                        child: Icon(
                          Icons.star,
                          size: 12,
                          color: AppColors.starAccent,
                        ),
                      ),
                    Flexible(
                      child: Text(
                        node.moveSan,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontFamily: 'SourceCodePro',
                          fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 52,
                child: evalCp != null
                    ? _EvalBadge(evalCp: evalCp)
                    : const Text(
                        '—',
                        style: TextStyle(
                          color: AppColors.onSurfaceMuted,
                          fontSize: 12,
                        ),
                      ),
              ),
              SizedBox(
                width: 40,
                child: _MetricText(
                  value: positionEase?.toStringAsFixed(2),
                  color: null,
                  align: TextAlign.right,
                ),
              ),
              SizedBox(
                width: 40,
                child: _MetricText(
                  value: node.myEase != null
                      ? '${(node.myEase! * 100).toStringAsFixed(0)}%'
                      : null,
                  color: null,
                  align: TextAlign.right,
                  tooltip: 'How natural this move is for a human to find',
                ),
              ),
              Expanded(
                child: _MetricText(
                  value: deepEase?.toStringAsFixed(2),
                  color: null,
                  align: TextAlign.right,
                  tooltip: isOurTurn
                      ? 'Minimum opponent ease deeper in this line\n(lower = harder for them)'
                      : 'Minimum opponent ease deeper in this reply',
                ),
              ),
              SizedBox(width: 48, child: _TrapCountBadge(count: trapCount)),
              SizedBox(
                width: 40,
                child: Text(
                  '${(node.moveProbability * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.onSurfaceMuted,
                    fontFamily: 'SourceCodePro',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EvalBadge extends StatelessWidget {
  final int evalCp;

  const _EvalBadge({required this.evalCp});

  @override
  Widget build(BuildContext context) {
    return Text(
      _formatEval(evalCp),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        fontFamily: 'SourceCodePro',
      ),
    );
  }
}

class _MetricText extends StatelessWidget {
  final String? value;
  final Color? color;
  final TextAlign align;
  final String? tooltip;

  const _MetricText({
    required this.value,
    required this.color,
    required this.align,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final text = Text(
      value ?? '—',
      textAlign: align,
      style: TextStyle(
        fontSize: 12,
        fontFamily: 'SourceCodePro',
        color: color ?? AppColors.onSurfaceSoft,
        fontWeight: value != null ? FontWeight.w600 : FontWeight.normal,
      ),
    );

    if (tooltip == null) return text;
    return Tooltip(message: tooltip!, child: text);
  }
}

class _TrapCountBadge extends StatelessWidget {
  final int count;

  const _TrapCountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return const Text(
        '—',
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
      );
    }

    return Tooltip(
      message: '$count trappy position${count == 1 ? '' : 's'} in this line',
      child: Text(
        '$count',
        textAlign: TextAlign.right,
        style: const TextStyle(
          fontSize: 12,
          color: AppColors.onSurfaceSoft,
          fontWeight: FontWeight.w600,
          fontFamily: 'SourceCodePro',
        ),
      ),
    );
  }
}

class _LeafPlaceholder extends StatelessWidget {
  final EvalTreeNodeSnapshot currentNode;

  const _LeafPlaceholder({required this.currentNode});

  @override
  Widget build(BuildContext context) {
    final message = switch (currentNode.pruneKind) {
      EvalTreePruneKind.evalTooHigh =>
        'Winning — no further preparation needed.',
      EvalTreePruneKind.evalTooLow => 'Too bad — pruned from the repertoire.',
      EvalTreePruneKind.none => 'End of explored line.',
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.flag_outlined,
              size: 36,
              color: AppColors.onSurfaceDim,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.emptyStateBody,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Label value" as plain text — the label is muted, the value is ink.
class _StatChip extends StatelessWidget {
  final String label;
  final String value;

  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

String _formatMovePath(EvalTreeSnapshot snapshot, int nodeId) {
  final prefix = snapshot.startMovesSan;
  final path = snapshot.movePathSan(nodeId);
  final allMoves = [...prefix, ...path];

  if (allMoves.isEmpty) return 'Starting position';

  return buildNumberedMovetext(
    allMoves,
    whiteToMoveFirst: snapshot.root.sideToMoveIsWhite,
  );
}

String _formatEval(int cpForUs) => formatPackedEval(cpForUs, decimals: 2);
