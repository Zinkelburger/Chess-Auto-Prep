import 'game_tree.dart';

/// PGN movetext for [tree], ending with [result] as the game-termination
/// marker: the comment before the first move, then the moves with their
/// variations in parentheses, mainline first.
///
/// One line, however long, because that is what the old app writes and what
/// every reader of a chapter file already handles; it also keeps a one-move
/// edit a one-line diff.
///
/// A chapter only writes the games an edit touched; the rest keep their own
/// bytes. So a regenerated game is normalised to what the tree models, and
/// two things do not survive the trip: a `;` comment is already gone before
/// this sees it, since the reader keeps `{}` comments only; and a glyph the
/// file wrote as `!?` comes back as its numeric annotation, `$5`.
String writeMoveText(GameTree tree, {required String result}) {
  final buffer = StringBuffer();
  final comment = tree.rootComment;
  if (comment != null && comment.isNotEmpty) {
    buffer.write('{${_sanitised(comment)}} ');
  }
  _writeNodes(
    buffer,
    tree.children,
    tree.rootFen.fullMove,
    tree.rootFen.whiteToMove,
    startsLine: true,
  );
  buffer.write(result);
  return buffer.toString();
}

/// A comment body that cannot break out of its `{}` block.
///
/// Only `}` ends a comment, so only `}` is dropped; comments do not nest and
/// a `{` inside one is ordinary text that every PGN reader keeps.
String _sanitised(String comment) => comment.replaceAll('}', '');

void _writeNodes(
  StringBuffer buffer,
  List<MoveNode> siblings,
  int moveNumber,
  bool isWhite, {
  bool startsLine = false,
}) {
  if (siblings.isEmpty) return;
  final main = siblings.first;
  _writeMove(
    buffer,
    main,
    moveNumber,
    isWhite,
    numbered: isWhite || startsLine,
  );

  final next = isWhite ? moveNumber : moveNumber + 1;
  for (final variation in siblings.skip(1)) {
    // Written aside so the closing bracket follows the last move directly,
    // the way a hand-written variation reads.
    final inner = StringBuffer();
    _writeMove(inner, variation, moveNumber, isWhite, numbered: true);
    _writeNodes(inner, variation.children, next, !isWhite);
    buffer.write('(${inner.toString().trimRight()}) ');
  }
  _writeNodes(buffer, main.children, next, !isWhite);
}

/// One move: the comment written before it, its number when [numbered], the
/// SAN, its NAGs and the comment written after it.
void _writeMove(
  StringBuffer buffer,
  MoveNode node,
  int moveNumber,
  bool isWhite, {
  required bool numbered,
}) {
  final starting = node.startingComment;
  if (starting != null && starting.isNotEmpty) {
    buffer.write('{${_sanitised(starting)}} ');
  }
  if (numbered) buffer.write(isWhite ? '$moveNumber. ' : '$moveNumber... ');
  buffer.write('${node.san} ');
  for (final nag in node.nags) {
    buffer.write('\$$nag ');
  }
  final comment = node.comment;
  if (comment != null && comment.isNotEmpty) {
    buffer.write('{${_sanitised(comment)}} ');
  }
}
