/// Dataset-slice chip bar shown in the PGN Viewer app bar.
///
/// Extracted from `pgn_viewer_screen.dart` (WS-C / B3). Renders the active
/// slice chips, an add/edit-filter chip, and a filtered/total game count.
/// State is read from the shared [PgnViewerController]; opening the slice
/// dialog is the screen's concern, passed in via [onOpenSliceDialog].
library;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';

class PgnSliceChips extends StatelessWidget {
  final PgnViewerController controller;
  final VoidCallback onOpenSliceDialog;

  const PgnSliceChips({
    super.key,
    required this.controller,
    required this.onOpenSliceDialog,
  });

  @override
  Widget build(BuildContext context) {
    final chipLabels = controller.activeSliceConfig.chipLabels;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < chipLabels.length; i++) ...[
            _buildActiveChip(chipLabels[i], i),
            const SizedBox(width: 4),
          ],
          _buildAddSliceChip(),
          if (controller.hasActiveFilters) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: Colors.blue.withAlpha(60), width: 0.5),
              ),
              child: Text(
                '${controller.filteredGames.length}/${controller.allGames.length}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue[300],
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveChip(String label, int index) {
    return GestureDetector(
      onTap: onOpenSliceDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.blue[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withAlpha(60), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.blue[100],
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => controller.removeSliceChip(index),
              child: Icon(Icons.close,
                  size: 13, color: Colors.blue[300]!.withAlpha(180)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddSliceChip() {
    return Tooltip(
      message: controller.hasActiveFilters ? 'Edit filters' : 'Add filter',
      child: GestureDetector(
        onTap: onOpenSliceDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: controller.hasActiveFilters
                  ? Colors.blue.withAlpha(40)
                  : Colors.grey[700]!,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add,
                size: 13,
                color: controller.hasActiveFilters
                    ? Colors.blue[300]
                    : Colors.grey[400],
              ),
              const SizedBox(width: 3),
              Text(
                controller.hasActiveFilters ? 'Edit' : 'Slice',
                style: TextStyle(
                  fontSize: 11,
                  color: controller.hasActiveFilters
                      ? Colors.blue[300]
                      : Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
