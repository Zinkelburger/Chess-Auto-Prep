import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_tree.dart';

/// The document open in the workspace and where the user is in it.
///
/// Holds two things: the chapter (an immutable value) and the cursor. The
/// board, the move list and every panel derive what they show from these;
/// nothing else in the workspace keeps a copy of the tree or the position.
final class DocumentSession extends ChangeNotifier {
  Chapter? _chapter;
  NodePath _cursor = const NodePath.root();

  Chapter? get chapter => _chapter;

  GameTree? get tree => _chapter?.tree;

  NodePath get cursor => _cursor;

  Fen get fen => tree?.fenAt(_cursor) ?? Fen.initial;

  Side get orientation => _chapter?.side ?? Side.white;

  /// The move the cursor is on; null at the root.
  MoveNode? get currentMove => tree?.nodeAt(_cursor);

  void open(Chapter chapter) {
    _chapter = chapter;
    _cursor = const NodePath.root();
    notifyListeners();
  }

  /// Moves the cursor; a path that is not in the tree is ignored.
  void goTo(NodePath path) {
    final tree = this.tree;
    if (tree == null || path == _cursor) return;
    if (!path.isRoot && tree.nodeAt(path) == null) return;
    _cursor = path;
    notifyListeners();
  }

  void forward() => goTo(_cursor.mainChild);

  void back() => goTo(_cursor.parent);

  void toStart() => goTo(const NodePath.root());

  void toEnd() {
    final tree = this.tree;
    if (tree != null) goTo(tree.endOfLineFrom(_cursor));
  }
}
