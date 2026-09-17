/// Opening-tree side panel for the PGN Viewer.
///
/// Renders a read-only opening graph and a captured list of matching games.
/// The owning workspace supplies navigation and mutation actions.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chess_core/moves/opening_graph.dart';
import '../../models/opening_tree.dart' show WdlPerspective;
import '../../models/pgn_game_entry.dart';
import '../../design_system/theme/app_typography.dart';
import '../game_nav_item.dart';
import '../game_search_dialog.dart';
import '../layout/edit_context_split_handle.dart';
import '../opening_tree_widget.dart';
import 'pgn_tree_games_list.dart';

class PgnOpeningTreePanel extends StatefulWidget {
  PgnOpeningTreePanel({
    super.key,
    required this.tree,
    required this.gameCount,
    required this.includeVariations,
    required this.building,
    required this.processed,
    required this.total,
    required List<String> currentMoveSequence,
    required this.wdlPerspective,
    required List<PgnGameEntry> matchingGames,
    required this.currentMatchingIndex,
    required this.onIncludeVariationsChanged,
    required this.onMoveSelected,
    required this.onGoBack,
    required this.onGoForward,
    required this.onGameSelected,
  }) : currentMoveSequence = List.unmodifiable(currentMoveSequence),
       matchingGames = List.unmodifiable(matchingGames);

  final OpeningGraph? tree;
  final int gameCount;
  final bool includeVariations;
  final bool building;
  final int processed;
  final int total;
  final List<String> currentMoveSequence;
  final WdlPerspective wdlPerspective;
  final List<PgnGameEntry> matchingGames;
  final int currentMatchingIndex;
  final ValueChanged<bool> onIncludeVariationsChanged;
  final ValueChanged<String> onMoveSelected;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;
  final ValueChanged<PgnGameEntry> onGameSelected;

  static const minTreeHeight = 80.0;
  static const minGamesHeight = 180.0;

  @override
  State<PgnOpeningTreePanel> createState() => _PgnOpeningTreePanelState();
}

class _PgnOpeningTreePanelState extends State<PgnOpeningTreePanel> {
  /// Fraction of the pane given to the tree above the games list.
  double _splitRatio = 0.55;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                '${widget.gameCount} games',
                style: AppTypography.bodyStrong(context),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: widget.includeVariations,
                    onChanged: (value) {
                      if (!mounted || value == null) return;
                      widget.onIncludeVariationsChanged(value);
                    },
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  Flexible(
                    child: GestureDetector(
                      onTap: () {
                        if (!mounted) return;
                        widget.onIncludeVariationsChanged(
                          !widget.includeVariations,
                        );
                      },
                      child: Text(
                        'Include variations',
                        style: AppTypography.secondary(context),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (widget.building)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.total > 0
                        ? 'Building tree... ${widget.processed} / ${widget.total} games'
                        : 'Building tree...',
                    style: AppTypography.caption(context).copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (widget.total > 0)
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value: widget.processed / widget.total,
                      ),
                    ),
                ],
              ),
            ),
          )
        else if (widget.tree == null)
          Expanded(
            child: Center(
              child: Text(
                'No tree available.\nLoad games to build.',
                textAlign: TextAlign.center,
                style: AppTypography.body(context),
              ),
            ),
          )
        else
          Expanded(child: _buildTreeAndGames()),
      ],
    );
  }

  Widget _buildTreeAndGames() {
    final tree = OpeningTreeWidget(
      tree: widget.tree!,
      onMoveSelected: (move) {
        if (mounted) widget.onMoveSelected(move);
      },
      onGoBack: () {
        if (mounted) widget.onGoBack();
      },
      onGoForward: () {
        if (mounted) widget.onGoForward();
      },
      currentMoveSequence: widget.currentMoveSequence,
      wdlPerspective: widget.wdlPerspective,
    );
    final matching = widget.matchingGames;
    if (matching.isEmpty) return tree;

    return LayoutBuilder(
      builder: (context, constraints) {
        const handleHeight = 8.0;
        final available = math.max(0.0, constraints.maxHeight - handleHeight);
        return Column(
          children: [
            SizedBox(height: _treeHeightFor(available), child: tree),
            Tooltip(
              message: 'Drag to show more games',
              waitDuration: const Duration(milliseconds: 500),
              child: EditContextSplitHandle(
                axis: EditContextSplitAxis.vertical,
                onDrag: (dy) {
                  if (!mounted || available <= 0) return;
                  setState(() {
                    _splitRatio = (_splitRatio + dy / available).clamp(
                      0.2,
                      0.85,
                    );
                  });
                },
              ),
            ),
            Expanded(
              child: PgnTreeGamesList(
                games: matching,
                currentFen: widget.tree!.currentFen,
                currentIndex: widget.currentMatchingIndex,
                onGameSelected: (i) {
                  if (mounted) widget.onGameSelected(matching[i]);
                },
                onSearch: () => openTreePositionGameSearch(
                  context: context,
                  games: matching,
                  currentIndex: widget.currentMatchingIndex,
                  onSelected: widget.onGameSelected,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _treeHeightFor(double available) {
    const minTree = PgnOpeningTreePanel.minTreeHeight;
    const minGames = PgnOpeningTreePanel.minGamesHeight;
    if (available <= minTree + minGames) {
      return available * _splitRatio;
    }
    return (available * _splitRatio)
        .clamp(minTree, available - minGames)
        .toDouble();
  }
}

/// Opens the nav-bar search dialog scoped to games that reach the tree's
/// current position. Returns true if a game was loaded.
Future<bool> openTreePositionGameSearch({
  required BuildContext context,
  required List<PgnGameEntry> games,
  required int currentIndex,
  required ValueChanged<PgnGameEntry> onSelected,
}) async {
  final captured = List<PgnGameEntry>.of(games);
  if (!context.mounted || captured.isEmpty) return false;
  final selected = await showGameSearchDialog(
    context: context,
    games: [for (final game in captured) GameNavItem.fromEntry(game)],
    currentIndex: currentIndex < 0 ? 0 : currentIndex,
  );
  if (!context.mounted || selected == null) return false;
  onSelected(captured[selected]);
  return true;
}
