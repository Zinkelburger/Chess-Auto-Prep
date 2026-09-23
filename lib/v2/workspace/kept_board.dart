import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_tree.dart';

/// The analysis board as the [DocumentSession] keeps it: its moves, where
/// the user was on it, and its earlier versions for undo. No file holds any
/// of this, so it lives as long as the window, and a file opened in its
/// place leaves it here to go back to.
///
/// Only the session touches it; it is a part of the session's state, kept
/// apart so the session's own fields stay about the document that is up.
final class KeptBoard {
  KeptBoard(this.chapter);

  /// How many edits undo can take back.
  static const undoDepth = 200;

  /// The board as last seen: current while the board is up only after
  /// [DocumentSession] puts it aside.
  Chapter chapter;

  NodePath cursor = const NodePath.root();

  /// Earlier versions of the board, newest last.
  final _undo = <Chapter>[];

  bool get canUndo => _undo.isNotEmpty;

  /// A new board in place of this one, with the cursor at the end of its
  /// main line and nothing to undo.
  void restart(Chapter board) {
    chapter = board;
    cursor = board.tree.endOfLineFrom(const NodePath.root());
    _undo.clear();
  }

  /// [before] is the version an edit just replaced.
  void remember(Chapter before) {
    _undo.add(before);
    if (_undo.length > undoDepth) _undo.removeAt(0);
  }

  /// The version before the last edit, or null when there is none.
  Chapter? takeBack() => _undo.isEmpty ? null : _undo.removeLast();
}
