/// Queries and edits over the PGN viewer's sidelines.
///
/// The viewer keeps sidelines as a [SidelineForest]: for each mainline ply,
/// the roots of the variations that branch there, each a [MoveNode] subtree.
/// These helpers are the tree walks every mutation on that forest needs —
/// locating a node, its ancestry, and its scratch (ephemeral) descendants —
/// kept out of [ViewerGameModel] so the model reads as game logic, not
/// recursion.
library;

import '../../models/move_tree.dart';

/// Sidelines keyed by the 0-based mainline ply they branch from: key `p`
/// holds alternatives to the mainline move at index `p`.
typedef SidelineForest = Map<int, List<MoveNode>>;

/// Where [SidelineForestEdits.removeNode] found the node it deleted.
typedef RemovedSidelineNode = ({int branchPly, bool wasRoot});

/// Subtree walks over a single sideline node.
extension MoveNodeSubtree on MoveNode {
  /// This node's root-first path down to [target] (both inclusive), matched
  /// by [MoveNode.id]; null when [target] is not in this subtree.
  List<MoveNode>? pathTo(MoveNode target) => _pathTo(target, const []);

  List<MoveNode>? _pathTo(MoveNode target, List<MoveNode> prefix) {
    final path = [...prefix, this];
    if (id == target.id) return path;
    for (final child in children) {
      final found = child._pathTo(target, path);
      if (found != null) return found;
    }
    return null;
  }

  /// The node with [targetId] in this subtree (this node included), or null.
  MoveNode? findById(int targetId) {
    if (id == targetId) return this;
    for (final child in children) {
      final hit = child.findById(targetId);
      if (hit != null) return hit;
    }
    return null;
  }

  /// Whether this node or any descendant is a scratch (ephemeral) move.
  bool get subtreeHasEphemeral =>
      isEphemeral || children.any((c) => c.subtreeHasEphemeral);

  /// Drop every ephemeral descendant, leaving this node itself alone.
  void removeEphemeralDescendants() {
    children.removeWhere((c) => c.isEphemeral);
    for (final child in children) {
      child.removeEphemeralDescendants();
    }
  }

  /// Detach the child with [targetId] from wherever it sits below this node.
  /// Returns whether it was found.
  bool removeDescendant(int targetId) {
    final before = children.length;
    children.removeWhere((c) => c.id == targetId);
    if (children.length < before) return true;
    return children.any((c) => c.removeDescendant(targetId));
  }
}

/// Read-only walks over the whole forest.
extension SidelineForestQueries on SidelineForest {
  /// Root-first path from one of this forest's roots down to [target], or
  /// null when [target] lives nowhere in it. Restricted to the roots at
  /// [branchPly] when given.
  List<MoveNode>? pathToNode(MoveNode target, {int? branchPly}) {
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
  MoveNode? findNodeById(int id) {
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
