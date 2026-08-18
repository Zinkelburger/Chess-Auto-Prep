/// Opening-tree side panel for the PGN Viewer.
///
/// Extracted from `pgn_viewer_screen.dart`. A section widget that
/// renders the opening-tree header, build progress, the [OpeningTreeWidget],
/// and the "games at this position" list. It reads all state and issues all
/// actions through the shared [PgnViewerController] (the screen's view-model),
/// so behavior is identical to the inlined version.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';
import '../game_nav_item.dart';
import '../game_search_dialog.dart';
import '../layout/edit_context_split_handle.dart';
import '../opening_tree_widget.dart';
import 'pgn_tree_games_list.dart';

class PgnOpeningTreePanel extends StatefulWidget {
  final PgnViewerController controller;

  const PgnOpeningTreePanel({super.key, required this.controller});

  static const minTreeHeight = 80.0;
  static const minGamesHeight = 180.0;

  @override
  State<PgnOpeningTreePanel> createState() => _PgnOpeningTreePanelState();
}

class _PgnOpeningTreePanelState extends State<PgnOpeningTreePanel> {
  /// Fraction of the pane given to the tree above the games list.
  double _splitRatio = 0.55;

  PgnViewerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.outline)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: controller.toggleOpeningTree,
                tooltip: actionTooltip(
                  'Back to Game/Analysis',
                  shortcut: AppShortcut.toggleOpeningTree,
                ),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Text(
                'Opening Tree',
                style: AppTextStyles.subtitle.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (controller.buildingTree)
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          controller.treeBuildTotal > 0
                              ? 'Building ${controller.treeBuildProcessed} / ${controller.treeBuildTotal}'
                              : 'Building tree...',
                          style: AppTextStyles.caption.copyWith(
                            fontSize: 11,
                            color: AppColors.onSurfaceSoft,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (controller.buildingTree)
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
                    controller.treeBuildTotal > 0
                        ? 'Building tree... ${controller.treeBuildProcessed} / ${controller.treeBuildTotal} games'
                        : 'Building tree...',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.onSurfaceSoft,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (controller.treeBuildTotal > 0)
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value:
                            controller.treeBuildProcessed /
                            controller.treeBuildTotal,
                      ),
                    ),
                ],
              ),
            ),
          )
        else if (controller.openingTree == null)
          Expanded(
            child: Center(
              child: Text(
                'No tree available.\nLoad games to build.',
                textAlign: TextAlign.center,
                style: AppTextStyles.muted.copyWith(fontSize: 14),
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
      tree: controller.openingTree!,
      onMoveSelected: controller.onTreeMoveSelected,
      onGoBack: controller.onTreeGoBack,
      onGoForward: controller.onTreeGoForward,
      currentMoveSequence: controller.treeCurrentMoveSequence,
      wdlPerspective: controller.wdlPerspective,
    );
    final matching = controller.gamesAtTreePosition();
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
                  if (available <= 0) return;
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
                games: [for (final i in matching) controller.filteredGames[i]],
                currentFen: controller.openingTree!.currentNode.fen,
                currentIndex: matching.indexOf(controller.currentGameIndex),
                onGameSelected: (i) => controller.loadGameFromTree(matching[i]),
                onSearch: () => openTreePositionGameSearch(
                  context: context,
                  controller: controller,
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
  required PgnViewerController controller,
}) async {
  final matching = controller.gamesAtTreePosition();
  if (matching.isEmpty) return false;
  final games = [
    for (final i in matching)
      GameNavItem.fromEntry(controller.filteredGames[i]),
  ];
  final current = matching.indexOf(controller.currentGameIndex);
  final selected = await showGameSearchDialog(
    context: context,
    games: games,
    currentIndex: current < 0 ? 0 : current,
  );
  if (selected == null) return false;
  controller.loadGameFromTree(matching[selected]);
  return true;
}
