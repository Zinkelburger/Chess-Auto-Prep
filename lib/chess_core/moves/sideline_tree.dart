/// Queries and edits over the PGN viewer's sidelines.
///
/// The viewer keeps sidelines as a [SidelineForest]: for each mainline ply,
/// the roots of the variations that branch there, each a [MoveNode] subtree.
/// These helpers are the tree walks every mutation on that forest needs —
/// locating a node, its ancestry, and its scratch (ephemeral) descendants —
/// kept out of [ViewerGameController] so the model reads as game logic, not
/// recursion.
library;

import '../../models/move_tree.dart';
import 'move_tree_view.dart';

/// Sidelines keyed by the 0-based mainline ply they branch from: key `p`
/// holds alternatives to the mainline move at index `p`.
typedef SidelineForest = Map<int, List<MoveNode>>;

/// Where [SidelineForestEdits.removeNode] found the node it deleted.
typedef RemovedSidelineNode = ({int branchPly, bool wasRoot});

/// Iterative queries shared by mutable owners and detached snapshots.
extension MoveNodeSubtree on MoveNodeView {
  /// Root-first path to [target], matched by stable node ID.
  List<MoveNodeView>? pathTo(MoveNodeView target) => pathToId(target.id);

  List<MoveNodeView>? pathToId(int targetId) {
    final path = <MoveNodeView>[];
    final pending = [(this, false)];
    while (pending.isNotEmpty) {
      final (node, leaving) = pending.removeLast();
      if (leaving) {
        path.removeLast();
        continue;
      }
      path.add(node);
      if (node.id == targetId) return path;
      pending.add((node, true));
      for (final child in node.children.reversed) {
        pending.add((child, false));
      }
    }
    return null;
  }

  MoveNodeView? findById(int targetId) {
    final pending = [this];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node.id == targetId) return node;
      pending.addAll(node.children.reversed);
    }
    return null;
  }

  bool get subtreeHasEphemeral {
    final pending = [this];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node.isEphemeral) return true;
      pending.addAll(node.children);
    }
    return false;
  }
}

/// Only the private mutable owner may edit trees.
extension MutableMoveNodeSubtree on MoveNode {
  void removeEphemeralDescendants() {
    final pending = [this];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      node.children.removeWhere((child) => child.isEphemeral);
      pending.addAll(node.children);
    }
  }

  bool removeDescendant(int targetId) {
    final pending = [this];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      final before = node.children.length;
      node.children.removeWhere((child) => child.id == targetId);
      if (node.children.length != before) return true;
      pending.addAll(node.children.reversed);
    }
    return false;
  }
}

/// Read-only walks over the whole forest.
extension SidelineForestQueries on Map<int, List<MoveNodeView>> {
  /// Root-first path from one of this forest's roots down to [target], or
  /// null when [target] lives nowhere in it. Restricted to the roots at
  /// [branchPly] when given.
  List<MoveNodeView>? pathToNode(MoveNodeView target, {int? branchPly}) {
    final rootLists = branchPly == null ? values : [?this[branchPly]];
    for (final roots in rootLists) {
      for (final root in roots) {
        final path = root.pathTo(target);
        if (path != null) return path;
      }
    }
    return null;
  }

  /// The node with [id], wherever it lives; null when absent.
  MoveNodeView? findNodeById(int id) {
    for (final roots in values) {
      for (final root in roots) {
        final hit = root.findById(id);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// Whether any root holds a scratch (ephemeral) move.
  bool get hasEphemeral =>
      values.any((roots) => roots.any((r) => r.subtreeHasEphemeral));
}

/// Mutations over the whole forest.
extension SidelineForestEdits on SidelineForest {
  /// Drop every ephemeral node — scratch roots and scratch descendants of
  /// saved roots — and forget plies left without any sideline.
  void removeEphemeral() {
    for (final roots in values) {
      roots.removeWhere((r) => r.isEphemeral);
      for (final root in roots) {
        root.removeEphemeralDescendants();
      }
    }
    removeWhere((_, roots) => roots.isEmpty);
  }

  /// Detach the node with [nodeId], wherever it lives, together with its
  /// subtree. Reports where it was found, or null when it was not.
  RemovedSidelineNode? removeNode(int nodeId) {
    for (final MapEntry(key: ply, value: roots) in entries) {
      final before = roots.length;
      roots.removeWhere((r) => r.id == nodeId);
      if (roots.length < before) return (branchPly: ply, wasRoot: true);
      if (roots.any((r) => r.removeDescendant(nodeId))) {
        return (branchPly: ply, wasRoot: false);
      }
    }
    return null;
  }
}
