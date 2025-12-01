/// Opening tree models - Represents a tree of moves from analyzed games
/// Similar to openingtree.com's move explorer functionality

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
    // Normalize FEN (remove move counters if present)
    final normalizedFen = _normalizeFen(fen);

    if (fenToNodes.containsKey(normalizedFen)) {
      final nodes = fenToNodes[normalizedFen]!;
      if (nodes.isNotEmpty) {
        currentNode = nodes.first;
        return true;
      }
    }
    return false;
  }

  /// Add a FEN to node mapping
  void indexNode(OpeningTreeNode node) {
    final normalizedFen = _normalizeFen(node.fen);
    if (!fenToNodes.containsKey(normalizedFen)) {
      fenToNodes[normalizedFen] = [];
    }
    fenToNodes[normalizedFen]!.add(node);
  }

  /// Normalize FEN (remove move counters) for consistent lookups
  String _normalizeFen(String fen) {
    final parts = fen.split(' ');
    if (parts.length >= 4) {
      return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}';
    }
    return fen;
  }

  /// Get total number of games in the tree (games at root)
  int get totalGames => root.gamesPlayed;

  /// Get current depth in the tree
  int get currentDepth => currentNode.getMovePath().length;

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
}
