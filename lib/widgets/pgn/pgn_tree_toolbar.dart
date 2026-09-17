import 'package:chess_auto_prep/widgets/common/horizontal_wheel_scroll.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/pgn_filter_models.dart';
import '../../design_system/theme/app_typography.dart';

/// One row for choosing a tree and narrowing the collection.
class PgnTreeToolbar extends StatelessWidget {
  const PgnTreeToolbar({
    super.key,
    required this.config,
    required this.player,
    required this.loading,
    required this.hasActiveFilters,
    required this.onApplyPreset,
    required this.onApplyConfig,
    required this.database,
    required this.onSourceChanged,
    required this.onFilter,
  });

  final SliceConfig config;
  final String? player;
  final bool loading;
  final bool hasActiveFilters;
  final Future<void> Function(HeaderFilterConfig) onApplyPreset;
  final Future<void> Function(SliceConfig) onApplyConfig;
  final bool database;
  final ValueChanged<bool> onSourceChanged;
  final VoidCallback onFilter;

  @override
  Widget build(BuildContext context) {
    final player = this.player;
    final selected = <String>{
      for (final filter in config.headerFilters)
        if (filter.value == player &&
            filter.mode == MatchMode.exact &&
            (filter.field == 'White' || filter.field == 'Black'))
          filter.field,
    };
    final style = TextButton.styleFrom(
      textStyle: AppTypography.caption(context),
      visualDensity: VisualDensity.compact,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return HorizontalWheelScroll(
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
                hasActiveFilters ? Icons.filter_alt : Icons.filter_list,
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
                    style: AppTypography.caption(context),
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
                onSelectionChanged: loading
                    ? null
                    : (value) {
                        if (!context.mounted) return;
                        if (value.isNotEmpty) {
                          unawaited(
                            onApplyPreset(
                              HeaderFilterConfig(
                                field: value.single,
                                mode: MatchMode.exact,
                                value: player,
                              ),
                            ),
                          );
                        } else {
                          unawaited(
                            onApplyConfig(
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
