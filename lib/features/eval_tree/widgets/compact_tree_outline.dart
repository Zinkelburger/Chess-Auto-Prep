import 'package:flutter/material.dart';

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

const _rowHeight = 24.0;
const _indentWidth = 16.0;

class _FlatRow {
  final BuildTreeNode node;
  final int depth;
  final bool hasChildren;
  final bool isExpanded;

  const _FlatRow({
    required this.node,
    required this.depth,
    required this.hasChildren,
    required this.isExpanded,
  });
}

/// Scrollable indented outline of a generated [BuildTree] with expectimax data.
class CompactTreeOutline extends StatefulWidget {
  final BuildTree tree;
  final bool playAsWhite;
  final String? currentFen;
  final ValueChanged<BuildTreeNode>? onNodeTapped;

  const CompactTreeOutline({
    super.key,
    required this.tree,
    required this.playAsWhite,
    this.currentFen,
    this.onNodeTapped,
  });

  @override
  State<CompactTreeOutline> createState() => _CompactTreeOutlineState();
}

class _CompactTreeOutlineState extends State<CompactTreeOutline> {
  final Set<int> _expandedNodeIds = {};
  final ScrollController _scrollController = ScrollController();
  List<_FlatRow> _rows = const [];
  int? _highlightIndex;

  int get _startPlyOffset => _parseStartPlyOffset(widget.tree.startMoves);

  @override
  void initState() {
    super.initState();
    _expandMainline(widget.tree.root);
    _rebuildRows();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
  }

  @override
  void didUpdateWidget(covariant CompactTreeOutline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final treeChanged = oldWidget.tree != widget.tree;
    if (treeChanged) {
      _expandedNodeIds.clear();
      _expandMainline(widget.tree.root);
    }
    if (treeChanged ||
        oldWidget.currentFen != widget.currentFen ||
        oldWidget.playAsWhite != widget.playAsWhite) {
      _rebuildRows();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int _parseStartPlyOffset(String startMoves) {
    final trimmed = startMoves.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).length;
  }

  void _expandMainline(BuildTreeNode node) {
    _expandedNodeIds.add(node.nodeId);
    BuildTreeNode? next;
    for (final child in node.children) {
      if (child.isRepertoireMove) {
        next = child;
        break;
      }
    }
    next ??= node.children.isNotEmpty ? node.children.first : null;
    if (next != null) {
      _expandMainline(next);
    }
  }

  void _rebuildRows() {
    final rows = <_FlatRow>[];
    _buildRowsRecursive(widget.tree.root, 0, rows);
    int? highlightIndex;
    final current = widget.currentFen;
    if (current != null) {
      final normalized = normalizeFen(current);
      for (var i = 0; i < rows.length; i++) {
        if (normalizeFen(rows[i].node.fen) == normalized) {
          highlightIndex = i;
          break;
        }
      }
    }
    _rows = rows;
    _highlightIndex = highlightIndex;
  }

  void _buildRowsRecursive(
    BuildTreeNode node,
    int depth,
    List<_FlatRow> rows,
  ) {
    final hasChildren = node.children.isNotEmpty;
    final isExpanded = _expandedNodeIds.contains(node.nodeId);
    rows.add(
      _FlatRow(
        node: node,
        depth: depth,
        hasChildren: hasChildren,
        isExpanded: isExpanded,
      ),
    );
    if (!isExpanded) return;
    for (final child in node.children) {
      _buildRowsRecursive(child, depth + 1, rows);
    }
  }

  void _scrollToHighlight() {
    final index = _highlightIndex;
    if (index == null || !_scrollController.hasClients) return;

    final viewport = _scrollController.position.viewportDimension;
    final target = (index * _rowHeight) - (viewport / 2) + (_rowHeight / 2);
    final maxScroll = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      target.clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _toggleExpanded(BuildTreeNode node) {
    setState(() {
      if (_expandedNodeIds.contains(node.nodeId)) {
        _expandedNodeIds.remove(node.nodeId);
      } else {
        _expandedNodeIds.add(node.nodeId);
      }
      _rebuildRows();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_rows.isEmpty) {
      return const Center(
        child: Text(
          'Empty tree',
          style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemExtent: _rowHeight,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _rows.length,
      itemBuilder: (context, index) {
        final row = _rows[index];
        final isHighlighted = index == _highlightIndex;
        return _CompactTreeRow(
          row: row,
          playAsWhite: widget.playAsWhite,
          startPlyOffset: _startPlyOffset,
          isHighlighted: isHighlighted,
          onChevronTap: row.hasChildren
              ? () => _toggleExpanded(row.node)
              : null,
          onRowTap: () => widget.onNodeTapped?.call(row.node),
        );
      },
    );
  }
}

class _CompactTreeRow extends StatelessWidget {
  final _FlatRow row;
  final bool playAsWhite;
  final int startPlyOffset;
  final bool isHighlighted;
  final VoidCallback? onChevronTap;
  final VoidCallback? onRowTap;

  const _CompactTreeRow({
    required this.row,
    required this.playAsWhite,
    required this.startPlyOffset,
    required this.isHighlighted,
    required this.onChevronTap,
    required this.onRowTap,
  });

  @override
  Widget build(BuildContext context) {
    final node = row.node;
    final evalCp = node.evalForUs(playAsWhite);
    final showEval = node.hasEngineEval;
    final showExpectimax = node.hasExpectimax;
    final showProb = node.moveProbability < 1.0;

    return Material(
      color: isHighlighted ? AppColors.surfaceContainer : Colors.transparent,
      child: InkWell(
        onTap: onRowTap,
        child: SizedBox(
          height: _rowHeight,
          child: Row(
            children: [
              SizedBox(width: row.depth * _indentWidth),
              SizedBox(
                width: 18,
                height: 18,
                child: row.hasChildren
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onChevronTap,
                        child: Icon(
                          row.isExpanded
                              ? Icons.expand_more
                              : Icons.chevron_right,
                          size: 14,
                          color: AppColors.onSurfaceMuted,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              SizedBox(
                width: 14,
                child: node.isRepertoireMove
                    ? Icon(
                        Icons.star,
                        size: 12,
                        color: Colors.amber[400],
                      )
                    : null,
              ),
              Expanded(
                child: Text(
                  _formatMoveLabel(node),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              if (showEval) ...[
                const SizedBox(width: 6),
                Text(
                  _formatEval(evalCp),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppColors.cpEval(evalCp),
                  ),
                ),
              ],
              if (showExpectimax) ...[
                const SizedBox(width: 6),
                Text(
                  'V:${(node.expectimaxValue * 100).round()}%',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: AppColors.winProbability(node.expectimaxValue),
                  ),
                ),
              ],
              if (showProb) ...[
                const SizedBox(width: 6),
                Text(
                  '${(node.moveProbability * 100).round()}%',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: AppColors.onSurfaceDim,
                  ),
                ),
              ],
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }

  String _formatMoveLabel(BuildTreeNode node) {
    if (node.moveSan.isEmpty) return 'Start';
    final movedByWhite = !node.isWhiteToMove;
    final absolutePly = node.ply + startPlyOffset;
    final moveNum = (absolutePly + 1) ~/ 2;
    if (movedByWhite) {
      return '$moveNum. ${node.moveSan}';
    }
    return '$moveNum...${node.moveSan}';
  }

  String _formatEval(int cpForUs) {
    if (isMateEval(cpForUs)) {
      return cpForUs > 0 ? '+M' : '-M';
    }
    final pawns = cpForUs / 100.0;
    return '${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(1)}';
  }
}
