import 'package:flutter/material.dart';

import '../../chess/explorer_answer.dart';
import '../../ui/list_row.dart';
import '../../ui/theme.dart';

/// How the games went, as lila draws it: White's wins, the draws and
/// Black's wins side by side, each as wide as its share, with the share
/// written in every part wide enough to hold it.
class ResultBar extends StatelessWidget {
  const ResultBar({
    super.key,
    required this.white,
    required this.draws,
    required this.black,
  });

  final int white;
  final int draws;
  final int black;

  @override
  Widget build(BuildContext context) {
    final total = white + draws + black;
    if (total == 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(Space.xs / 2),
      child: SizedBox(
        height: explorerBarHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _part(white, total, resultBarWhite, resultBarWhiteInk),
            _part(draws, total, resultBarDraw, resultBarDrawInk),
            _part(black, total, resultBarBlack, resultBarBlackInk),
          ],
        ),
      ),
    );
  }

  Widget _part(int count, int total, Color fill, Color ink) {
    if (count == 0) return const SizedBox.shrink();
    final share = count / total;
    final label = '${(share * 100).round()}%';
    final style = resultBarText.copyWith(color: ink);
    return Expanded(
      flex: (share * 1000).round().clamp(1, 1000),
      child: ColoredBox(
        color: fill,
        child: LayoutBuilder(
          builder: (context, constraints) =>
              _fits(label, style, context, constraints.maxWidth)
              ? Center(child: Text(label, style: style, maxLines: 1))
              : const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Whether [label] fits in [width] with a little room either side.
  static bool _fits(
    String label,
    TextStyle style,
    BuildContext context,
    double width,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final fits = painter.width + Space.xs <= width;
    painter.dispose();
    return fits;
  }
}

/// One game the explorer lists: the players with their ratings when known,
/// how it ended and when. Clicking it opens the game.
class ExplorerGameRow extends StatelessWidget {
  const ExplorerGameRow({
    super.key,
    required this.game,
    this.fetching = false,
    required this.onTap,
  });

  final ExplorerGame game;

  /// The game is being fetched to open; said where its year is.
  final bool fetching;
  final VoidCallback? onTap;

  String _player(String name, int? elo) => elo == null ? name : '$name ($elo)';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall;
    return ListRow(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_player(game.white, game.whiteElo)} – '
              '${_player(game.black, game.blackElo)}',
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: Space.m),
          Text(
            game.result,
            style: monoText.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: Space.m),
          SizedBox(
            width: explorerGamesWidth / 2,
            child: Text(
              fetching ? 'Fetching…' : '${game.year ?? ''}',
              style: muted,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
