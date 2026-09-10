import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../models/pgn_filter_models.dart';
import '../../theme/app_text_styles.dart';

/// One row for choosing a tree and narrowing the collection.
class PgnTreeToolbar extends StatelessWidget {
  const PgnTreeToolbar({
    super.key,
    required this.controller,
    required this.database,
    required this.onSourceChanged,
    required this.onFilter,
  });

  final PgnViewerController controller;
  final bool database;
  final ValueChanged<bool> onSourceChanged;
  final VoidCallback onFilter;

  @override
  Widget build(BuildContext context) {
    final player = controller.collectionPlayer;
    final selected = <String>{
      for (final filter in controller.activeSliceConfig.headerFilters)
        if (filter.value == player &&
            filter.mode == MatchMode.exact &&
            (filter.field == 'White' || filter.field == 'Black'))
          filter.field,
    };
    final style = TextButton.styleFrom(
      textStyle: AppTextStyles.caption,
      visualDensity: VisualDensity.compact,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SegmentedButton<bool>(
            style: style,
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Collection'),
                tooltip: 'Collection tree',
              ),
              ButtonSegment(
                value: true,
                label: Text('Database'),
                tooltip: 'Database explorer',
              ),
            ],
            selected: {database},
            showSelectedIcon: false,
            onSelectionChanged: (value) => onSourceChanged(value.single),
          ),
          if (!database) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              style: style,
              onPressed: onFilter,
              icon: Icon(
                controller.hasActiveFilters
                    ? Icons.filter_alt
                    : Icons.filter_list,
                size: 16,
              ),
              label: const Text('Filter'),
            ),
            if (player != null) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: player,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 100),
                  child: Text(
                    player.split(',').first,
                    style: AppTextStyles.caption,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<String>(
                style: style,
                segments: [
                  for (final side in ['White', 'Black'])
                    ButtonSegment(
                      value: side,
                      label: Text(side),
                      tooltip: '$player as $side',
                    ),
                ],
                selected: selected.take(1).toSet(),
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: controller.isLoading
                    ? null
                    : (value) {
                        if (!context.mounted) return;
                        if (value.isNotEmpty) {
                          unawaited(
                            controller.applySlicePreset(
                              HeaderFilterConfig(
                                field: value.single,
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
                                additionalPositions: config.additionalPositions,
                                matchAny: config.matchAny,
                                headerFilters: config.headerFilters
                                    .where(
                                      (filter) =>
                                          !(selected.contains(filter.field) &&
                                              filter.value == player &&
                                              filter.mode == MatchMode.exact),
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
            ],
          ],
        ],
      ),
    );
  }
}
