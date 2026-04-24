/// Shared Lichess database selector: DB toggle, speed chips, rating chips,
/// and min-games field.  Used by both repertoire generation and coverage
/// analysis.
library;

import 'package:flutter/material.dart';

import '../services/coverage_service.dart';
import 'lichess_db_info_icon.dart';

const _speedOptions = <(String label, String value)>[
  ('UltraBullet', 'ultraBullet'),
  ('Bullet', 'bullet'),
  ('Blitz', 'blitz'),
  ('Rapid', 'rapid'),
  ('Classical', 'classical'),
  ('Correspondence', 'correspondence'),
];

const _ratingBuckets = [
  '400', '1000', '1200', '1400', '1600', '1800', '2000', '2200', '2500',
];

/// All-in-one Lichess DB selection widget.
///
/// Renders the database toggle (Lichess / Masters), speed filter chips,
/// rating filter chips, and an optional min-games field.
class LichessDbSelector extends StatelessWidget {
  const LichessDbSelector({
    super.key,
    required this.database,
    required this.onDatabaseChanged,
    required this.selectedSpeeds,
    required this.onSpeedsChanged,
    required this.selectedRatings,
    required this.onRatingsChanged,
    this.minGamesController,
    this.enabled = true,
    this.compact = false,
  });

  final LichessDatabase database;
  final ValueChanged<LichessDatabase> onDatabaseChanged;

  final Set<String> selectedSpeeds;
  final ValueChanged<Set<String>> onSpeedsChanged;

  final Set<String> selectedRatings;
  final ValueChanged<Set<String>> onRatingsChanged;

  /// If provided, shows a "Min Games" text field.
  final TextEditingController? minGamesController;

  /// When false, all controls are disabled (e.g. during generation).
  final bool enabled;

  /// When true, uses smaller chip styling for inline/embedded use.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Database toggle
        Row(
          children: [
            if (!compact)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('Database',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            if (compact)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child:
                    Text('Database:', style: TextStyle(fontSize: 13)),
              ),
            const LichessDbInfoIcon(size: 14),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<LichessDatabase>(
          segments: const [
            ButtonSegment(
              value: LichessDatabase.lichess,
              label: Text('Lichess'),
              icon: Icon(Icons.computer, size: 16),
            ),
            ButtonSegment(
              value: LichessDatabase.masters,
              label: Text('Masters'),
              icon: Icon(Icons.star, size: 16),
            ),
          ],
          selected: {database},
          onSelectionChanged: enabled
              ? (s) => onDatabaseChanged(s.first)
              : null,
        ),

        // Speed & rating filters (only for the Lichess player DB)
        if (database == LichessDatabase.lichess) ...[
          const SizedBox(height: 12),
          _buildSpeedSection(theme),
          const SizedBox(height: 12),
          _buildRatingSection(theme),
        ],

        // Min games (applies to both Lichess and Masters)
        if (minGamesController != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: 140,
            child: Tooltip(
              message:
                  'Minimum games for a move to be considered.\n'
                  'Lower values include rarer moves, higher values\n'
                  'give more reliable statistics.',
              child: TextField(
                controller: minGamesController,
                enabled: enabled,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Min Games',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSpeedSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact)
          Text('Time Controls',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        if (compact)
          Tooltip(
            message: 'Which time controls to include.',
            child: Text('Speeds:',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _speedOptions.map((opt) {
            final isSelected = selectedSpeeds.contains(opt.$2);
            return FilterChip(
              label: Text(opt.$1,
                  style: TextStyle(fontSize: compact ? 11 : 12)),
              selected: isSelected,
              onSelected: enabled
                  ? (v) {
                      final next = Set.of(selectedSpeeds);
                      if (v) {
                        next.add(opt.$2);
                      } else if (next.length > 1) {
                        next.remove(opt.$2);
                      }
                      onSpeedsChanged(next);
                    }
                  : null,
              visualDensity: compact ? VisualDensity.compact : null,
              materialTapTargetSize: compact
                  ? MaterialTapTargetSize.shrinkWrap
                  : null,
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildRatingSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact)
          Text('Rating Ranges',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        if (compact)
          Tooltip(
            message:
                'Rating buckets to include.\n'
                'Each value is the lower bound of a Lichess rating bracket.',
            child: Text('Ratings:',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _ratingBuckets.map((r) {
            final isSelected = selectedRatings.contains(r);
            return FilterChip(
              label:
                  Text(r, style: TextStyle(fontSize: compact ? 11 : 12)),
              selected: isSelected,
              onSelected: enabled
                  ? (v) {
                      final next = Set.of(selectedRatings);
                      if (v) {
                        next.add(r);
                      } else if (next.length > 1) {
                        next.remove(r);
                      }
                      onRatingsChanged(next);
                    }
                  : null,
              visualDensity: compact ? VisualDensity.compact : null,
              materialTapTargetSize: compact
                  ? MaterialTapTargetSize.shrinkWrap
                  : null,
            );
          }).toList(),
        ),
      ],
    );
  }
}
