import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/game_filter.dart';
import '../../ui/theme.dart';
import '../../workspace/file_filter.dart';
import 'pgn_viewer.dart';

/// Under the explorer's `This file`: the followed player's games with
/// either colour, with White or with Black, each with how many there are.
/// It is the file's filter that is set — a rule on the `White` or the
/// `Black` header — so the list of games narrows with the table, and the
/// rule is there in the Filter tab to be changed or removed.
///
/// Nothing when nobody is followed: a file that is not one player's games
/// has no side to choose.
class PlayerSideChoice extends StatelessWidget {
  const PlayerSideChoice({
    super.key,
    required this.viewer,
    required this.filter,
  });

  final PgnViewer viewer;
  final FileFilter filter;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([viewer, filter]),
    builder: (context, _) {
      final player = viewer.followed;
      if (player == null || viewer.file == null) return const SizedBox.shrink();
      final sides = viewer.followedSides;
      if (sides.white + sides.black == 0) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Row(
        children: [
          Flexible(
            child: Text(
              player,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: Space.s),
          SegmentedButton<Side?>(
            key: const ValueKey('player-side'),
            segments: [
              ButtonSegment(
                value: null,
                label: Text('All ${sides.white + sides.black}'),
              ),
              ButtonSegment(
                value: Side.white,
                label: Text('White ${sides.white}'),
              ),
              ButtonSegment(
                value: Side.black,
                label: Text('Black ${sides.black}'),
              ),
            ],
            selected: {sideKept(filter.filter, player)},
            showSelectedIcon: false,
            style: const ButtonStyle(
              animationDuration: Duration.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: Space.s),
              ),
            ),
            onSelectionChanged: (picked) =>
                filter.apply(keepingSide(filter.filter, player, picked.single)),
          ),
        ],
      );
    },
  );
}

/// Whether [rule] is the one [keepingSide] writes for [player].
bool _isSideRule(HeaderRule rule, String player) =>
    (rule.field == 'White' || rule.field == 'Black') &&
    rule.rule == FilterRule.contains &&
    rule.value.trim().toLowerCase() == player.trim().toLowerCase();

/// The colour [filter] keeps [player]'s games with, or null for both.
///
/// Example: a filter with the rule `White contains Kasparov, Gary` keeps
/// Kasparov's games with White.
Side? sideKept(GameFilter filter, String player) {
  for (final rule in filter.rules) {
    if (_isSideRule(rule, player)) {
      return rule.field == 'White' ? Side.white : Side.black;
    }
  }
  return null;
}

/// [filter] keeping [player]'s games with [side], or with either colour
/// when it is null; its other rules stay as they are.
GameFilter keepingSide(GameFilter filter, String player, Side? side) =>
    filter.copyWith(
      rules: [
        for (final rule in filter.rules)
          if (!_isSideRule(rule, player)) rule,
        if (side != null)
          HeaderRule(
            field: side == Side.white ? 'White' : 'Black',
            rule: FilterRule.contains,
            value: player,
          ),
      ],
    );
