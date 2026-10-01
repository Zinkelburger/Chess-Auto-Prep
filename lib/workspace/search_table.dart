import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/generation/draft_lines.dart' show expectimaxText;
import '../chess/generation/eval.dart';
import '../chess/generation/search_node.dart';
import '../engines/engine_line.dart' show Centipawns;
import '../ui/move_notation.dart';
import '../ui/theme.dart';

/// A reply that loses this much against the opponent's best is a trap.
const trapLossCp = 50;

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
    this.white,
    this.black,
    this.trap = false,
  });

  final MoveRef move;

  /// The position the move reaches.
  final Fen after;

  /// How often the move is expected, where a search modelled the side
  /// that plays it.
  final double? share;

  /// The move's value in the search made for White, and in the one made
  /// for Black; null where that search does not hold the move.
  final SideValue? white;
  final SideValue? black;

  /// The engine's verdict on [after] from White's side, in the search's
  /// packed centipawns.
  final int engineCp;

  /// A reply to the board's side that loses [trapLossCp] or more against
  /// their best.
  final bool trap;

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
        white: white ? worth : held?.white,
        black: white ? held?.black : worth,
        trap: (held?.trap ?? false) || (prepared == side && trap),
      );
    }
  }
  return rows.values.toList();
}

/// The moves under [node] in table order, each with where it leads, its
/// share when it is a reply, and whether that reply loses half a pawn or
/// more against the best of them.
List<(MoveRef, SearchNode, double?, bool)> _movesOf(SearchNode? node) {
  switch (node) {
    case OurNode(:final candidates):
      return [for (final c in candidates) (c.move, c.child, null, false)];
    case OpponentNode(:final replies):
      final best = replies
          .map((r) => r.child.evalForUs.cp)
          .reduce((a, b) => a < b ? a : b);
      final sorted = [...replies]
        ..sort((a, b) => b.probability.compareTo(a.probability));
      return [
        for (final r in sorted)
          (
            r.move,
            r.child,
            r.probability,
            r.child.evalForUs.cp - best >= trapLossCp,
          ),
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
/// A pane too narrow for all of them leaves out Played.
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
          _Header(ours: ours, sides: sides, played: played),
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
  });

  final bool ours;
  final List<Side> sides;
  final bool played;

  static String _tip(Side side) {
    final (prepared, modelled) = side == Side.white
        ? ('White', 'Black')
        : ('Black', 'White');
    return '$prepared plays its best moves; $modelled replies as Maia '
        'predicts. Scored from White\'s side.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      height: searchHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Row(
          children: [
            Expanded(
              child: Text(
                ours ? 'Your move' : 'Their reply',
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (played) _Cell('Played', width: searchShareWidth, style: style),
            // The book's one column is ChessDB's value, not a model's.
            if (sides case [_])
              _Cell('Value', width: searchValueWidth, style: style)
            else
              for (final side in sides)
                Tooltip(
                  message: _tip(side),
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
  });

  final SearchRow row;
  final List<Side> sides;
  final bool played;
  final int? engineDepth;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = monoText.copyWith(color: scheme.onSurface);
    final muted = monoText.copyWith(color: scheme.onSurfaceVariant);
    final share = row.share;
    return MouseRegion(
      onEnter: (_) => onHover(_anchor(context)),
      onExit: (_) => onLeave(),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  displaySan(
                    context,
                    row.trap ? '${row.move.san}?' : row.move.san,
                  ),
                  style: ink,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                ),
              ),
              if (played)
                _Cell(
                  share == null ? '' : _percent(share),
                  width: searchShareWidth,
                  style: muted,
                ),
              for (final side in sides)
                switch (row.valueFor(side)) {
                  null => const SizedBox(width: searchValueWidth),
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
