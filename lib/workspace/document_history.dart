import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/game_tree.dart';
import '../storage/edit_scope.dart';
import '../storage/document_ref.dart';
import 'document_projection.dart';

typedef ShownDocument = ({Chapter chapter, SectionView? view});

/// Edits to a file the session shows but has not written: the
/// file as it was before them, the text and scope of all of them together,
/// and each version they replaced, for undo.
final class HeldEdits {
  HeldEdits(this.original, Landing first)
    : _current = (chapter: first.chapter, view: first.view),
      scope = first.scope,
      _versions = [(shown: original, scope: null)];

  static const undoDepth = 100;

  /// Discard always returns here, even after older undo steps were dropped.
  final ShownDocument original;
  ShownDocument _current;
  EditScope scope;
  bool _atOriginal = false;

  /// Serialize on demand, never once per retained undo step. Unchanged games
  /// are shared by the immutable document versions.
  String get text => writeChapter(_current.view?.file ?? _current.chapter);

  final List<({ShownDocument shown, EditScope? scope})> _versions;

  bool get canUndo => _versions.isNotEmpty;
  bool get isEmpty => _atOriginal;

  void add(ShownDocument before, Landing landed) {
    _versions.add((shown: before, scope: scope));
    if (_versions.length > undoDepth) _versions.removeAt(0);
    _current = (chapter: landed.chapter, view: landed.view);
    scope = scopeOfBoth(scope, landed.scope);
    _atOriginal = false;
  }

  ShownDocument takeBack() {
    final last = _versions.removeLast();
    _current = last.shown;
    _atOriginal = last.scope == null;
    if (last.scope case final earlier?) scope = earlier;
    return _current;
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

/// How held edits left the session: written to their file, thrown away by
/// the user, or dropped when another document, or another reading of the
/// same file, was put up in their place. Only the first two retire their
/// checkpoint and their tab's copy.
enum HeldEditsEnded { kept, discarded, dropped }

/// A viewer draft parked in a document tab, including its save precondition.
final class RetainedDraft {
  const RetainedDraft({
    required this.shown,
    required this.held,
    required this.revision,
  });
  final ShownDocument shown;
  final HeldEdits held;
  final Revision revision;
}
