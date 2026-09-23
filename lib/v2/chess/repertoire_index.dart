import 'package:dartchess/dartchess.dart' show Side;

import 'fen.dart';
import 'pgn/game_tree.dart';

/// One move of a repertoire file at one position, where the file first
/// plays it.
final class IndexedMove {
  IndexedMove(this.node, this.sans);

  final MoveNode node;

  /// From the file's start to the position after the move.
  final List<String> sans;

  int _lines = 0;

  /// The lines of the file through it: the ends of lines below it.
  int get lines => _lines;
}

/// What one repertoire file plays, looked up by position: the Tree tab's
/// rows and the book check's verdicts both read it.
///
/// Positions are keyed without the move counters ([Fen.position]), so a
/// transposition finds the lines another move order wrote. Every position
/// the file reaches is a key, including the ones where a line ends, which
/// map to no moves: "the book ends here" is an answer, not a miss.
///
/// Example: a file with the one line `1.e4 e5 2.Nf3` has four keys — the
/// start (`e2e4`), after 1.e4 (`e7e5`), after 1...e5 (`g1f3`) and after
/// 2.Nf3, with no moves — and [into] of the last is 2.Nf3 with the sans
/// `[e4, e5, Nf3]`.
final class RepertoireIndex {
  RepertoireIndex._(this.side, this._moves, this._into);

  factory RepertoireIndex.of(GameTree tree, Side side) {
    final moves = <String, Map<String, IndexedMove>>{};
    final into = <String, IndexedMove>{};
    final sans = <String>[];
    int visit(Fen fen, List<MoveNode> children) {
      final here = moves[fen.position] ??= {};
      if (children.isEmpty) return 1;
      var total = 0;
      for (final child in children) {
        sans.add(child.san);
        // The first place the file plays the move is where it is read, so
        // it is claimed before the line under it is walked.
        final first = here.containsKey(child.uci)
            ? null
            : here[child.uci] = IndexedMove(child, List.unmodifiable(sans));
        if (first != null) into.putIfAbsent(child.fen.position, () => first);
        final lines = visit(child.fen, child.children);
        sans.removeLast();
        first?._lines = lines;
        total += lines;
      }
      return total;
    }

    visit(tree.rootFen, tree.children);
    return RepertoireIndex._(side, moves, into);
  }

  /// The side the file is a repertoire for.
  final Side side;

  final Map<String, Map<String, IndexedMove>> _moves;
  final Map<String, IndexedMove> _into;

  /// The moves the file plays at [position] (a [Fen.position]) by UCI:
  /// empty where a line of it ends, null where it never goes.
  Map<String, IndexedMove>? movesAt(String position) => _moves[position];

  /// The move that first brings the file to [position]; null for the
  /// file's start and for a position it never reaches.
  IndexedMove? into(String position) => _into[position];
}
