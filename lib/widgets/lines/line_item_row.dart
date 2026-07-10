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
import 'line_table_layout.dart';

/// A single repertoire line row: full mainline on the left, one stat cell
/// per table column on the right (aligned with [LineTableLayout]).
class LineItemRow extends StatelessWidget {
  static const int linesTabIndex = 2;
  static const int maxUnaccountedGroupsPreview = 2;
  static const int maxUnaccountedMovesPreview = 4;

  final RepertoireLine line;
  final int index;
  final LineTableLayout layout;
  final List<String> currentMoveSequence;
  final bool showCoverage;
  final LineCoverageInfo? coverageInfo;
  final LineQualityInfo? metrics;

  /// Precomputed display title (from the browser's line display index);
  /// falls back to extracting from the PGN when absent.
  final String? displayTitle;

  final void Function(RepertoireLine line)? onLineSelected;
  final void Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final void Function(RepertoireLine line)? onLineDeleted;
  final void Function(List<String> moveSequence)? onNavigateToPosition;
  final NavigationStack? navigationStack;
  final BoardPreviewController? boardPreview;

  const LineItemRow({
    super.key,
    required this.line,
    required this.index,
    required this.layout,
    this.currentMoveSequence = const [],
    this.showCoverage = false,
    this.coverageInfo,
    this.metrics,
    this.displayTitle,
    this.onLineSelected,
    this.onLineRenamed,
    this.onLineDeleted,
    this.onNavigateToPosition,
    this.navigationStack,
    this.boardPreview,
  });

  void _confirmDelete(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Line'),
        content: Text('Delete "${line.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red[300]),
            child: const Text('Delete'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) onLineDeleted?.call(line);
    });
  }

  static void showRenameDialog(
    BuildContext context, {
    required RepertoireLine line,
    required void Function(RepertoireLine line, String newTitle) onRenamed,
  }) {
    final eventTitle = pgn_utils.extractEventTitle(line.fullPgn);
    final currentTitle = !isPlaceholderLineTitle(eventTitle) ? eventTitle : '';
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
    final String resolvedTitle;
    if (displayTitle != null) {
      resolvedTitle = displayTitle!;
    } else {
      final eventTitle = pgn_utils.extractEventTitle(line.fullPgn);
      resolvedTitle =
          !isPlaceholderLineTitle(eventTitle) ? eventTitle : line.name;
    }

    final matchDepth =
        pgn_utils.getPositionMatchDepth(line, currentMoveSequence);
    final isExactMatch = matchDepth == currentMoveSequence.length &&
        currentMoveSequence.isNotEmpty;

    return InkWell(
      onTap: () => onLineSelected?.call(line),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildLineCell(context, resolvedTitle)),
            if (layout.showMovesColumn)
              _StatCell(
                width: LineTableLayout.movesWidth,
                child: Text(
                  '${line.moves.length}',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.grey[400],
                  ),
                ),
              ),
            _StatCell(
              width: LineTableLayout.easeWidth,
              child: _ScoreText(value: metrics?.playability),
            ),
            _StatCell(
              width: LineTableLayout.coherenceWidth,
              child: _ScoreText(
                value: metrics?.coherence,
                dangerBelow: lowCoherenceThreshold,
              ),
            ),
            if (layout.showTrapsColumn)
              _StatCell(
                width: LineTableLayout.trapsWidth,
                child: _TrapsCellText(metrics: metrics),
              ),
            if (layout.showCoverageColumn)
              _StatCell(
                width: LineTableLayout.coverageWidth,
                child: _CoverageStatus(
                  info: showCoverage ? coverageInfo : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLineCell(BuildContext context, String displayTitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
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
            if (line.importance != null && line.importance! > 0) ...[
              const SizedBox(width: 6),
              _ImportanceBadge(importance: line.importance!),
            ],
            // Narrow panes drop the traps/coverage columns; keep those
            // stats visible as inline badges instead.
            if (!layout.showTrapsColumn &&
                metrics != null &&
                metrics!.trapCount > 0) ...[
              const SizedBox(width: 6),
              _TrapBadge(metrics: metrics!),
            ],
            if (!layout.showCoverageColumn && showCoverage) ...[
              const SizedBox(width: 6),
              _CoverageStatus(info: coverageInfo),
            ],
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
            if (onLineDeleted != null)
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 14, color: Colors.grey[600]),
                  padding: EdgeInsets.zero,
                  tooltip: 'Delete line',
                  onPressed: () => _confirmDelete(context),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        // The full mainline: lines often share long prefixes, so truncating
        // makes them indistinguishable. Wraps to as many rows as needed.
        HoverableMoveChips(
          moves: line.moves,
          maxMoves: line.moves.length,
          fontSize: 11,
          boardPreview: boardPreview,
          ownerTag: this,
        ),
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
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  final double width;
  final Widget child;

  const _StatCell({required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        // Nudge down so cell values align with the title baseline.
        padding: const EdgeInsets.only(top: 1),
        child: Center(child: child),
      ),
    );
  }
}

/// A 0–1 score colored good/medium/bad; "—" when not computed.
class _ScoreText extends StatelessWidget {
  static const double goodAbove = 0.6;

  final double? value;
  final double dangerBelow;

  const _ScoreText({
    required this.value,
    this.dangerBelow = 0.3,
  });

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v == null) {
      return Text('—',
          style: TextStyle(fontSize: 11, color: Colors.grey[600]));
    }
    final color = v >= goodAbove
        ? AppColors.success
        : (v < dangerBelow ? AppColors.danger : AppColors.warning);
    return Text(
      v.toStringAsFixed(2),
      style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: color),
    );
  }
}

class _TrapsCellText extends StatelessWidget {
  final LineQualityInfo? metrics;

  const _TrapsCellText({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final count = metrics?.trapCount ?? 0;
    if (count == 0) {
      return Text('—',
          style: TextStyle(fontSize: 11, color: Colors.grey[600]));
    }
    final evalDiff = metrics?.bestTrapEvalDiff;
    final text = Text(
      '$count',
      style: const TextStyle(
        fontSize: 11,
        fontFamily: 'monospace',
        color: AppColors.warning,
      ),
    );
    if (evalDiff == null) return text;
    return Tooltip(
      message: 'Best trap wins +${evalDiff}cp',
      child: text,
    );
  }
}

class _TrapBadge extends StatelessWidget {
  final LineQualityInfo metrics;

  const _TrapBadge({required this.metrics});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${metrics.trapCount} trap${metrics.trapCount == 1 ? '' : 's'}',
        style: const TextStyle(fontSize: 11, color: AppColors.warning),
      ),
    );
  }
}

class _ImportanceBadge extends StatelessWidget {
  final double importance;

  const _ImportanceBadge({required this.importance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.blueGrey.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Text(
        '${(importance * 100).toStringAsFixed(1)}%',
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Colors.blueGrey,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// Coverage status word for the coverage column (or inline in narrow panes).
class _CoverageStatus extends StatelessWidget {
  final LineCoverageInfo? info;

  const _CoverageStatus({this.info});

  @override
  Widget build(BuildContext context) {
    final leaf = info?.leaf;
    if (leaf == null) {
      return Text('—',
          style: TextStyle(fontSize: 11, color: Colors.grey[600]));
    }

    late final Color color;
    late final String text;
    String? tooltip;

    switch (leaf.category) {
      case LeafCategory.covered:
        color = const Color(0xFF4CAF50);
        text = 'Covered';
      case LeafCategory.tooShallow:
        color = const Color(0xFFFFA726);
        text = 'Shallow';
      case LeafCategory.tooDeep:
        color = const Color(0xFF42A5F5);
        text = 'Deep';
        tooltip = '${leaf.excessPly} ply past target depth';
    }

    final label = Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    );
    if (tooltip == null) return label;
    return Tooltip(message: tooltip, child: label);
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
        final moves = [...group.value]..sort((a, b) {
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
                            onNavigateToPosition!([...m.parentMoves, m.move]);
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
                          color: const Color(0xFFEF5350).withValues(alpha: 0.7),
                        ),
                      );
                    }),
                    if (moves.length > LineItemRow.maxUnaccountedMovesPreview)
                      Text(
                        '+${moves.length - LineItemRow.maxUnaccountedMovesPreview} more',
                        style: TextStyle(
                          fontSize: 10,
                          color: const Color(0xFFEF5350).withValues(alpha: 0.5),
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
        m.bottleneckQuality! >= hardMoveEaseThreshold) {
      return const SizedBox.shrink();
    }

    final ply = m.bottleneckPly ?? 0;
    final moveNum = (ply ~/ 2) + 1;
    final moveSan = ply < line.moves.length ? line.moves[ply] : 'move $moveNum';
    final isOurMove = m.bottleneckIsOurMove;
    final tooltip = isOurMove
        ? 'Position where your move is hard to find (low naturalness)'
        : 'Position where the opponent easily finds strong replies';
    final label = isOurMove
        ? 'hard move: $moveNum. $moveSan (ease ${m.bottleneckQuality!.toStringAsFixed(2)})'
        : 'easy for opponent at $moveNum. $moveSan (quality ${m.bottleneckQuality!.toStringAsFixed(2)})';

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Tooltip(
            message: tooltip,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 12, color: AppColors.danger),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(fontSize: 10, color: AppColors.danger),
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
