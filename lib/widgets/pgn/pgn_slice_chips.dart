/// Compact, editable applied filters beside the PGN viewer title.
library;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../models/pgn_filter_models.dart';
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
    final labels = <({String value, String detail, String full})>[
      for (final position in [
        if (config.positionInput != null) config.positionInput!,
        ...config.additionalPositions,
      ])
        if (position.isNotEmpty)
          (value: position, detail: 'Position', full: 'Position: $position'),
      if (config.sequencePattern case final sequence? when sequence.isNotEmpty)
        (
          value: sequence,
          detail: 'Moves · gap ${config.sequenceGap}',
          full: 'Move sequence: $sequence (gap ${config.sequenceGap})',
        ),
      for (final filter in config.headerFilters)
        if (filter.value.isNotEmpty) _headerLabel(filter),
    ];
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
            SizedBox(
              key: ValueKey(('applied-filter', i)),
              width: 112,
              height: 44,
              child: Material(
                color: AppColors.surfaceInset,
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: 'Edit ${labels[i].full}',
                        child: InkWell(
                          onTap: onOpenSliceDialog,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  labels[i].value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.muted.copyWith(
                                    color: AppColors.ink,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  labels[i].detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.caption,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove ${labels[i].full}',
                      onPressed: () => controller.removeSliceChip(i),
                      icon: const Icon(Icons.close, size: 14),
                      color: AppColors.onSurfaceMuted,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 44,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey('add-collection-filter'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onSurfaceMuted,
              backgroundColor: Colors.transparent,
              textStyle: AppTextStyles.muted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: onOpenSliceDialog,
            icon: const Icon(Icons.add, size: 16),
            label: Text(labels.isEmpty ? 'Filter games' : 'Add filter'),
          ),
        ],
      ),
    );
  }

  ({String value, String detail, String full}) _headerLabel(
    HeaderFilterConfig filter,
  ) {
    final codes = filter.field == 'ECO'
        ? selectedEcoCodes(filter.value, filter.mode)
        : <String>[];
    final value = codes.isEmpty ? filter.value : codes.join(', ');
    final field = switch (filter.field) {
      'WhiteElo' => 'White rating',
      'BlackElo' => 'Black rating',
      'StudyRating' => 'Study rating',
      'StudySummary' => 'Study summary',
      'Site' => 'Place',
      _ => filter.field,
    };
    final detail = codes.length > 1
        ? '$field · any of'
        : switch (filter.mode) {
            MatchMode.contains || MatchMode.exact => field,
            MatchMode.notContains => 'Not $field',
            MatchMode.regex => '$field · regex',
            MatchMode.after => '$field ≥',
            MatchMode.before => '$field ≤',
          };
    return (
      value: value,
      detail: detail,
      full: codes.isEmpty ? filter.chipLabel : 'ECO: $value',
    );
  }
}
