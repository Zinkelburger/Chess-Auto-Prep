/// Flat, reference-free encoding of an [OpeningTree] for isolate transfer.
///
/// [OpeningTreeNode] has cyclic parent references which Dart's `SendPort`
/// cannot transfer.  The tree is flattened into a list of maps keyed by
/// integer ids so it can cross the isolate boundary, and parent/child
/// pointers are rebuilt on the receiving side.
library;

import 'dart:collection';

import 'opening_tree.dart';

/// Encodes and decodes the map shape [OpeningTree.toTransferJson] produces.
abstract final class OpeningTreeTransfer {
  /// The tree as a JSON-compatible map containing only primitives, lists and
  /// maps.  Ids are assigned breadth-first from the root, then from each
  /// setup root.
  static Map<String, dynamic> encode(OpeningTree tree) {
    final nodes = <Map<String, dynamic>>[];
    final nodeToId = <OpeningTreeNode, int>{};

    final queue = Queue<OpeningTreeNode>()..add(tree.root);
    nodeToId[tree.root] = 0;
    for (final setupRoot in tree.setupRoots) {
      nodeToId[setupRoot] = nodeToId.length;
      queue.add(setupRoot);
    }

    while (queue.isNotEmpty) {
      final node = queue.removeFirst();
      final id = nodeToId[node]!;

      final childIds = <String, int>{};
      for (final entry in node.children.entries) {
        final childNode = entry.value;
        childIds[entry.key] = nodeToId.putIfAbsent(childNode, () {
          final nextId = nodeToId.length;
          queue.add(childNode);
          return nextId;
        });
      }

      final parent = node.parent;
      nodes.add({
        'id': id,
        'parentId': parent == null ? -1 : nodeToId[parent] ?? -1,
        'move': node.move,
        'fen': node.fen,
        'gamesPlayed': node.gamesPlayed,
        'wins': node.wins,
        'losses': node.losses,
        'draws': node.draws,
        'childIds': childIds,
      });
    }

    // The FEN index is derivable from the nodes — every node is indexed under
    // its own FEN — so it is rebuilt on receipt rather than shipped: sending
    // it doubled every FEN in the message.
    return {'nodes': nodes, 'preserveSetupRoots': tree.preserveSetupRoots};
  }

  /// Rebuilds the tree [encode] flattened.
  ///
  /// Node ids were assigned in BFS order, so indexing in id order files each
  /// FEN's nodes shallowest-first — *not* the depth-first order the builder's
  /// walk produced them in.  Both are legitimate: a FEN's node list is a set
  /// of transposing paths, and the only thing that reads its order is
  /// [PositionGroup.primaryNode], which picks the most-played path and is
  /// therefore free to break a tie either way.
  static OpeningTree decode(Map<String, dynamic> json) {
    final rawNodes = (json['nodes'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final builtNodes = <int, OpeningTreeNode>{};

    // First pass: create all nodes without parent/child links.
    for (final m in rawNodes) {
      builtNodes[m['id'] as int] = OpeningTreeNode(
        move: m['move'] as String,
        fen: m['fen'] as String,
        gamesPlayed: m['gamesPlayed'] as int,
        wins: m['wins'] as int,
        losses: m['losses'] as int,
        draws: m['draws'] as int,
      );
    }

    // Second pass: wire up parent + children pointers.
    for (final m in rawNodes) {
      final node = builtNodes[m['id'] as int]!;
      final parentId = m['parentId'] as int;
      if (parentId >= 0) {
        node.parent = builtNodes[parentId];
      }
      final childIds = m['childIds'] as Map<String, dynamic>;
      for (final entry in childIds.entries) {
        node.children[entry.key] = builtNodes[entry.value as int]!;
      }
    }

    final tree = OpeningTree(
      root: builtNodes[0],
      preserveSetupRoots: json['preserveSetupRoots'] as bool? ?? false,
    );
    for (var id = 1; id < rawNodes.length; id++) {
      final node = builtNodes[id];
      if (node != null) {
        tree.indexNode(node);
        if (node.parent == null) tree.setupRoots.add(node);
      }
    }
    return tree;
  }
}
