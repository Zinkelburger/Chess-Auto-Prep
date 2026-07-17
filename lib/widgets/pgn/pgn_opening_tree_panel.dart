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
import '../opening_tree_widget.dart';

class PgnOpeningTreePanel extends StatelessWidget {
  final PgnViewerController controller;

  const PgnOpeningTreePanel({super.key, required this.controller});

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
                tooltip: 'Back to Game/Analysis (T)',
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
        else ...[
          Expanded(
            child: OpeningTreeWidget(
              tree: controller.openingTree!,
              onMoveSelected: controller.onTreeMoveSelected,
              onGoBack: controller.onTreeGoBack,
              onGoForward: controller.onTreeGoForward,
              currentMoveSequence: controller.treeCurrentMoveSequence,
              wdlPerspective: controller.wdlPerspective,
            ),
          ),
          _TreeGamesList(controller: controller),
        ],
      ],
    );
  }
}

class _TreeGamesList extends StatelessWidget {
  final PgnViewerController controller;

  const _TreeGamesList({required this.controller});

  @override
  Widget build(BuildContext context) {
    final matchingIndices = controller.gamesAtTreePosition();
    if (matchingIndices.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              '${matchingIndices.length} game${matchingIndices.length == 1 ? '' : 's'} at this position',
              style: AppTextStyles.caption.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurfaceSoft,
              ),
            ),
          ),
          SizedBox(
            // Fixed row height + a capped visible-row count lets the list
            // build lazily. At the root position every filtered game matches,
            // and `shrinkWrap: true` used to build a row for each one just to
            // measure a list that only ever shows ~5 in its 180px box.
            height: math.min(matchingIndices.length, 5) * 26.0 + 4,
            child: ListView.builder(
              itemExtent: 26,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: matchingIndices.length,
              itemBuilder: (context, idx) {
                final gi = matchingIndices[idx];
                final game = controller.filteredGames[gi];
                return InkWell(
                  onTap: () => controller.loadGameFromTree(gi),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.play_arrow,
                          size: 14,
                          color: AppColors.info,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            game.label,
                            style: const TextStyle(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (game.studyRating > 0) ...[
                          const Icon(
                            Icons.star,
                            size: 12,
                            color: AppColors.starAccent,
                          ),
                          Text(
                            '${game.studyRating}',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
