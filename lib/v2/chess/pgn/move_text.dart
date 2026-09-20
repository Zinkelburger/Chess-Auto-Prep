import 'game_tree.dart';

/// PGN movetext for [tree], ending with [terminator] as the game-termination
/// marker, or with no marker when the game had none.
///
/// One line, however long, because that is what the old app writes and what
/// every reader of a chapter file already handles; it also keeps a one-move
/// edit a one-line diff.
///
/// **The canonical form.** A chapter only writes the games an edit touched;
/// the rest keep their own bytes. What a rewritten game keeps: the SAN
/// exactly as the file spelled it, every comment's text, the order of the
/// moves and variations, the NAG numbers, the termination marker. What it
/// normalises, each of which reads back as the same game:
///
/// * move numbers are written where a reader needs them — before White's
///   move and at the start of a variation — and dropped everywhere else, so
///   a course that numbered Black's ply `5.` comes back numbered `5...`;
/// * several comments on one move join into one, `{a} {b}` into `{a b}`;
/// * a `;` comment becomes a `{}` comment;
/// * a symbolic annotation comes back as its number, `!?` as `$5`;
/// * `e.p.`, an empty `()` and a `)` that opened nothing are dropped;
/// * a termination marker written in the middle moves to the end.
///
/// A comment is written exactly as it is held, `}` included. A `}` cannot be
/// written inside `{}` and there is no escape for it in PGN, so the game
/// will not read back as itself and `safeGameText` refuses the rewrite; the
/// text is never quietly thrown away.
String writeMoveText(GameTree tree, {required String? terminator}) {
  final buffer = StringBuffer();
  final comment = tree.rootComment;
  if (comment != null && comment.isNotEmpty) buffer.write('{$comment} ');
  _writeLine(
    buffer,
    tree.children,
    tree.rootFen.fullMove,
    tree.rootFen.whiteToMove,
    startsLine: true,
  );
  final moves = buffer.toString();
  return terminator == null ? moves.trimRight() : '$moves$terminator';
}

/// The main continuation of [children] and, after each of its moves, the
/// variations that replace it.
///
/// A loop down the main line and recursion only into variations: a game's
/// main line is as long as the game, and two thousand plies must not be two
/// thousand stack frames. Real files nest variations three deep at most.
void _writeLine(
  StringBuffer buffer,
  List<MoveNode> children,
  int moveNumber,
  bool whiteToMove, {
  bool startsLine = false,
}) {
  var siblings = children;
  var number = moveNumber;
  var white = whiteToMove;
  var first = startsLine;
  while (siblings.isNotEmpty) {
    final main = siblings.first;
    _writeMove(buffer, main, number, white, numbered: white || first);
    final next = white ? number : number + 1;
    for (final variation in siblings.skip(1)) {
      // Written aside so the closing bracket follows the last move directly,
      // the way a hand-written variation reads.
      final inner = StringBuffer();
      _writeMove(inner, variation, number, white, numbered: true);
      _writeLine(inner, variation.children, next, !white);
      buffer.write('(${inner.toString().trimRight()}) ');
    }
    siblings = main.children;
    number = next;
    white = !white;
    first = false;
  }
}

/// One move: the comment written before it, its number when [numbered], the
/// SAN as the file spelled it, its NAGs and the comment written after it.
void _writeMove(
  StringBuffer buffer,
  MoveNode node,
  int moveNumber,
  bool isWhite, {
  required bool numbered,
}) {
  final starting = node.startingComment;
  if (starting != null && starting.isNotEmpty) buffer.write('{$starting} ');
  if (numbered) buffer.write(isWhite ? '$moveNumber. ' : '$moveNumber... ');
  buffer.write('${node.spelling ?? node.san} ');
  for (final nag in node.nags) {
    buffer.write('\$$nag ');
  }
  final comment = node.comment;
  if (comment != null && comment.isNotEmpty) buffer.write('{$comment} ');
}
