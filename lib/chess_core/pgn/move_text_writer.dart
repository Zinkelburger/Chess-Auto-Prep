import '../moves/move_tree_view.dart';

/// Movetext (no headers, no result token) for [roots] played from a
/// position with [startMoveNumber] and [startIsWhite] to move, preceded
/// by [rootComment] when there is one.  Variations are written in PGN's
/// parenthesised form, mainline first.
String writeMoveText({
  required List<MoveNodeView> roots,
  required int startMoveNumber,
  required bool startIsWhite,
  String? rootComment,
}) {
  final buffer = StringBuffer();
  if (rootComment != null) {
    buffer.write('{${sanitizePgnComment(rootComment)}} ');
  }
  if (roots.isNotEmpty) {
    _writeNodes(
      buffer,
      roots,
      startMoveNumber,
      startIsWhite,
      isFirstMove: true,
    );
  }
  return buffer.toString().trim();
}

/// A comment body that cannot break out of its `{}` block.
String sanitizePgnComment(String comment) =>
    comment.replaceAll('{', '').replaceAll('}', '');

void _writeNodes(
  StringBuffer buffer,
  List<MoveNodeView> siblings,
  int moveNumber,
  bool isWhite, {
  bool isFirstMove = false,
}) {
  if (siblings.isEmpty) return;

  final main = siblings[0];
  _writeMove(
    buffer,
    main,
    moveNumber,
    isWhite,
    numbered: isWhite || isFirstMove,
  );

  final nextMoveNumber = isWhite ? moveNumber : moveNumber + 1;
  for (final variant in siblings.skip(1)) {
    buffer.write('(');
    _writeMove(buffer, variant, moveNumber, isWhite, numbered: true);
    _writeNodes(buffer, variant.children, nextMoveNumber, !isWhite);
    buffer.write(') ');
  }

  _writeNodes(buffer, main.children, nextMoveNumber, !isWhite);
}

/// One move with its starting comment, number indicator (`3.` / `3...`
/// when [numbered]), NAGs and trailing comment.
void _writeMove(
  StringBuffer buffer,
  MoveNodeView node,
  int moveNumber,
  bool isWhite, {
  required bool numbered,
}) {
  final starting = node.startingComment;
  if (starting != null && starting.isNotEmpty) {
    buffer.write('{${sanitizePgnComment(starting)}} ');
  }
  if (numbered) {
    buffer.write(isWhite ? '$moveNumber. ' : '$moveNumber... ');
  }
  buffer.write('${node.san} ');
  for (final nag in node.nags ?? const <int>[]) {
    buffer.write('\$$nag ');
  }
  final comment = node.comment;
  if (comment != null && comment.isNotEmpty) {
    buffer.write('{${sanitizePgnComment(comment)}} ');
  }
}
