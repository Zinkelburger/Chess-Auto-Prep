/// Compact, editable applied filters beside the PGN viewer title.
library;

import 'package:chess_auto_prep/widgets/common/horizontal_wheel_scroll.dart';

import 'package:flutter/material.dart';

import '../../models/pgn_filter_models.dart';
import '../../design_system/theme/workspace_theme.dart';
import '../../design_system/theme/app_typography.dart';
import '../slice/eco_filter_chips.dart';

class PgnSliceChips extends StatelessWidget {
  final SliceConfig config;
  final ValueChanged<int> onRemoveChip;
  final VoidCallback onOpenSliceDialog;

  const PgnSliceChips({
    super.key,
    required this.config,
    required this.onRemoveChip,
    required this.onOpenSliceDialog,
  });

  @override
  Widget build(BuildContext context) {
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
    return HorizontalWheelScroll(
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  config.matchAny ? 'OR' : 'AND',
                  style: AppTypography.caption(context),
                ),
              ),
            SizedBox(
              key: ValueKey(('applied-filter', i)),
              width: 112 * MediaQuery.textScalerOf(context).scale(1),
              height: 20 + 28 * MediaQuery.textScalerOf(context).scale(1),
              child: Material(
                color: WorkspaceTheme.of(context).inset,
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
                            child: _label(
                              context,
                              labels[i].value,
                              labels[i].detail,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove ${labels[i].full}',
                      onPressed: () => onRemoveChip(i),
                      icon: const Icon(Icons.close, size: 14),
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints.tightFor(
                        width: 28,
                        height:
                            20 + 28 * MediaQuery.textScalerOf(context).scale(1),
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
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              textStyle: AppTypography.secondary(context),
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

  Widget _label(BuildContext context, String value, String detail) {
    final valueStyle = AppTypography.secondary(context).copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      fontWeight: FontWeight.w500,
    );
    final detailStyle = AppTypography.caption(context);
    final scaler = MediaQuery.textScalerOf(context);
    final twoLineHeight =
        (scaler.scale(valueStyle.fontSize!) * (valueStyle.height ?? 1)).ceil() +
        (scaler.scale(detailStyle.fontSize!) * (detailStyle.height ?? 1))
            .ceil();
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: valueStyle,
          ),
          // The app bar has a fixed height. Keep the scaled value readable when
          // its secondary line cannot fit; the edit/remove tooltips retain both.
          if (constraints.maxHeight >= twoLineHeight)
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: detailStyle,
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
