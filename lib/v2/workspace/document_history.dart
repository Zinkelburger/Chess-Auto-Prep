import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/game_tree.dart';
import '../storage/edit_scope.dart';
import 'document_projection.dart';

typedef ShownDocument = ({Chapter chapter, SectionView? view});

/// Edits to a file the session shows but has not written: the
/// file as it was before them, the text and scope of all of them together,
/// and each version they replaced, for undo.
final class HeldEdits {
  HeldEdits(this.original, Landing first)
    : text = first.text,
      scope = first.scope,
      _versions = [(shown: original, text: null, scope: null)];

  /// What was on the board before the first edit: the file as on disk.
  final ShownDocument original;

  String text;
  EditScope scope;

  /// The versions the edits replaced, newest last, each with the text and
  /// scope that had been held up to it (null for the original).
  final List<({ShownDocument shown, String? text, EditScope? scope})> _versions;

  bool get isEmpty => _versions.isEmpty;

  /// One more edit, [landed], made to [before].
  void add(ShownDocument before, Landing landed) {
    _versions.add((shown: before, text: text, scope: scope));
    text = landed.text;
    scope = scopeOfBoth(scope, landed.scope);
  }

  /// The version before the last edit, with what was held up to it.
  ShownDocument takeBack() {
    final last = _versions.removeLast();
    if (last.text case final earlier?) text = earlier;
    if (last.scope case final earlier?) scope = earlier;
    return last.shown;
  }
}

/// The analysis board as the session keeps it: its moves, where
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
  /// the session puts it aside.
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
