/// Opening-tree side panel for the PGN Viewer.
///
/// Extracted from `pgn_viewer_screen.dart`. A section widget that
/// renders the opening-tree header, build progress, the [OpeningTreeWidget],
/// and the "games at this position" list. It reads all state and issues all
/// actions through the shared [PgnViewerController] (the screen's view-model),
/// so behavior is identical to the inlined version.
library;

import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../models/pgn_filter_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../game_nav_item.dart';
import '../game_search_dialog.dart';
import '../layout/edit_context_split_handle.dart';
import '../opening_tree_widget.dart';
import 'pgn_tree_games_list.dart';

class PgnOpeningTreePanel extends StatefulWidget {
  final PgnViewerController controller;

  final VoidCallback? onFilter;
  final Future<void> Function()? onExportPosition;

  const PgnOpeningTreePanel({
    super.key,
    required this.controller,
    this.onFilter,
    this.onExportPosition,
  });

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
        if (widget.onFilter != null || widget.onExportPosition != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (controller.collectionPlayer case final player?)
                  for (final side in ['White', 'Black'])
                    FilterChip(
                      label: Text('${player.split(',').first} as $side'),
                      selected: controller.activeSliceConfig.headerFilters.any(
                        (filter) =>
                            filter.field == side &&
                            filter.value == player &&
                            filter.mode == MatchMode.exact,
                      ),
                      onSelected: controller.isLoading
                          ? null
                          : (selected) {
                              if (!mounted) return;
                              if (selected) {
                                unawaited(
                                  controller.applySlicePreset(
                                    HeaderFilterConfig(
                                      field: side,
                                      mode: MatchMode.exact,
                                      value: player,
                                    ),
                                  ),
                                );
                              } else {
                                final config = controller.activeSliceConfig;
                                unawaited(
                                  controller.recomputeAndApplyConfig(
                                    SliceConfig(
                                      positionInput: config.positionInput,
                                      headerFilters: config.headerFilters
                                          .where(
                                            (filter) =>
                                                !(filter.field == side &&
                                                    filter.value == player),
                                          )
                                          .toList(),
                                      sequencePattern: config.sequencePattern,
                                      sequenceGap: config.sequenceGap,
                                    ),
                                  ),
                                );
                              }
                            },
                    ),
                if (widget.onFilter != null)
                  TextButton.icon(
                    onPressed: widget.onFilter,
                    icon: const Icon(Icons.filter_list, size: 16),
                    label: const Text('Filter'),
                  ),
                if (widget.onExportPosition != null)
                  TextButton.icon(
                    onPressed:
                        controller.buildingTree ||
                            controller.gamesAtTreePosition().isEmpty
                        ? null
                        : () => unawaited(widget.onExportPosition!()),
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: const Text('Export games here…'),
                  ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.outline)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${controller.filteredGames.length} games',
                  style: AppTextStyles.subtitle.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: controller.treeIncludeVariations,
                    onChanged: (value) {
                      if (!mounted || value == null) return;
                      controller.setTreeIncludeVariations(value);
                    },
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  GestureDetector(
                    onTap: () {
                      if (!mounted) return;
                      controller.setTreeIncludeVariations(
                        !controller.treeIncludeVariations,
                      );
                    },
                    child: const Text(
                      'Include variations',
                      style: AppTextStyles.muted,
                    ),
                  ),
                ],
              ),
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
                            fontSize: 12,
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
