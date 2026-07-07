/// Dataset-slice chip bar shown in the PGN Viewer app bar.
///
/// Extracted from `pgn_viewer_screen.dart`. Renders the active
/// slice chips, an add/edit-filter chip, and a filtered/total game count.
/// State is read from the shared [PgnViewerController]; opening the slice
/// dialog is the screen's concern, passed in via [onOpenSliceDialog].
library;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../models/pgn_filter_models.dart';

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
          // One-click presets for the detected protagonist. Applied presets
          // turn into regular slice chips (with ✕) above, so only offer the
          // ones that aren't active yet.
          for (final preset in controller.slicePresets)
            if (!controller.isPresetActive(preset.filter)) ...[
              const SizedBox(width: 4),
              _buildPresetChip(preset.label, preset.filter),
            ],
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

  Widget _buildPresetChip(String label, HeaderFilterConfig filter) {
    return Tooltip(
      message: 'Slice: $label',
      child: GestureDetector(
        onTap: () => controller.applySlicePreset(filter),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey[850],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.withAlpha(70), width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_outline, size: 13, color: Colors.blue[200]),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.blue[100]),
              ),
            ],
          ),
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
