/// Editable applied collection filters beside the PGN viewer title.
library;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../slice/eco_filter_chips.dart';

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
    final config = controller.activeSliceConfig;
    final labels = config.chipLabels;
    // Replace picker-generated regexes with the codes the user selected.
    final headerOffset =
        labels.length -
        config.headerFilters.where((f) => f.value.isNotEmpty).length;
    var index = headerOffset;
    for (final filter in config.headerFilters) {
      if (filter.value.isEmpty) continue;
      final codes = filter.field == 'ECO'
          ? selectedEcoCodes(filter.value, filter.mode)
          : <String>[];
      if (codes.isNotEmpty) labels[index] = 'ECO: ${codes.join(', ')}';
      index++;
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  config.matchAny ? 'OR' : 'AND',
                  style: AppTextStyles.caption,
                ),
              ),
            InputChip(
              key: ValueKey(('applied-filter', i)),
              tooltip: 'Edit ${labels[i]}',
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 230),
                child: Text(
                  labels[i],
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.muted.copyWith(color: AppColors.ink),
                ),
              ),
              backgroundColor: AppColors.surface,
              side: const BorderSide(color: AppColors.outline),
              onPressed: onOpenSliceDialog,
              onDeleted: () => controller.removeSliceChip(i),
              deleteButtonTooltipMessage: 'Remove ${labels[i]}',
            ),
          ],
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey('add-collection-filter'),
            onPressed: onOpenSliceDialog,
            icon: const Icon(Icons.add, size: 18),
            label: Text(labels.isEmpty ? 'Filter games' : 'Add filter'),
          ),
        ],
      ),
    );
  }
}
