import '../chess/fen.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pv_text.dart';

/// A line written in a comment, on the board as far as one of its moves
/// without being written into the file: how a course's `12. Nf3 is the
/// alternative` is read.
final class CommentLine {
  const CommentLine({required this.from, required this.moves, required this.at})
    : assert(at >= 0 && at < moves.length);

  /// The move the comment belongs to, where [moves] start from.
  final NodePath from;

  /// Every move of the line as written, from [from]'s position.
  final List<PvMove> moves;

  /// The index in [moves] of the move on the board.
  final int at;

  PvMove get move => moves[at];
  Fen get fen => move.after;

  /// The same line, on the board as far as its move at [index].
  CommentLine atMove(int index) =>
      CommentLine(from: from, moves: moves, at: index);

  /// Whether [move], written in a comment on the move at [from], is the one
  /// on the board. A comment shown twice, in the move list and under the
  /// board, marks it in both.
  bool shows(NodePath from, PvMove move) =>
      from == this.from && move.after == fen && move.uci == this.move.uci;
}

/// Where [tree] plays [moves] from [from], or null when it does not play
/// all of them.
NodePath? pathPlaying(GameTree tree, NodePath from, Iterable<PvMove> moves) {
  var path = from;
  for (final move in moves) {
    final children = path.isRoot
        ? tree.children
        : tree.nodeAt(path)?.children ?? const <MoveNode>[];
    final index = children.indexWhere((child) => child.uci == move.uci);
    if (index < 0) return null;
    path = path.child(index);
  }
  return path;
}
