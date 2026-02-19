/// Opening tree models - Represents a tree of moves from analyzed games
/// Similar to openingtree.com's move explorer functionality
library;

import 'package:dartchess_webok/dartchess_webok.dart';
import '../utils/fen_utils.dart';

class OpeningTreeNode {
  /// The move that led to this node (SAN notation, e.g. "e4", "Nf3")
  /// Empty string for root node
  final String move;

  /// The FEN position after this move was played
  final String fen;

  /// Statistics for games where this move was played
  int gamesPlayed;
  int wins;
  int losses;
  int draws;

  /// Child nodes (next moves from this position)
  /// Key: move in SAN notation
  /// Value: the resulting node
  final Map<String, OpeningTreeNode> children;

  /// Parent node (for navigation back up the tree)
  OpeningTreeNode? parent;

  OpeningTreeNode({
    required this.move,
    required this.fen,
    this.gamesPlayed = 0,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    Map<String, OpeningTreeNode>? children,
    this.parent,
  }) : children = children ?? {};

  /// Calculate win rate (0.0 to 1.0)
  double get winRate {
    if (gamesPlayed == 0) return 0.0;
    return (wins + 0.5 * draws) / gamesPlayed;
  }

  /// Win rate as percentage
  double get winRatePercent => winRate * 100;

  /// Get sorted list of children by number of games played (descending)
  List<OpeningTreeNode> get sortedChildren {
    final childList = children.values.toList();
    childList.sort((a, b) => b.gamesPlayed.compareTo(a.gamesPlayed));
    return childList;
  }

  /// Update statistics with a game result
  /// Result should be from the player's perspective (1.0 = win, 0.5 = draw, 0.0 = loss)
  void updateStats(double result) {
    gamesPlayed++;
    if (result >= 0.9) {
      wins++;
    } else if (result <= 0.1) {
      losses++;
    } else {
      draws++;
    }
  }

  /// Add or get a child node for a move
  OpeningTreeNode getOrCreateChild(String movesan, String resultingFen) {
    if (!children.containsKey(movesan)) {
      children[movesan] = OpeningTreeNode(
        move: movesan,
        fen: resultingFen,
        parent: this,
      );
    }
    return children[movesan]!;
  }

  /// Get path from root to this node (list of moves)
  List<String> getMovePath() {
    final path = <String>[];
    OpeningTreeNode? current = this;

    while (current != null && current.move.isNotEmpty) {
      path.insert(0, current.move);
      current = current.parent;
    }

    return path;
  }

  /// Get the full move path as a string (e.g. "1.e4 e5 2.Nf3 Nc6")
  String getMovePathString() {
    final moves = getMovePath();
    if (moves.isEmpty) return 'Starting position';

    final buffer = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      if (i % 2 == 0) {
        // White's move - add move number
        buffer.write('${(i ~/ 2) + 1}.');
        buffer.write(moves[i]);
        buffer.write(' ');
      } else {
        // Black's move
        buffer.write(moves[i]);
        buffer.write(' ');
      }
    }

    return buffer.toString().trim();
  }

  @override
  String toString() {
    return 'OpeningTreeNode(move: $move, games: $gamesPlayed, children: ${children.length})';
  }
}

/// Opening tree - contains the root node and provides navigation
class OpeningTree {
  late final OpeningTreeNode root;
  late OpeningTreeNode currentNode;

  /// FEN to node mapping for quick lookup
  final Map<String, List<OpeningTreeNode>> fenToNodes;

  OpeningTree({OpeningTreeNode? root, Map<String, List<OpeningTreeNode>>? fenToNodes})
      : fenToNodes = fenToNodes ?? {} {
    // Ensure root and currentNode point to the same object
    final rootNode = root ?? OpeningTreeNode(move: '', fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1');
    this.root = rootNode;
    currentNode = rootNode;
  }

  /// Navigate to a child node by move
  bool makeMove(String move) {
    if (currentNode.children.containsKey(move)) {
      currentNode = currentNode.children[move]!;
      return true;
    }
    return false;
  }

  /// Navigate back to parent node
  bool goBack() {
    if (currentNode.parent != null) {
      currentNode = currentNode.parent!;
      return true;
    }
    return false;
  }

  /// Reset to root position
  void reset() {
    currentNode = root;
  }

  /// Navigate to a specific FEN position (finds the first matching node)
  bool navigateToFen(String fen) {
    final key = normalizeFen(fen);
    final nodes = fenToNodes[key];
    if (nodes != null && nodes.isNotEmpty) {
      currentNode = nodes.first;
      return true;
    }
    return false;
  }

  /// Add a FEN to node mapping
  void indexNode(OpeningTreeNode node) {
    final key = normalizeFen(node.fen);
    (fenToNodes[key] ??= []).add(node);
  }

  /// Get total number of games in the tree (games at root)
  int get totalGames => root.gamesPlayed;

  /// Get current depth in the tree
  int get currentDepth => currentNode.getMovePath().length;

  /// Append a single line of moves to the tree without rebuilding.
  /// Each move is walked node-by-node; new nodes are created as needed.
  void appendLine(List<String> moves) {
    Position position = Chess.initial;
    var node = root;
    node.updateStats(0.5); // repertoire lines have no game result

    for (final san in moves) {
      final move = position.parseSan(san);
      if (move == null) break;
      position = position.play(move);
      node = node.getOrCreateChild(san, position.fen);
      node.updateStats(0.5);
      indexNode(node);
    }
  }

  /// Sync the tree state to match a specific list of moves (SANs)
  /// Returns true if the full path was found in the tree
  bool syncToMoveHistory(List<String> moves) {
    reset(); // Start at root

    for (final move in moves) {
      // Try to make the move
      final success = makeMove(move);

      // If the move doesn't exist in the tree, we stop.
      // We remain at the last known node, which is usually exactly what we want
      // (showing the user they have left the "book" moves).
      if (!success) {
        return false;
      }
    }
    return true;
  }

  // ── Serialisation for isolate transfer ──────────────────────────────
  //
  // OpeningTreeNode has cyclic parent references which Dart's SendPort
  // cannot transfer.  We flatten the tree into a list of maps keyed by
  // integer IDs so it can cross the isolate boundary, then reconstruct
  // parent/child pointers on the receiving side.

  /// Serialise the entire tree into a JSON-compatible map that contains
  /// no object references (only primitives, lists, and maps).
  Map<String, dynamic> toTransferJson() {
    final nodes = <Map<String, dynamic>>[];
    final nodeToId = <OpeningTreeNode, int>{};

    // BFS to assign IDs and serialise each node.
    final queue = <OpeningTreeNode>[root];
    nodeToId[root] = 0;

    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      final id = nodeToId[node]!;

      final childIds = <String, int>{};
      for (final entry in node.children.entries) {
        final childId = nodeToId.length;
        nodeToId[entry.value] = childId;
        childIds[entry.key] = childId;
        queue.add(entry.value);
      }

      nodes.add({
        'id': id,
        'parentId': node.parent != null ? nodeToId[node.parent!] ?? -1 : -1,
        'move': node.move,
        'fen': node.fen,
        'gamesPlayed': node.gamesPlayed,
        'wins': node.wins,
        'losses': node.losses,
        'draws': node.draws,
        'childIds': childIds,
      });
    }

    // Serialise fenToNodes as fen → list of node IDs.
    final fenIndex = <String, List<int>>{};
    for (final entry in fenToNodes.entries) {
      fenIndex[entry.key] =
          entry.value.map((n) => nodeToId[n] ?? -1).toList();
    }

    return {'nodes': nodes, 'fenToNodes': fenIndex};
  }

  /// Reconstruct an [OpeningTree] from the flat map produced by
  /// [toTransferJson].
  factory OpeningTree.fromTransferJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'] as List<dynamic>;
    final builtNodes = <int, OpeningTreeNode>{};

    // First pass: create all nodes without parent/child links.
    for (final raw in rawNodes) {
      final m = raw as Map<String, dynamic>;
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
    for (final raw in rawNodes) {
      final m = raw as Map<String, dynamic>;
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

    // Rebuild fenToNodes index.
    final rawFenIndex = json['fenToNodes'] as Map<String, dynamic>;
    final fenToNodes = <String, List<OpeningTreeNode>>{};
    for (final entry in rawFenIndex.entries) {
      fenToNodes[entry.key] = (entry.value as List<dynamic>)
          .map((id) => builtNodes[id as int]!)
          .toList();
    }

    return OpeningTree(
      root: builtNodes[0],
      fenToNodes: fenToNodes,
    );
  }
}
