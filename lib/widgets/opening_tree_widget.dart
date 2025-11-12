/// Opening tree widget - Interactive move tree explorer
/// Similar to openingtree.com's interface

import 'package:flutter/material.dart';
import '../models/opening_tree.dart';

class OpeningTreeWidget extends StatefulWidget {
  final OpeningTree tree;
  final Function(String fen)? onPositionSelected;

  const OpeningTreeWidget({
    super.key,
    required this.tree,
    this.onPositionSelected,
  });

  @override
  State<OpeningTreeWidget> createState() => _OpeningTreeWidgetState();
}

class _OpeningTreeWidgetState extends State<OpeningTreeWidget> {
  @override
  Widget build(BuildContext context) {
    final currentNode = widget.tree.currentNode;
    final movePath = currentNode.getMovePathString();
    final sortedChildren = currentNode.sortedChildren;

    return Column(
      children: [
        // Header with current position
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(
                color: Colors.grey[700]!,
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Simplified header without navigation buttons
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    movePath,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[300],
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Stats for current position
              Text(
                '${currentNode.gamesPlayed} games • '
                '${currentNode.winRatePercent.toStringAsFixed(1)}% '
                '(${currentNode.wins}-${currentNode.losses}-${currentNode.draws})',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[300],
                ),
              ),
            ],
          ),
        ),

        // Move list
        Expanded(
          child: sortedChildren.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      currentNode.parent == null
                          ? 'No games found.\nAnalyze a player to build the tree.'
                          : 'No more moves in the database.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: sortedChildren.length,
                  itemBuilder: (context, index) {
                    final child = sortedChildren[index];
                    return _buildMoveItem(child);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildMoveItem(OpeningTreeNode node) {
    final totalGames = widget.tree.currentNode.gamesPlayed;
    final playedPercent = totalGames > 0 ? (node.gamesPlayed / totalGames * 100) : 0.0;

    // Color based on win rate
    Color winRateColor;
    if (node.winRate >= 0.55) {
      winRateColor = Colors.green;
    } else if (node.winRate >= 0.45) {
      winRateColor = Colors.orange;
    } else {
      winRateColor = Colors.red;
    }

    return InkWell(
      onTap: () {
        setState(() {
          widget.tree.makeMove(node.move);
        });
        // Notify parent about position change
        widget.onPositionSelected?.call(widget.tree.currentNode.fen);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Colors.grey[800]!,
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Move and stats row
            Row(
              children: [
                // Move notation
                Container(
                  width: 60,
                  child: Text(
                    node.move,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Games played
                Expanded(
                  child: Text(
                    '${node.gamesPlayed} games (${playedPercent.toStringAsFixed(1)}%)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[400],
                    ),
                  ),
                ),

                // Win rate
                Text(
                  '${node.winRatePercent.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: winRateColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Visual stats bar
            Row(
              children: [
                // W-D-L text
                SizedBox(
                  width: 100,
                  child: Text(
                    '${node.wins}-${node.draws}-${node.losses}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Win rate bar
                Expanded(
                  child: _buildWinRateBar(node),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Build a visual win rate bar similar to openingtree.com
  Widget _buildWinRateBar(OpeningTreeNode node) {
    final winPercent = node.gamesPlayed > 0 ? node.wins / node.gamesPlayed : 0.0;
    final drawPercent = node.gamesPlayed > 0 ? node.draws / node.gamesPlayed : 0.0;
    final lossPercent = node.gamesPlayed > 0 ? node.losses / node.gamesPlayed : 0.0;

    return Container(
      height: 16,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: Row(
          children: [
            // Win section (green)
            if (winPercent > 0)
              Expanded(
                flex: (winPercent * 100).round(),
                child: Container(
                  color: Colors.green[600],
                ),
              ),
            // Draw section (grey)
            if (drawPercent > 0)
              Expanded(
                flex: (drawPercent * 100).round(),
                child: Container(
                  color: Colors.grey[600],
                ),
              ),
            // Loss section (red)
            if (lossPercent > 0)
              Expanded(
                flex: (lossPercent * 100).round(),
                child: Container(
                  color: Colors.red[600],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
