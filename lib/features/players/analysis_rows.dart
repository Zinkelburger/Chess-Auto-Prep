import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import 'player_analysis.dart';
import 'player_games.dart';
import 'player_hunt.dart';

/// The names over the positions table, which are also how it is sorted:
/// Games puts the most played first, Score the worst score and then, pressed
/// again, the best. Eval is there once an engine pass has scored positions.
class PositionsHeader extends StatelessWidget {
  const PositionsHeader({super.key, required this.analysis});

  final PlayerAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final order = analysis.order;
    final byScore =
        order == PositionOrder.lowScore || order == PositionOrder.highScore;
    return SizedBox(
      height: searchHeaderHeight,
      child: Row(
        children: [
          const SizedBox(width: Space.m),
          Text('Position', style: Theme.of(context).textTheme.labelSmall),
          if (analysis.evals.isNotEmpty) ...[
            const SizedBox(width: Space.m),
            _Sorter(
              label: 'Eval',
              tooltip: 'Worst engine evaluation first',
              active: order == PositionOrder.badEval,
              onTap: () => analysis.configure(order: PositionOrder.badEval),
            ),
          ],
          const Spacer(),
          SizedBox(
            width: positionGamesWidth,
            child: _Sorter(
              label: 'Games',
              tooltip: 'Most played first',
              active: order == PositionOrder.frequent,
              onTap: () => analysis.configure(order: PositionOrder.frequent),
            ),
          ),
          SizedBox(
            width: positionScoreWidth,
            child: _Sorter(
              label: 'Score',
              tooltip: order == PositionOrder.lowScore
                  ? 'Best score first'
                  : 'Worst score first',
              active: byScore,
              ascending: order == PositionOrder.lowScore,
              onTap: () => analysis.configure(
                order: order == PositionOrder.lowScore
                    ? PositionOrder.highScore
                    : PositionOrder.lowScore,
              ),
            ),
          ),
          const SizedBox(width: Space.m),
        ],
      ),
    );
  }
}

/// A column's name as the way to sort by it: bright with an arrow while the
/// table is sorted by it.
class _Sorter extends StatelessWidget {
  const _Sorter({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.ascending = false,
  });

  final String label;
  final String tooltip;
  final bool active;
  final bool ascending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = active
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (active)
              Icon(
                ascending ? Icons.arrow_upward : Icons.arrow_downward,
                size: IconSize.sort,
                color: ink,
              ),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: ink),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One position the player reached: the moves to it, how often, and how
/// they scored from it; under the moves, wins, draws and losses the way a
/// crosstable writes them, and the engine's score once there is one.
class PositionRow extends StatelessWidget {
  const PositionRow({
    super.key,
    required this.position,
    required this.eval,
    required this.onOpen,
  });

  final PlayerPosition position;

  /// The engine's packed score from the player's side, when a pass gave one.
  final int? eval;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = position;
    final muted = monoText.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final score = at.score;
    return InkWell(
      onTap: onOpen,
      child: Container(
        // As tall as a row of the other lists; taller when the moves wrap.
        constraints: const BoxConstraints(minHeight: puzzleRowHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs,
        ),
        child: Row(
          children: [
            Expanded(child: _line(context, theme)),
            SizedBox(
              width: positionGamesWidth,
              child: Text(
                '${at.count}',
                style: muted,
                textAlign: TextAlign.end,
              ),
            ),
            SizedBox(
              width: positionScoreWidth,
              child: Text(
                score == null ? '–' : '${(score * 100).round()}%',
                style: monoText.copyWith(color: theme.colorScheme.onSurface),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        // A move stays on the line of its number.
        displaySan(context, position.label).replaceAll('. ', '.\u00A0'),
        style: monoText.copyWith(color: theme.colorScheme.onSurface),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      Text(
        [
          '+${position.wins} =${position.draws} −${position.losses}',
          if (position.unknown > 0) '${position.unknown} unfinished',
          if (eval case final eval?) scoreFromPacked(eval).text,
        ].join(' · '),
        style: theme.textTheme.labelSmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );
}

/// One of the player's games: who it was against and how it ended, then
/// when, in which opening and where.
class PlayerGameRow extends StatelessWidget {
  const PlayerGameRow({super.key, required this.game, required this.onOpen});

  final AnalyzedGame game;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opponent = game.tag(game.side == Side.white ? 'Black' : 'White');
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    opponent.isEmpty ? 'Unknown opponent' : opponent,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Space.s),
                Text(
                  game.result,
                  style: monoText.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Text(
              [
                game.date,
                game.tag('ECO'),
                game.tag('Event'),
              ].where((word) => word.isNotEmpty && word != '?').join(' · '),
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Words in place of a list: why it is empty, and the one thing that fixes
/// it when there is one.
class ListMessage extends StatelessWidget {
  const ListMessage(this.text, {super.key, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Space.l),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: Theme.of(context).textTheme.bodyMedium),
        if (action case final action?) ...[
          const SizedBox(height: Space.s),
          action,
        ],
      ],
    ),
  );
}
