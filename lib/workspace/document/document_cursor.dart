part of 'document_session.dart';

/// Where the reader is in the document on screen: the move the cursor is on,
/// and a line read out of a comment, shown on the board in its place.
///
/// It notifies for its own moves only, the cursor's as a
/// `ValueListenable<NodePath>` and the comment line's apart; the session
/// notifies for the document. Moving the cursor puts the board back on the
/// file. Only the session puts the cursor on a path it has not checked: one
/// it found in the document it just put up.
final class DocumentCursor implements ValueListenable<NodePath> {
  DocumentCursor._(this._tree, this._shownTo) {
    _path.addListener(closeCommentLine);
  }

  /// The move tree of the document on screen, read at every step.
  final GameTree? Function() _tree;

  /// The session's [DocumentSession.shownTo]: the cursor cannot pass it.
  final NodePath? Function() _shownTo;

  final _path = ValueNotifier<NodePath>(const NodePath.root());
  final _commentLine = ValueNotifier<CommentLine?>(null);

  /// The move the cursor is on; the root before the first move.
  @override
  NodePath get value => _path.value;

  /// Notifies when the cursor moves, and only then.
  @override
  void addListener(VoidCallback listener) => _path.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _path.removeListener(listener);

  /// Puts the cursor on [path] as it is: the session's, for the document it
  /// just put up or changed.
  void _place(NodePath path) => _path.value = path;

  /// The move the cursor is on; null at the root.
  MoveNode? get currentMove => _tree()?.nodeAt(value);

  /// The position of the file at the cursor.
  Fen get fen => _tree()?.fenAt(value) ?? Fen.initial;

  /// A line written in a comment, shown on the board in place of the
  /// cursor's position; null otherwise. None of it is in the file: the cursor
  /// stays on the comment's move, the board takes no moves, and moving in or
  /// changing the file puts the board back on it.
  ValueListenable<CommentLine?> get commentLine => _commentLine;

  /// The position on the board: the comment line's while one is shown.
  Fen get boardFen => _commentLine.value?.fen ?? fen;

  /// The move that reached [boardFen], as UCI, for the highlight.
  String? get boardLastMove => _commentLine.value?.move.uci ?? currentMove?.uci;

  /// Reads the line written in a comment on the move at [from], as far as
  /// its move at [at]. When the file already plays those moves from there,
  /// the cursor follows them instead; otherwise the board shows the line
  /// and the file is left as it is.
  void showCommentLine(NodePath from, List<PvMove> moves, int at) {
    final tree = _tree();
    if (tree == null || _shownTo() != null) return;
    if (!from.isRoot && tree.nodeAt(from) == null) return;
    final inFile = pathPlaying(tree, from, moves.take(at + 1));
    if (inFile != null) {
      closeCommentLine();
      _path.value = inFile;
      return;
    }
    _path.value = from;
    _commentLine.value = CommentLine(from: from, moves: moves, at: at);
  }

  /// Puts the board back on the file's position.
  void closeCommentLine() => _commentLine.value = null;

  /// Moves the cursor; a path not in the tree is ignored. Going to the move
  /// the cursor is already on still puts the board back on the file.
  void goTo(NodePath path) {
    final tree = _tree();
    if (path == value) closeCommentLine();
    if (tree == null || path == value) return;
    if (!path.isRoot && tree.nodeAt(path) == null) return;
    if (_shownTo() case final limit? when !limit.startsWith(path)) return;
    _path.value = path;
  }

  /// The next move of the file, or of the comment line on the board.
  void forward() {
    if (_commentLine.value case final line?) {
      if (line.at + 1 < line.moves.length) {
        _commentLine.value = line.atMove(line.at + 1);
      }
      return;
    }
    goTo(value.mainChild);
  }

  /// The move before in the file; while a comment line is on the board, its
  /// move before, and from its first move back to the file.
  void back() {
    if (_commentLine.value case final line?) {
      _commentLine.value = line.at == 0 ? null : line.atMove(line.at - 1);
      return;
    }
    goTo(value.parent);
  }

  void toStart() => goTo(const NodePath.root());

  /// Steps into the first variation that branches off where the cursor is:
  /// the move played instead of the main continuation. Whether there was
  /// one to step into.
  bool enterVariation() {
    final variation = value.child(1);
    if (_tree()?.nodeAt(variation) == null) return false;
    goTo(variation);
    return value == variation;
  }

  /// Back out of the variation the cursor is in, to the move of the line
  /// it branches from. Whether the cursor was in one.
  bool leaveVariation() {
    final branch = value.branchPoint;
    if (branch == null) return false;
    goTo(branch);
    return value == branch;
  }

  void toEnd() {
    final tree = _tree();
    if (tree != null) goTo(tree.endOfLineFrom(value));
  }

  void _dispose() {
    _path.dispose();
    _commentLine.dispose();
  }
}
