import 'package:flutter/material.dart';

import '../../models/tactics_position.dart';
import 'puzzle_stats_display.dart';

/// Scrollable list of stored tactics for review and selection.
class TacticsBrowsePanel extends StatelessWidget {
  const TacticsBrowsePanel({
    super.key,
    required this.positions,
    this.selectedFen,
    required this.onSelectTactic,
    required this.onDeleteTactic,
    required this.onEditTactic,
    required this.onClearAll,
  });

  final List<TacticsPosition> positions;
  final String? selectedFen;
  final ValueChanged<int> onSelectTactic;
  final ValueChanged<int> onDeleteTactic;
  final ValueChanged<int> onEditTactic;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            'No tactics found yet.\nImport games to discover tactical positions.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Text(
                '${positions.length} tactics',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onClearAll,
                icon: const Icon(Icons.delete_outline,
                    size: 16, color: Colors.red),
                label:
                    const Text('Clear All', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const TacticsBrowseHeader(),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: positions.length,
            itemBuilder: (context, index) => TacticsBrowseRow(
              position: positions[index],
              index: index,
              isSelected: selectedFen != null && selectedFen == positions[index].fen,
              onTap: () => onSelectTactic(index),
              onDelete: () => onDeleteTactic(index),
              onEdit: () => onEditTactic(index),
            ),
          ),
        ),
      ],
    );
  }
}

class TacticsBrowseHeader extends StatelessWidget {
  const TacticsBrowseHeader({super.key});

  static const _headerStyle = TextStyle(
    fontWeight: FontWeight.bold,
    fontSize: 12,
    color: Colors.grey,
  );

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 72),
          SizedBox(width: 32, child: Text('Type', style: _headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 3, child: Text('Game', style: _headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 2, child: Text('Context', style: _headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 2, child: Text('Played → Best', style: _headerStyle)),
          SizedBox(width: 8),
          SizedBox(
              width: 60,
              child:
                  Text('Stats', style: _headerStyle, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class TacticsBrowseRow extends StatelessWidget {
  const TacticsBrowseRow({
    super.key,
    required this.position,
    required this.index,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
    required this.onEdit,
  });

  final TacticsPosition position;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final pos = position;

    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: 0.3)
              : (index.isEven
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: 0.02)),
          border: Border(
            bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            IconButton(
              onPressed: onDelete,
              icon: Icon(Icons.close,
                  size: 16, color: Colors.red.withValues(alpha: 0.6)),
              tooltip: 'Delete tactic',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit, size: 16),
              tooltip: 'Edit tactic',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 32,
              child: Text(
                pos.mistakeType,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: pos.mistakeType == '??' ? Colors.red : Colors.orange,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: Text(
                '${pos.gameWhite} vs ${pos.gameBlack}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                pos.positionContext,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                '${pos.userMove} → ${pos.bestMove}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(width: 8),
            PuzzleStatsDisplay(position: pos),
          ],
        ),
      ),
    );
  }
}
