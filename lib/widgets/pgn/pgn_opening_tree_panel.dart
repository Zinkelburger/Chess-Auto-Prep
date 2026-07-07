/// Opening-tree side panel for the PGN Viewer.
///
/// Extracted from `pgn_viewer_screen.dart`. A section widget that
/// renders the opening-tree header, build progress, the [OpeningTreeWidget],
/// and the "games at this position" list. It reads all state and issues all
/// actions through the shared [PgnViewerController] (the screen's view-model),
/// so behavior is identical to the inlined version.
library;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
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
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey[700]!),
            ),
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
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.grey[200],
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
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[400],
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
                    style: TextStyle(color: Colors.grey[300], fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  if (controller.treeBuildTotal > 0)
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value: controller.treeBuildProcessed /
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
                style: TextStyle(color: Colors.grey[500]),
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
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey[700]!)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              '${matchingIndices.length} game${matchingIndices.length == 1 ? '' : 's'} at this position',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[400],
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: matchingIndices.length,
              itemBuilder: (context, idx) {
                final gi = matchingIndices[idx];
                final game = controller.filteredGames[gi];
                return InkWell(
                  onTap: () => controller.loadGameFromTree(gi),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    child: Row(
                      children: [
                        Icon(Icons.play_arrow,
                            size: 14, color: Colors.blue[300]),
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
                          const Icon(Icons.star, size: 12, color: Colors.amber),
                          Text('${game.studyRating}',
                              style: const TextStyle(fontSize: 10)),
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
