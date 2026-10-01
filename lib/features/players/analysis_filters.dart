import 'package:flutter/material.dart';

import '../../chess/tactics/game_ids.dart';
import '../../ui/choice_field.dart';
import '../../ui/field_row.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import '../../ui/toggle_chip.dart';
import 'player_analysis.dart';

/// Which of the player's games count, under the count they change: how
/// often and how deep a position must be to be listed, how far back the
/// games go, and at which time controls. Every change is kept at once.
class AnalysisFilters extends StatelessWidget {
  const AnalysisFilters({super.key, required this.analysis});

  final PlayerAnalysis analysis;

  static const _ranges = {
    'All dates': null,
    'Last 30 days': 30,
    'Last 90 days': 90,
    'Last 180 days': 180,
    'Last 365 days': 365,
  };

  /// How many filters are narrowing the games or the positions.
  static int active(PlayerAnalysis analysis) => [
    analysis.minGames > 1,
    analysis.minPly != 2,
    analysis.recentDays != null,
    analysis.speeds.isNotEmpty,
  ].where((on) => on).length;

  void _range(String words) {
    if (!_ranges.containsKey(words)) return;
    analysis.recentDays = _ranges[words];
    analysis.changed();
  }

  void _speed(TimeClass speed, bool on) {
    analysis.speeds = on
        ? {...analysis.speeds, speed}
        : ({...analysis.speeds}..remove(speed));
    analysis.changed();
  }

  @override
  Widget build(BuildContext context) {
    final days = analysis.recentDays;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The two that say which positions are listed mean nothing to the
          // list of games.
          if (analysis.list != PlayerList.games) ..._positionRows(),
          FieldRow(
            label: 'Dates',
            child: SizedBox(
              width: fieldControlWidth,
              child: ChoiceField(
                text: days == null ? 'All dates' : 'Last $days days',
                options: _ranges.keys.toList(),
                hint: 'Dates',
                onSubmitted: _range,
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          Tooltip(
            message: 'With none chosen, every time control counts.',
            child: Text(
              'Time controls',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final speed in TimeClass.values)
                ToggleChip(
                  label: speed.label,
                  selected: analysis.speeds.contains(speed),
                  onSelected: (on) => _speed(speed, on),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _positionRows() => [
    FieldRow(
      label: 'Minimum games',
      tooltip: 'Positions reached in fewer games are not listed.',
      child: NumberField(
        label: 'Minimum games',
        value: analysis.minGames,
        min: 1,
        max: 10000,
        onChanged: (v) => analysis.configure(minGames: v),
      ),
    ),
    FieldRow(
      label: 'From move',
      tooltip: 'Positions before this move are not listed.',
      child: NumberField(
        label: 'From move',
        value: analysis.minPly ~/ 2,
        min: 0,
        max: 20,
        onChanged: (v) => analysis.configure(minPly: v * 2),
      ),
    ),
  ];
}
