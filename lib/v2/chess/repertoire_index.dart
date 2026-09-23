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

  /// The lines of the file through it, by every move order that plays it
  /// here: the ends of lines below it.
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
///
/// A move's [IndexedMove.lines] counts the lines under every place the
/// file plays it from the position: with `1.d4 Nf6 2.c4 e6 3.Nc3` and
/// `1.c4 Nf6 2.d4 e6 3.Nc3`, 3.Nc3 is two lines. A place inside another
/// place of the same move — a line that repeats the position and plays the
/// move again — holds lines already counted there, and adds none.
final class RepertoireIndex {
  RepertoireIndex._(this.side, this._moves, this._into);

  factory RepertoireIndex.of(GameTree tree, Side side) {
    final moves = <String, Map<String, IndexedMove>>{};
    final into = <String, IndexedMove>{};
    final sans = <String>[];
    // The moves the line being walked is already under, by position.
    final under = <String>{};
    int visit(Fen fen, List<MoveNode> children) {
      final position = fen.position;
      final here = moves[position] ??= {};
      if (children.isEmpty) return 1;
      var total = 0;
      for (final child in children) {
        sans.add(child.san);
        // The first place the file plays the move is where it is read, so
        // it is claimed before the line under it is walked.
        final move = here[child.uci] ??= _claimed(child, sans, into);
        final key = '$position ${child.uci}';
        final outermost = under.add(key);
        final lines = visit(child.fen, child.children);
        if (outermost) {
          under.remove(key);
          move._lines += lines;
        }
        sans.removeLast();
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

/// [child] as the move first read at its position, which also first brings
/// the file to the position after it unless another move already did.
IndexedMove _claimed(
  MoveNode child,
  List<String> sans,
  Map<String, IndexedMove> into,
) {
  final move = IndexedMove(child, List.unmodifiable(sans));
  into.putIfAbsent(child.fen.position, () => move);
  return move;
}
