/// Opening tree models - Represents a tree of moves from analyzed games
/// Similar to openingtree.com's move explorer functionality
library;

import 'dart:collection';

import 'package:dartchess/dartchess.dart';
import '../constants/chess_constants.dart';
import '../utils/fen_utils.dart';

/// How win/draw/loss stats should be colored when displayed.
///
/// The PGN-viewer tree counts `wins` from White's perspective. Green/red only
/// makes sense when we know whose games these are — otherwise color like
/// lichess: white / grey / black segments.
enum WdlPerspective {
  /// `wins` belong to the protagonist playing White → green = wins.
  playerIsWhite,

  /// The protagonist plays Black → green = `losses` (Black's wins).
  playerIsBlack,

  /// No known protagonist: neutral white/grey/black coloring.
  whiteBlack,
}

/// Estimated likelihood that the tree's protagonist steers the game into a
/// position, together with how many real choices they had on the way.
///
/// [probability] is the product of the protagonist's empirical move
/// frequencies at each of *their* turns along the path. Moves by the other
/// side are treated as certain (probability 1) — the viewer controls those.
/// [decisionPoints] counts the protagonist's moves on the path where the
/// database shows they did not always continue this way (frequency < 100%).
class ReachEstimate {
  final double probability;
  final int decisionPoints;

  const ReachEstimate(this.probability, this.decisionPoints);

  double get percent => probability * 100;

  /// Compact percentage label: '100', '<0.1', or one decimal place.
  String get percentLabel {
    if (percent >= 99.95) return '100';
    if (percent > 0 && percent < 0.05) return '<0.1';
    return percent.toStringAsFixed(1);
  }
}

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

  /// Calculate win rate (0.0 to 1.0).
  ///
  /// USER-perspective: [wins]/[losses] are counted for the tree's
  /// protagonist (the user/repertoire side the tree was built for), not for
  /// White. Contrast with `BuildTreeNode.whiteWinRate`, which is always
  /// White's score.
  double get winRate {
    if (gamesPlayed == 0) return 0.0;
    return (wins + 0.5 * draws) / gamesPlayed;
  }

  /// Win rate as percentage
  double get winRatePercent => winRate * 100;

  List<OpeningTreeNode>? _sortedChildrenCache;

  /// Get sorted list of children by number of games played (descending).
  /// Cached and invalidated when children or stats change.
  List<OpeningTreeNode> get sortedChildren {
    if (_sortedChildrenCache == null) {
      final childList = children.values.toList();
      childList.sort((a, b) => b.gamesPlayed.compareTo(a.gamesPlayed));
      _sortedChildrenCache = childList;
    }
    return _sortedChildrenCache!;
  }

  void _invalidateSortCache() => _sortedChildrenCache = null;

  /// Update statistics with a game result.
  /// Result should be from the player's perspective (1.0 = win, 0.5 = draw, 0.0 = loss).
  ///
  /// **Important:** Directly mutating [gamesPlayed], [wins], [losses], or
  /// [draws] bypasses cache invalidation. Always use this method or call
  /// [_invalidateSortCache] on the parent after manual mutation.
  void updateStats(double result) {
    gamesPlayed++;
    if (result >= 0.9) {
      wins++;
    } else if (result <= 0.1) {
      losses++;
    } else {
      draws++;
    }
    parent?._invalidateSortCache();
  }

  /// Remove the child reached by [movesan], discarding its whole subtree.
  /// Returns true if a child was removed.
  bool removeChild(String movesan) {
    final removed = children.remove(movesan);
    if (removed != null) {
      removed.parent = null;
      _invalidateSortCache();
      return true;
    }
    return false;
  }

  /// Add or get a child node for a move
  OpeningTreeNode getOrCreateChild(String movesan, String resultingFen) {
    if (!children.containsKey(movesan)) {
      _sortedChildrenCache = null;
      children[movesan] = OpeningTreeNode(
        move: movesan,
        fen: resultingFen,
        parent: this,
      );
    }
    return children[movesan]!;
  }

  /// Whether the move leading to this node was played by White. [fen] is the
  /// position *after* the move, so the mover is the side that is no longer to
  /// move. FEN-derived (rather than ply parity) so custom start positions and
  /// transposed paths stay correct.
  bool get moverWasWhite {
    final parts = fen.split(' ');
    return parts.length > 1 && parts[1] == 'b';
  }

  /// How likely the protagonist (the player whose games built this tree,
  /// playing White when [protagonistIsWhite]) is to reach this node's
  /// position, assuming the viewer plays down this exact path themselves.
  /// See [ReachEstimate].
  ReachEstimate reachEstimate({required bool protagonistIsWhite}) {
    var probability = 1.0;
    var decisionPoints = 0;
    for (
      OpeningTreeNode? node = this;
      node != null && node.parent != null;
      node = node.parent
    ) {
      if (node.moverWasWhite != protagonistIsWhite) continue;
      final parentGames = node.parent!.gamesPlayed;
      if (parentGames <= 0) continue;
      probability *= node.gamesPlayed / parentGames;
      if (node.gamesPlayed < parentGames) decisionPoints++;
    }
    return ReachEstimate(probability, decisionPoints);
  }

  /// Get path from root to this node (list of moves)
  List<String> getMovePath() {
    final path = <String>[];
    OpeningTreeNode? current = this;

    while (current != null && current.move.isNotEmpty) {
      path.add(current.move);
      current = current.parent;
    }

    return path.reversed.toList();
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

/// A transposition-aware view of one position: every tree node that reaches
/// the same position (same normalized FEN) via a different move order, with
/// statistics summed across them.
///
/// The tree itself is path-based, so a position reached by transposition is
/// split across several [OpeningTreeNode]s. Summing here is what makes tree
/// counts agree with the FEN-keyed position statistics shown elsewhere
/// (e.g. the FEN list in player analysis).
class PositionGroup {
  /// The nodes sharing this position. Never empty.
  final List<OpeningTreeNode> nodes;

  PositionGroup(this.nodes) : assert(nodes.isNotEmpty);

  /// The node reached by the most games — the representative concrete path
  /// used where a single node is required (navigation cursor, move-path
  /// display, coverage checks).
  OpeningTreeNode get primaryNode =>
      nodes.reduce((a, b) => b.gamesPlayed > a.gamesPlayed ? b : a);

  /// Full FEN of the position (from [primaryNode]).
  String get fen => primaryNode.fen;

  /// SAN of the move leading here. Continuation groups built by [children]
  /// share one SAN; for an arbitrary position group this is the primary
  /// node's last move.
  String get move => primaryNode.move;

  int get gamesPlayed => nodes.fold(0, (sum, n) => sum + n.gamesPlayed);
  int get wins => nodes.fold(0, (sum, n) => sum + n.wins);
  int get losses => nodes.fold(0, (sum, n) => sum + n.losses);
  int get draws => nodes.fold(0, (sum, n) => sum + n.draws);

  /// Win rate across all paths (user perspective, like
  /// [OpeningTreeNode.winRate]).
  double get winRate {
    final games = gamesPlayed;
    if (games == 0) return 0.0;
    return (wins + 0.5 * draws) / games;
  }

  double get winRatePercent => winRate * 100;

  /// Reach estimate summed across every path (transposition) into this
  /// position — the paths are disjoint, so their probabilities add. Decision
  /// points are reported for the most-played path ([primaryNode]).
  ReachEstimate reachEstimate({required bool protagonistIsWhite}) {
    var probability = 0.0;
    for (final node in nodes) {
      probability += node
          .reachEstimate(protagonistIsWhite: protagonistIsWhite)
          .probability;
    }
    return ReachEstimate(
      probability.clamp(0.0, 1.0),
      primaryNode
          .reachEstimate(protagonistIsWhite: protagonistIsWhite)
          .decisionPoints,
    );
  }

  /// Continuations from this position, merged across all [nodes] (grouped by
  /// SAN) and sorted by games played, descending.
  List<PositionGroup> get children {
    final bySan = <String, List<OpeningTreeNode>>{};
    for (final node in nodes) {
      for (final child in node.children.values) {
        (bySan[child.move] ??= []).add(child);
      }
    }
    return bySan.values.map(PositionGroup.new).toList()
      ..sort((a, b) => b.gamesPlayed.compareTo(a.gamesPlayed));
  }
}

/// Opening tree - contains the root node and provides navigation
class OpeningTree {
  late final OpeningTreeNode root;
  late OpeningTreeNode currentNode;

  /// FEN to node mapping for quick lookup
  final Map<String, List<OpeningTreeNode>> fenToNodes;

  OpeningTree({
    OpeningTreeNode? root,
    Map<String, List<OpeningTreeNode>>? fenToNodes,
  }) : fenToNodes = fenToNodes ?? {} {
    // Ensure root and currentNode point to the same object
    final rootNode = root ?? OpeningTreeNode(move: '', fen: kStandardStartFen);
    this.root = rootNode;
    currentNode = rootNode;
  }

  /// Navigate to a child node by move.
  ///
  /// Transposition-aware: if the current path never continued with [move]
  /// but another path reaching the same position did, the cursor jumps to
  /// that path's child instead of failing.
  bool makeMove(String move) {
    final direct = currentNode.children[move];
    if (direct != null) {
      currentNode = direct;
      return true;
    }
    final transpositions =
        fenToNodes[normalizeFen(currentNode.fen)] ?? const <OpeningTreeNode>[];
    for (final node in transpositions) {
      final child = node.children[move];
      if (child != null) {
        currentNode = child;
        return true;
      }
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

  /// Navigate to a position by FEN. When several paths (transpositions)
  /// reach it, the cursor lands on the most-played one.
  bool navigateToFen(String fen) {
    final nodes = fenToNodes[normalizeFen(fen)];
    if (nodes == null || nodes.isEmpty) return false;
    currentNode = PositionGroup(nodes).primaryNode;
    return true;
  }

  /// Transposition-aware view of [node]'s position: the node itself plus any
  /// nodes reaching the same position via other move orders.
  PositionGroup groupFor(OpeningTreeNode node) {
    final indexed = fenToNodes[normalizeFen(node.fen)];
    if (indexed == null || indexed.isEmpty) return PositionGroup([node]);
    return PositionGroup(indexed.contains(node) ? indexed : [node, ...indexed]);
  }

  /// Transposition-aware view of the current position.
  PositionGroup get currentGroup => groupFor(currentNode);

  /// Add a FEN to node mapping (idempotent — a node is indexed once even
  /// when re-visited by later games, so [PositionGroup] sums stay correct).
  void indexNode(OpeningTreeNode node) {
    final key = normalizeFen(node.fen);
    final nodes = fenToNodes[key] ??= [];
    if (!nodes.contains(node)) nodes.add(node);
  }

  /// Get total number of games in the tree (games at root)
  int get totalGames => root.gamesPlayed;

  /// Get current depth in the tree
  int get currentDepth => currentNode.getMovePath().length;

  /// Whether [san] is already a child of any node at [fen].
  bool hasMove(String fen, String san) {
    final key = normalizeFen(fen);
    final nodes = fenToNodes[key];
    if (nodes != null) {
      for (final node in nodes) {
        if (node.children.containsKey(san)) return true;
      }
    }
    if (normalizeFen(root.fen) == key && root.children.containsKey(san)) {
      return true;
    }
    return false;
  }

  /// Whether [san] is a child along [pathFromRoot] (path-aware repertoire check).
  bool hasMoveOnPath(List<String> pathFromRoot, String san) {
    reset();
    for (final move in pathFromRoot) {
      if (!makeMove(move)) return false;
    }
    return currentNode.children.containsKey(san);
  }

  /// Append a single line of moves to the tree without rebuilding.
  /// Each move is walked node-by-node; new nodes are created as needed.
  void appendLine(List<String> moves) {
    appendLineFromFen(kStandardStartFen, moves);
  }

  /// Append moves starting from [startFen] (supports custom setup positions).
  void appendLineFromFen(String startFen, List<String> moves) {
    if (moves.isEmpty) return;

    Position position;
    OpeningTreeNode node;

    final normalizedStart = normalizeFen(startFen);
    final nodesAtFen = fenToNodes[normalizedStart];

    if (nodesAtFen != null && nodesAtFen.isNotEmpty) {
      node = PositionGroup(nodesAtFen).primaryNode;
      position = Chess.fromSetup(Setup.parseFen(node.fen));
    } else if (normalizedStart == normalizeFen(kStandardStartFen)) {
      position = Chess.initial;
      node = root;
    } else {
      position = Chess.fromSetup(Setup.parseFen(startFen));
      node = root;
    }

    node.updateStats(0.5);

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
    final queue = Queue<OpeningTreeNode>()..add(root);
    nodeToId[root] = 0;

    while (queue.isNotEmpty) {
      final node = queue.removeFirst();
      final id = nodeToId[node]!;

      final childIds = <String, int>{};
      for (final entry in node.children.entries) {
        final childNode = entry.value;
        final childId = nodeToId.putIfAbsent(childNode, () {
          final nextId = nodeToId.length;
          queue.add(childNode);
          return nextId;
        });
        childIds[entry.key] = childId;
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
      fenIndex[entry.key] = entry.value.map((n) => nodeToId[n] ?? -1).toList();
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

    return OpeningTree(root: builtNodes[0], fenToNodes: fenToNodes);
  }
}
