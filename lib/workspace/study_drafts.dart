import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_line.dart';
import '../chess/pgn/game_summary.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart' show numberedMoves;
import '../chess/pgn/study.dart';
import '../chess/pgn/tree_edit.dart' show lineTree;
import 'document_session.dart';

/// What the board holds, as chapters on their way into a study: the game
/// with its notes, variations and unsaved moves, or one line of it.

/// The game on the board as it stands, called by its players; the analysis
/// board as it is, called by nothing (the study then numbers it). Null with
/// nothing on the board.
ChapterDraft? gameDraft(DocumentSession session) {
  final chapter = session.chapter;
  if (chapter == null) return null;
  final line = _lineOnBoard(chapter);
  return ChapterDraft(
    name: line == null ? '' : summarizeGame(line, index: 0).title,
    orientation: session.orientation,
    moves: chapter.tree,
    tags: line?.tags ?? const [],
    result: line?.terminator,
  );
}

/// The line through the move at [path] — from the start, through it, and
/// on along its main continuation — as a chapter of its own: the moves
/// alone, the way a copied line reads. Called `White – Black, 12...Nf6`
/// after the move it was asked from.
ChapterDraft? lineDraft(DocumentSession session, NodePath path) {
  final tree = session.tree;
  final node = tree?.nodeAt(path);
  if (tree == null || node == null) return null;
  final sans = [
    for (final move in tree.lineTo(tree.endOfLineFrom(path))) move.san,
  ];
  final line = _lineOnBoard(session.chapter!);
  final move = numberedMoves([node]);
  return ChapterDraft(
    name: line == null ? move : '${summarizeGame(line, index: 0).title}, $move',
    orientation: session.orientation,
    moves: lineTree(tree.rootFen, sans),
  );
}

/// The game of the file the board shows, when it shows one game of it.
ChapterLine? _lineOnBoard(Chapter chapter) {
  final game = chapter.game;
  if (game == null)
    return chapter.lines.length == 1 ? chapter.lines.single : null;
  return game >= chapter.lines.length ? null : chapter.lines[game];
}
