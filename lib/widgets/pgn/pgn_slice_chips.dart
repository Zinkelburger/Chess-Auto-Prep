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
import '../../theme/app_colors.dart';

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
                color: AppColors.infoTint,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppColors.info.withAlpha(60),
                  width: 0.5,
                ),
              ),
              child: Text(
                '${controller.filteredGames.length}/${controller.allGames.length}',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  // info, not chipActiveFg: on the pale infoTint wash the
                  // near-white fg would erase the "filters active" signal.
                  color: AppColors.info,
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
          color: AppColors.chipActiveBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.info.withAlpha(60), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.chipActiveFg,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => controller.removeSliceChip(index),
              child: Icon(
                Icons.close,
                size: 13,
                color: AppColors.chipActiveFg.withAlpha(180),
              ),
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
            color: AppColors.surfaceInset,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.info.withAlpha(70), width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 13, color: AppColors.info),
              const SizedBox(width: 3),
              Text(
                label,
                // Matches the info icon beside it; chipActiveFg is reserved
                // for text sitting on a chipActiveBg fill.
                style: const TextStyle(fontSize: 11, color: AppColors.info),
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
            // Fill flips to the active-chip blue when filters are applied so
            // the Edit affordance reads as "on" at a glance (the fg colors
            // alone were too close to tell apart on the grey fill).
            color: controller.hasActiveFilters
                ? AppColors.chipActiveBg
                : AppColors.chipInactiveBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: controller.hasActiveFilters
                  ? AppColors.info.withAlpha(40)
                  : AppColors.outline,
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
                    ? AppColors.chipActiveFg
                    : AppColors.onSurfaceSoft,
              ),
              const SizedBox(width: 3),
              Text(
                controller.hasActiveFilters ? 'Edit' : 'Slice',
                style: TextStyle(
                  fontSize: 11,
                  color: controller.hasActiveFilters
                      ? AppColors.chipActiveFg
                      : AppColors.onSurfaceSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
