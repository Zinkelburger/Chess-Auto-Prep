/// Shared move-tree cursor navigation.
///
/// The repertoire, PGN-viewer, training, and tactics controllers each
/// re-implemented goBack/goForward/goToStart/goToEnd over a [MoveTree] + a
/// [TreePath] cursor. This mixin provides that one implementation. Implementors
/// supply [tree], [path], and [jump] (which may do extra work such as syncing
/// derived state); the directional helpers are defined in terms of those.
library;

import '../models/move_tree.dart';

mixin MoveNavigation {
  /// The move tree being navigated.
  MoveTree get tree;

  /// The current cursor.
  TreePath get path;

  /// Move the cursor to [target]. Implementors define this (it typically also
  /// notifies listeners and syncs any derived state).
  void jump(TreePath target);

  /// Step back one ply toward the root. No-op at the start position.
  void goBack() {
    if (path.isNotEmpty) jump(path.parent);
  }

  /// Step forward along the mainline (`children[0]`). No-op at a leaf.
  void goForward() {
    final children =
        path.isEmpty ? tree.roots : (tree.nodeAt(path)?.children ?? const []);
    if (children.isNotEmpty) jump(path.child(0));
  }

  /// Jump to the start position.
  void goToStart() => jump(TreePath.empty);

  /// Jump to the end of the mainline from the current cursor.
  void goToEnd() {
    if (tree.isEmpty) return;
    jump(tree.mainlineEndFrom(path));
  }
}
