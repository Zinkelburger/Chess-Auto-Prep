import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../chess/generation/draft_lines.dart' show expectimaxText;
import '../../chess/generation/eval.dart';
import '../../chess/generation/search_node.dart';
import '../../chess/generation/sources.dart' show RepliesFrom;
import '../../chess/generation/trap_scent.dart';
import '../../chess/generation/traps.dart'
    show trapMinLossCp, trapMinShare, trapRepliesAt;
import '../../engines/engine_line.dart' show Centipawns;
import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import '../board/preview_target.dart';

/// What a move is worth in the search made for one side, as White's
/// expected score; not [searched] while that search has only the engine's
/// word for the move.
typedef SideValue = ({double forWhite, bool searched});

/// One move of the Expectimax table: what it is worth when White is the
/// prepared side, what it is worth when Black is, and what the engine says.
final class SearchRow {
  const SearchRow({
    required this.move,
    required this.after,
    required this.engineCp,
    this.share,
    this.shareFrom,
    this.white,
    this.black,
    this.trapLossCp,
    this.below = noTraps,
  });

  final MoveRef move;

  /// The position the move reaches.
  final Fen after;

  /// How often the move is expected, where a search modelled the side
  /// that plays it.
  final double? share;

  /// Who gave [share], where a database of games was the opponent: its
  /// games, or Maia where it had too few. Null where Maia alone was, or
  /// the tree was saved before this was kept.
  final RepliesFrom? shareFrom;

  /// The move's value in the search made for White, and in the one made
  /// for Black; null where that search does not hold the move.
  final SideValue? white;
  final SideValue? black;

  /// The engine's verdict on [after] from White's side, in the search's
  /// packed centipawns.
  final int engineCp;

  /// What the reply throws away against the opponent's best, where it is a
  /// trap for the board's side by [trapRepliesAt]'s rule; null otherwise.
  final int? trapLossCp;

  /// The traps in the lines after the move, in the search made for the
  /// board's side: which row is worth following.
  final TrapScent below;

  bool get trap => trapLossCp != null;

  SideValue? valueFor(Side side) => side == Side.white ? white : black;
}

/// The moves at one position, from the search made for [side] ([mine]) and
/// the one made for the other side ([other]); either may be missing, or not
/// expanded here. The moves [mine] holds come first, in its order — ours
/// best first, theirs most played first — then the ones only [other] holds.
List<SearchRow> searchRows({
  required Side side,
  SearchNode? mine,
  SearchNode? other,
}) {
  final rows = <String, SearchRow>{};
  for (final (prepared, node) in [(side, mine), (side.opposite, other)]) {
    final white = prepared == Side.white;
    final from = node is OpponentNode ? node.repliesFrom : null;
    // What a move of ours must beat for a reply to it to be a trap.
    final best = prepared == side && node is OurNode
        ? node.candidates
              .map((c) => c.evalForUs.cp)
              .reduce((a, b) => a > b ? a : b)
        : null;
    for (final (move, child, share, trap) in _movesOf(node)) {
      final value = child.valuation.value;
      final SideValue worth = (
        forWhite: white ? value : 1 - value,
        searched: child is! FrontierNode,
      );
      final cp = child.evalForUs.cp;
      final held = rows[move.uci];
      rows[move.uci] = SearchRow(
        move: move,
        after: child.fen,
        // Trees of different runs may hold two scores for one position:
        // White's is shown, whichever way the board is turned.
        engineCp: white ? cp : held?.engineCp ?? -cp,
        share: held?.share ?? share,
        shareFrom: held?.share != null ? held?.shareFrom : from,
        white: white ? worth : held?.white,
        black: white ? held?.black : worth,
        trapLossCp: held?.trapLossCp ?? (prepared == side ? trap : null),
        below: prepared == side
            ? trapsBelow(child, bestBefore: best)
            : held?.below ?? noTraps,
      );
    }
  }
  return rows.values.toList();
}

/// The moves under [node] in table order, each with where it leads, its
/// share when it is a reply, and what it throws away when it is a trap.
List<(MoveRef, SearchNode, double?, int?)> _movesOf(SearchNode? node) {
  switch (node) {
    case OurNode(:final candidates):
      return [for (final c in candidates) (c.move, c.child, null, null)];
    case OpponentNode(:final replies):
      final traps = {
        for (final (reply, loss) in trapRepliesAt(node)) reply.move.uci: loss,
      };
      final sorted = [...replies]
        ..sort((a, b) => b.probability.compareTo(a.probability));
      return [
        for (final r in sorted)
          (r.move, r.child, r.probability, traps[r.move.uci]),
      ];
    default:
      return const [];
  }
}

/// The Expectimax table: a row a move, with how often it is played, its
/// expectimax for each side in [sides], and the engine's verdict, all from
/// White's side. Clicking a row plays the move; resting on it reports
/// where, for the floated board.
///
/// Every row and the header keep one height, and the columns their widths.
/// A pane too narrow for all of them leaves out Played. A move with traps
/// in the lines after it says how many beside its name.
class SearchTable extends StatelessWidget {
  const SearchTable({
    super.key,
    required this.rows,
    required this.ours,
    required this.sides,
    required this.engineDepthAt,
    required this.onHover,
    required this.onLeave,
    required this.onPlay,
    this.shareTip,
    this.valueTip,
  });

  final List<SearchRow> rows;

  /// Whether the side at the bottom of the board is the one to move.
  final bool ours;

  /// The sides a search was made for, a column each: both, or the one the
  /// mainline book is for.
  final List<Side> sides;

  /// The depth the engine scored a position at, when this session knows.
  final int? Function(Fen after) engineDepthAt;
  final void Function(SearchRow row, Offset anchor) onHover;
  final VoidCallback onLeave;
  final ValueChanged<SearchRow> onPlay;

  /// What a share's tooltip says about who gave it ([repliesFromTip]).
  final String Function(RepliesFrom from)? shareTip;

  /// What the one `Value` column is, where only one side was searched;
  /// null for the book, whose value is ChessDB's.
  final String? valueTip;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final played =
          size.maxWidth >=
          2 * Space.m +
              searchMoveWidth +
              searchShareWidth +
              (sides.length + 1) * searchValueWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(ours: ours, sides: sides, played: played, valueTip: valueTip),
          if (played && rows.any((row) => row.shareFrom == RepliesFrom.maia))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Text(
                '~ Estimated by Maia where database games are sparse.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemExtent: searchRowHeight,
              itemBuilder: (context, index) {
                final row = rows[index];
                return _RowView(
                  key: ValueKey(row.move.uci),
                  row: row,
                  sides: sides,
                  played: played,
                  engineDepth: engineDepthAt(row.after),
                  shareTip: switch (row.shareFrom) {
                    final from? => shareTip?.call(from),
                    null => null,
                  },
                  onHover: (anchor) => onHover(row, anchor),
                  onLeave: onLeave,
                  onTap: () => onPlay(row),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}

/// A number's cell: one line, right-aligned, never wrapped.
class _Cell extends StatelessWidget {
  const _Cell(this.text, {required this.width, required this.style});

  final String text;
  final double width;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Text(
      text,
      style: style,
      textAlign: TextAlign.right,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    ),
  );
}

/// The column names over the rows.
class _Header extends StatelessWidget {
  const _Header({
    required this.ours,
    required this.sides,
    required this.played,
    this.valueTip,
  });

  final bool ours;
  final List<Side> sides;
  final bool played;
  final String? valueTip;

  /// What a side's column holds, in the header's tooltip.
  static String sideTip(Side side) {
    final (prepared, modelled) = side == Side.white
        ? ('White', 'Black')
        : ('Black', 'White');
    return '$prepared plays its best moves; $modelled replies the way '
        'players do. Scored from White\'s side.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall;
    return SizedBox(
      height: searchHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Row(
          children: [
            Expanded(
              // Narrow enough to lose Played, the move column is too
              // narrow for the long names too.
              child: Tooltip(
                message: ours
                    ? 'Click a move to play it'
                    : '? marks a trap: a reply played in at least '
                          '${(trapMinShare * 100).round()}% of games that '
                          'loses ${(trapMinLossCp / 100).toStringAsFixed(1)} '
                          'or more against their best',
                child: Text(
                  switch ((ours, played)) {
                    (true, true) => 'Your move',
                    (false, true) => 'Their reply',
                    (true, false) => 'Move',
                    (false, false) => 'Reply',
                  },
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (played) _Cell('Played', width: searchShareWidth, style: style),
            // One side searched is one column; the book's is ChessDB's
            // value, not a model's, and says nothing more.
            if (sides case [_])
              switch (valueTip) {
                final tip? => Tooltip(
                  message: tip,
                  child: _Cell('Value', width: searchValueWidth, style: style),
                ),
                null => _Cell('Value', width: searchValueWidth, style: style),
              }
            else
              for (final side in sides)
                Tooltip(
                  message: sideTip(side),
                  child: _Cell(
                    side == Side.white ? 'White' : 'Black',
                    width: searchValueWidth,
                    style: style,
                  ),
                ),
            _Cell('Engine', width: searchValueWidth, style: style),
          ],
        ),
      ),
    );
  }
}

class _RowView extends StatelessWidget {
  const _RowView({
    super.key,
    required this.row,
    required this.sides,
    required this.played,
    required this.engineDepth,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
    this.shareTip,
  });

  final SearchRow row;
  final List<Side> sides;
  final bool played;
  final int? engineDepth;
  final String? shareTip;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  /// The share, marked `~` where Maia stood in for the database; the
  /// tooltip says who gave it.
  Widget _shareCell(double? share, TextStyle style) {
    final cell = _Cell(
      share == null
          ? ''
          : '${row.shareFrom == RepliesFrom.maia ? '~' : ''}${_percent(share)}',
      width: searchShareWidth,
      style: style,
    );
    final tip = shareTip;
    return share == null || tip == null
        ? cell
        : Tooltip(message: tip, child: cell);
  }

  /// The move, a trap's marked `?` and saying on hover what it costs, then
  /// how many traps wait in the lines after it.
  Widget _move(BuildContext context, TextStyle style) {
    final text = Text(
      displaySan(context, row.trap ? '${row.move.san}?' : row.move.san),
      style: style,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    );
    final loss = row.trapLossCp;
    final played = row.share == null ? '' : 'Played ${_percent(row.share!)}, ';
    final move = loss == null
        ? text
        : Tooltip(
            message:
                'Trap: ${played}loses ${(loss / 100).toStringAsFixed(1)} '
                'against their best',
            child: text,
          );
    final traps = row.below.traps;
    if (traps == 0) return Align(alignment: Alignment.centerLeft, child: move);
    return Row(
      children: [
        move,
        const SizedBox(width: Space.s),
        Flexible(
          child: Tooltip(
            message: trapsBelowTip(row.below),
            child: Text(
              traps == 1 ? '1 trap' : '$traps traps',
              style: Theme.of(context).textTheme.labelSmall,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = monoText.copyWith(color: scheme.onSurface);
    final muted = monoText.copyWith(color: scheme.onSurfaceVariant);
    final share = row.share;
    return PreviewTarget(
      onHover: onHover,
      onLeave: onLeave,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Row(
          children: [
            Expanded(child: _move(context, ink)),
            if (played) _shareCell(share, muted),
            for (final side in sides)
              switch (row.valueFor(side)) {
                null => Tooltip(
                  message:
                      'Not among the moves the search for '
                      '${side == Side.white ? 'White' : 'Black'} looked at',
                  child: _Cell('–', width: searchValueWidth, style: muted),
                ),
                // An unexpanded move is worth only what the engine says;
                // the search's own value is not in yet.
                (searched: false, forWhite: _) => _Cell(
                  '…',
                  width: searchValueWidth,
                  style: muted,
                ),
                (:final forWhite, searched: true) => _Cell(
                  expectimaxText(forWhite),
                  width: searchValueWidth,
                  style: ink,
                ),
              },
            Tooltip(
              message: engineDepth == null
                  ? 'Depth unknown (saved or database result)'
                  : 'Depth $engineDepth',
              child: _Cell(
                _engineText(row.engineCp),
                width: searchValueWidth,
                style: muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The engine's verdict from White's side, as the engine pane writes one;
/// a mate the search found is `#`.
String _engineText(int cp) {
  if (cp.abs() >= mateSaturationCp) return cp > 0 ? '+#' : '-#';
  return Centipawns(cp).text;
}

String _percent(double share) {
  final percent = (share * 100).round();
  return percent < 1 ? '<1%' : '$percent%';
}

/// What a row's trap count means, for its tooltip.
///
/// Example: `2 traps in the lines after this move. The likeliest comes up
/// in 1 of 12 games from here.`
String trapsBelowTip(TrapScent below) {
  final count = below.traps == 1 ? '1 trap' : '${below.traps} traps';
  final onceIn = below.likeliest <= 0 ? 0 : (1 / below.likeliest).round();
  final often = onceIn <= 1
      ? 'nearly every game'
      : onceIn > 9999
      ? 'very few games'
      : '1 of $onceIn games';
  return '$count in the lines after this move. '
      'The likeliest comes up in $often from here.';
}

/// What the one value column of a search made for [side] holds.
String searchValueTip(Side side) => _Header.sideTip(side);

/// Who gave a share, for its tooltip: the [database]'s games, or Maia at
/// [elo] where the database had fewer than [fallbackUnder] games.
///
/// Example: `Maia 2200; Lichess masters has under 10 games here`.
String repliesFromTip(
  RepliesFrom from, {
  required String database,
  required int elo,
  required int? fallbackUnder,
}) => switch (from) {
  RepliesFrom.games => 'From $database',
  RepliesFrom.maia =>
    'Maia $elo; $database has under ${fallbackUnder ?? 1} games here',
};
