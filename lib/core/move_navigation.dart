/// Shared move-tree cursor navigation.
///
/// Implementors supply [tree], [path], and [jump] (which may do extra work
/// such as syncing derived state); the directional helpers are defined in
/// terms of those. Adopted by `RepertoireController` and `StudyController`,
/// which both hold exactly a [MoveTree] plus a [TreePath] cursor.
///
/// Deliberately NOT adopted elsewhere — the other navigation code in this app
/// only looks similar. Nothing below is a missed migration:
///
///  * `pgn/viewer_opening_tree.dart` walks an `OpeningTree`: a
///    transposition-merged graph with its own `currentNode`, where "forward"
///    means the most-played continuation across merged nodes, not `children[0]`.
///  * `PgnViewerController.navigateToStart/End` is a dispatcher over three
///    modes (solitaire / opening-tree / plain PGN) that delegates outward
///    rather than moving a cursor of its own.
///  * `tactics/tactics_solution_navigator.dart` indexes a flat SAN solution
///    list and drives the PGN widget; it has no tree.
///  * `TrainingSessionController` owns a `RepertoireController` and navigates
///    through it, so it inherits this mixin's behaviour already.
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
    final children = path.isEmpty
        ? tree.roots
        : (tree.nodeAt(path)?.children ?? const []);
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
