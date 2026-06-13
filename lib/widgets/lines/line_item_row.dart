import 'package:flutter/material.dart';

import '../../core/board_preview_controller.dart';
import '../../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../../theme/app_colors.dart';
import '../../utils/coverage_helpers.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import '../../utils/lines_filter_helpers.dart';
import '../../utils/pgn_utils.dart' as pgn_utils;
import '../hoverable_move_chips.dart';

/// A single repertoire line row with stats, coverage, and move preview.
class LineItemRow extends StatelessWidget {
  static const int linesTabIndex = 2;
  static const int maxUnaccountedGroupsPreview = 2;
  static const int maxUnaccountedMovesPreview = 4;
  static const double bottleneckQualityThreshold = 0.3;

  final RepertoireLine line;
  final int index;
  final bool indented;
  final bool isExpanded;
  final List<String> currentMoveSequence;
  final bool showCoverage;
  final LineCoverageInfo? coverageInfo;
  final LineQualityInfo? metrics;
  final void Function(RepertoireLine line)? onLineSelected;
  final void Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final void Function(List<String> moveSequence)? onNavigateToPosition;
  final NavigationStack? navigationStack;
  final BoardPreviewController? boardPreview;

  const LineItemRow({
    super.key,
    required this.line,
    required this.index,
    this.indented = false,
    this.isExpanded = false,
    this.currentMoveSequence = const [],
    this.showCoverage = false,
    this.coverageInfo,
    this.metrics,
    this.onLineSelected,
    this.onLineRenamed,
    this.onNavigateToPosition,
    this.navigationStack,
    this.boardPreview,
  });

  static void showRenameDialog(
    BuildContext context, {
    required RepertoireLine line,
    required void Function(RepertoireLine line, String newTitle) onRenamed,
  }) {
    final eventTitle = pgn_utils.extractEventTitle(line.fullPgn);
    final currentTitle =
        !isPlaceholderLineTitle(eventTitle) ? eventTitle : '';
    final controller = TextEditingController(text: currentTitle);

    final renameDialog = showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Line'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g., KID - Fianchetto Variation',
            labelText: 'Line Title',
          ),
          onSubmitted: (value) {
            final title = value.trim();
            if (title.isNotEmpty) {
              onRenamed(line, title);
            }
            Navigator.of(dialogContext).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final title = controller.text.trim();
              if (title.isNotEmpty) {
                onRenamed(line, title);
              }
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    renameDialog.whenComplete(controller.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final eventTitle = pgn_utils.extractEventTitle(line.fullPgn);
    final displayTitle =
        !isPlaceholderLineTitle(eventTitle) ? eventTitle : line.name;

    final matchDepth =
        pgn_utils.getPositionMatchDepth(line, currentMoveSequence);
    final isExactMatch = matchDepth == currentMoveSequence.length &&
        currentMoveSequence.isNotEmpty;

    final coverageBadge =
        showCoverage ? _CoverageBadge(info: coverageInfo) : null;

    return InkWell(
      onTap: () => onLineSelected?.call(line),
      child: Container(
        padding: EdgeInsets.only(
          left: indented ? 32 : 12,
          right: 12,
          top: 10,
          bottom: 10,
        ),
        decoration: BoxDecoration(
          color: isExactMatch
              ? AppColors.info.withValues(alpha: 0.2)
              : (index % 2 == 0 ? Colors.grey[900] : Colors.grey[850]),
          border: Border(
            left: isExactMatch
                ? const BorderSide(color: AppColors.info, width: 3)
                : BorderSide.none,
            bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    displayTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onLineRenamed != null)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      icon: Icon(Icons.edit, size: 14, color: Colors.grey[500]),
                      padding: EdgeInsets.zero,
                      tooltip: 'Rename line',
                      onPressed: () => showRenameDialog(
                        context,
                        line: line,
                        onRenamed: onLineRenamed!,
                      ),
                    ),
                  ),
                if (coverageBadge != null) ...[
                  const SizedBox(width: 4),
                  coverageBadge,
                ],
                if (metrics != null && metrics!.trapCount > 0) ...[
                  const SizedBox(width: 4),
                  _TrapLineBadges(metrics: metrics!),
                ],
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: line.color == 'white'
                        ? Colors.grey[200]
                        : Colors.grey[800],
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[600]!, width: 0.5),
                  ),
                  child: Text(
                    line.color == 'white' ? 'W' : 'B',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: line.color == 'white'
                          ? Colors.grey[900]
                          : Colors.grey[200],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${line.moves.length} moves',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                  ),
                ),
                if (line.importance != null && line.importance! > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.blueGrey.withValues(alpha: 0.4),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      '${(line.importance! * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            _MovesPreview(
              line: line,
              matchDepth: matchDepth,
              isExpanded: isExpanded,
              boardPreview: boardPreview,
            ),
            _LineMetricsRow(metrics: metrics),
            _HardMoveWarning(
              line: line,
              metrics: metrics,
              onNavigateToPosition: onNavigateToPosition,
              navigationStack: navigationStack,
            ),
            if (showCoverage)
              _UnaccountedAnnotation(
                info: coverageInfo,
                onNavigateToPosition: onNavigateToPosition,
              ),
            if (line.comments.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${line.comments.length} comment${line.comments.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.evalPositive,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrapLineBadges extends StatelessWidget {
  final LineQualityInfo metrics;

  const _TrapLineBadges({required this.metrics});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${metrics.trapCount} trap${metrics.trapCount == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 11, color: AppColors.warning),
          ),
        ),
        if (metrics.bestTrapEvalDiff != null) ...[
          const SizedBox(width: 4),
          Text(
            '+${metrics.bestTrapEvalDiff}cp',
            style:
                const TextStyle(fontSize: 11, color: AppColors.evalPositive),
          ),
        ],
      ],
    );
  }
}

class _CoverageBadge extends StatelessWidget {
  final LineCoverageInfo? info;

  const _CoverageBadge({this.info});

  @override
  Widget build(BuildContext context) {
    if (info?.leaf == null) return const SizedBox.shrink();
    final leaf = info!.leaf!;

    late final Color color;
    late final String text;

    switch (leaf.category) {
      case LeafCategory.covered:
        color = const Color(0xFF4CAF50);
        text = 'Covered';
      case LeafCategory.tooShallow:
        color = const Color(0xFFFFA726);
        text = 'Too shallow';
      case LeafCategory.tooDeep:
        color = const Color(0xFF42A5F5);
        text = '${leaf.excessPly} ply deep';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _UnaccountedAnnotation extends StatelessWidget {
  final LineCoverageInfo? info;
  final void Function(List<String> moveSequence)? onNavigateToPosition;

  const _UnaccountedAnnotation({this.info, this.onNavigateToPosition});

  @override
  Widget build(BuildContext context) {
    if (info == null || info!.unaccountedMoves.isEmpty) {
      return const SizedBox.shrink();
    }

    final groups = info!.groupedUnaccounted.entries.toList();
    if (groups.isEmpty) return const SizedBox.shrink();

    final displayGroups =
        groups.take(LineItemRow.maxUnaccountedGroupsPreview).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: displayGroups.map((group) {
        final moves = [...group.value]
          ..sort((a, b) {
            if (a.gameCount != b.gameCount) {
              return b.gameCount.compareTo(a.gameCount);
            }
            return b.probability.compareTo(a.probability);
          });
        final displayMoves =
            moves.take(LineItemRow.maxUnaccountedMovesPreview).toList();

        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Unaccounted: ',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFFEF5350).withValues(alpha: 0.8),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    ...displayMoves.map((m) {
                      final label = m.gameCount > 0
                          ? '${m.move} (${formatCoveragePercent(m.probability)})'
                          : '${m.move} (${formatCoveragePercent(m.probability)}, ${m.source})';

                      if (onNavigateToPosition != null) {
                        return GestureDetector(
                          onTap: () {
                            onNavigateToPosition!(
                                [...m.parentMoves, m.move]);
                          },
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: const Color(0xFFEF5350)
                                  .withValues(alpha: 0.9),
                              decoration: TextDecoration.underline,
                              decorationColor: const Color(0xFFEF5350)
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                        );
                      }
                      return Text(
                        label,
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color:
                              const Color(0xFFEF5350).withValues(alpha: 0.7),
                        ),
                      );
                    }),
                    if (moves.length > LineItemRow.maxUnaccountedMovesPreview)
                      Text(
                        '+${moves.length - LineItemRow.maxUnaccountedMovesPreview} more',
                        style: TextStyle(
                          fontSize: 10,
                          color:
                              const Color(0xFFEF5350).withValues(alpha: 0.5),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _LineMetricsRow extends StatelessWidget {
  final LineQualityInfo? metrics;

  const _LineMetricsRow({this.metrics});

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    if (m == null) return const SizedBox.shrink();
    final hasAnyMetric =
        m.quality != null || m.trapCount > 0 || m.coherence != null;
    if (!hasAnyMetric) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 2,
        children: [
          if (m.quality != null)
            Text(
              'quality ${m.quality!.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 10, color: AppColors.lichessDb),
            ),
          if (m.trapCount > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt, size: 10, color: AppColors.warning),
                Text(
                  ' ${m.trapCount} trap${m.trapCount == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 10, color: AppColors.warning),
                ),
              ],
            ),
          if (m.coherence != null)
            Text(
              'coherence ${m.coherence!.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 10, color: AppColors.maia),
            ),
        ],
      ),
    );
  }
}

class _HardMoveWarning extends StatelessWidget {
  final RepertoireLine line;
  final LineQualityInfo? metrics;
  final void Function(List<String> moveSequence)? onNavigateToPosition;
  final NavigationStack? navigationStack;

  const _HardMoveWarning({
    required this.line,
    this.metrics,
    this.onNavigateToPosition,
    this.navigationStack,
  });

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    if (m == null ||
        m.bottleneckQuality == null ||
        m.bottleneckQuality! >= LineItemRow.bottleneckQualityThreshold) {
      return const SizedBox.shrink();
    }

    final ply = m.bottleneckPly ?? 0;
    final moveNum = (ply ~/ 2) + 1;
    final moveSan =
        ply < line.moves.length ? line.moves[ply] : 'move $moveNum';

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Tooltip(
            message: 'Position where your move is hard to find (low ease)',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 12, color: AppColors.danger),
                const SizedBox(width: 4),
                Text(
                  'hard move: $moveNum. $moveSan (ease ${m.bottleneckQuality!.toStringAsFixed(2)})',
                  style: TextStyle(fontSize: 10, color: AppColors.danger),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (onNavigateToPosition != null)
            InkWell(
              onTap: () {
                if (navigationStack != null) {
                  navigationStack!.push(const NavigationEntry(
                    tabIndex: LineItemRow.linesTabIndex,
                    fen: '',
                    label: 'Lines',
                    reason: 'hard_move',
                  ));
                }
                onNavigateToPosition!(line.moves.sublist(0, ply + 1));
              },
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.withAlpha(80)),
                ),
                child: const Text('Go', style: TextStyle(fontSize: 10)),
              ),
            ),
        ],
      ),
    );
  }
}

class _MovesPreview extends StatelessWidget {
  final RepertoireLine line;
  final int matchDepth;
  final bool isExpanded;
  final BoardPreviewController? boardPreview;

  const _MovesPreview({
    required this.line,
    required this.matchDepth,
    required this.isExpanded,
    this.boardPreview,
  });

  @override
  Widget build(BuildContext context) {
    final moves = line.moves;
    final maxPreviewMoves = isExpanded ? 12 : 8;

    return HoverableMoveChips(
      moves: moves,
      maxMoves: maxPreviewMoves,
      fontSize: 11,
      highlightDepth: matchDepth,
      highlightColor: AppColors.lichessDb,
      boardPreview: boardPreview,
      ownerTag: this,
    );
  }
}
