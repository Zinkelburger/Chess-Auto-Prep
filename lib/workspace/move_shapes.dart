import 'package:dartchess/dartchess.dart' show Move, NormalMove;

import '../chess/pgn/board_shapes.dart';
import '../chess/pgn/comment_edits.dart';
import 'document_session.dart';
import 'engine_analysis.dart';

/// The arrows and circles the workspace board shows: those in the comment
/// on the move under the cursor — the chapter's introduction at the start —
/// and the engine's threat, in red, while it is for the position shown.
///
/// A comment's shapes are for the position after its move, so they are not
/// drawn over a comment's line. Neither they nor the threat are drawn while
/// part of the game is hidden: a puzzle's or a solitaire game's arrows
/// would give its answer away.
List<BoardShape> shapesOnBoard(DocumentSession session, Threat? threat) {
  final hidden = session.shownTo != null;
  final onMove = session.commentLine.value == null && !hidden;
  final threatMove = hidden || threat == null || threat.fen != session.boardFen
      ? null
      : Move.parse(threat.uci);
  return [
    if (onMove) ...shapesIn(session.commentAt(session.cursor)),
    if (threatMove case NormalMove(:final from, :final to))
      BoardShape(from, to, ShapeColour.red),
  ];
}

/// Whether a shape drawn on the board is written into the move's comment,
/// or stays on the board until the position changes: written where the
/// document takes edits as they are made, and in the viewer, which holds
/// its edits until saved, only while [editing].
bool drawsIntoComment(DocumentSession session, {required bool editing}) =>
    session.chapter != null &&
    session.readOnly == null &&
    session.commentLine.value == null &&
    session.shownTo == null &&
    (editing || !session.holdsEdits);

/// Draws [shape] over the shapes in the comment on the move under the
/// cursor, through the session's one edit path: drawn again it goes, in
/// another colour it is recoloured.
void drawIntoComment(DocumentSession session, BoardShape shape) {
  final at = session.cursor;
  session.apply((chapter) {
    final comment = at.isRoot
        ? chapter.tree.rootComment
        : chapter.tree.nodeAt(at)?.comment;
    final shapes = withShapeDrawn(shapesIn(comment), shape);
    return setShapes(chapter, at: at, shapes: shapes);
  });
}
