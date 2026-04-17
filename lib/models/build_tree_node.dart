/// Persistent tree model for the two-phase repertoire build algorithm.
///
/// Phase 1 builds the full tree with evaluations on every node.
/// Phase 2 computes ease/expectimax and selects repertoire moves from it.
///
/// This is separate from [OpeningTreeNode] which is used for PGN-imported
/// trees and game analysis.
library;

// ── Prune reasons ────────────────────────────────────────────────────────

enum PruneReason {
  none,

  /// Position is already winning — no further preparation needed.
  /// Node is kept as a leaf with annotation info.
  evalTooHigh,

  /// Position is too bad for us.  Marked during build, then deleted
  /// in a post-build cleanup pass.
  evalTooLow,
}

// ── Build tree node ──────────────────────────────────────────────────────

class BuildTreeNode {
  final String fen;
  final String moveSan;
  final String moveUci;
  final int depth;
  final bool isWhiteToMove;
  final int nodeId;

  BuildTreeNode? parent;
  final List<BuildTreeNode> children = [];

  /// Engine evaluation in centipawns (side-to-move perspective).
  int? engineEvalCp;

  /// Local probability of this move being played (0.0–1.0).
  /// For our-move children this is 1.0 (we choose what to play).
  double moveProbability;

  /// Product of opponent-move probabilities along the path from root.
  /// Only decreases on opponent moves.
  double cumulativeProbability;

  // Lichess stats
  int whiteWins = 0;
  int blackWins = 0;
  int draws = 0;
  int totalGames = 0;

  /// Whether this node's position has been fully processed by the builder.
  bool explored = false;

  PruneReason pruneReason = PruneReason.none;

  /// The eval (from our perspective) that triggered pruning.
  int? pruneEvalCp;

  String? openingName;
  String? openingEco;

  /// Ease score [0.0, 1.0] — how likely the side to move finds a good move.
  double? ease;

  /// Expected centipawn loss by the opponent at this node (display only).
  double localCpl = 0.0;

  /// Practical win probability in [0, 1], computed via expectimax.
  double expectimaxValue = 0.0;

  /// Max ply depth below this node (0 for leaves).
  int subtreeDepth = 0;

  /// Actual count of opponent-move levels in the subtree (diagnostics).
  int subtreeOppPlies = 0;

  bool hasExpectimax = false;

  /// Ease score from the opponent's perspective.
  double opponentEase = 0.0;

  /// Trap score: how often opponents play suboptimal moves here [0, 1].
  /// -1.0 means not computed / insufficient data.
  double trapScore = -1.0;

  /// Maia-predicted probability that a human would play this move.
  /// Used as a novelty signal when novelty_weight > 0.
  /// -1.0 means not set.
  double maiaFrequency = -1.0;

  /// Selected as part of the repertoire during the selection phase.
  bool isRepertoireMove = false;

  /// Composite repertoire quality score (set during selection).
  double repertoireScore = 0.0;

  BuildTreeNode({
    required this.fen,
    required this.moveSan,
    required this.moveUci,
    required this.depth,
    required this.isWhiteToMove,
    required this.nodeId,
    this.parent,
    this.moveProbability = 1.0,
    this.cumulativeProbability = 1.0,
  });

  bool get hasEngineEval => engineEvalCp != null;

  /// Engine eval from our perspective (positive = good for us).
  int evalForUs(bool playAsWhite) {
    if (engineEvalCp == null) return 0;
    return isWhiteToMove == playAsWhite
        ? engineEvalCp!
        : -engineEvalCp!;
  }

  void setLichessStats(int w, int b, int d) {
    whiteWins = w;
    blackWins = b;
    draws = d;
    totalGames = w + b + d;
  }

  double get winRate {
    if (totalGames == 0) return 0.0;
    return (whiteWins + 0.5 * draws) / totalGames;
  }

  /// Count all nodes in this subtree (including this node).
  int countSubtree() {
    int count = 1;
    for (final child in children) {
      count += child.countSubtree();
    }
    return count;
  }

  /// Get the line of SAN moves from root to this node.
  List<String> getLineSan() {
    final moves = <String>[];
    BuildTreeNode? current = this;
    while (current != null && current.moveSan.isNotEmpty) {
      moves.insert(0, current.moveSan);
      current = current.parent;
    }
    return moves;
  }

  @override
  String toString() =>
      'BuildTreeNode(d=$depth, ${moveSan.isEmpty ? "root" : moveSan}, '
      'eval=${engineEvalCp ?? "?"}, '
      'cumP=${(cumulativeProbability * 100).toStringAsFixed(2)}%)';
}

// ── Build tree container ─────────────────────────────────────────────────

class BuildTree {
  BuildTreeNode root;
  int totalNodes;
  int maxDepthReached;
  bool buildComplete;

  /// Config snapshot used for serialization and re-scoring.
  final Map<String, dynamic> configSnapshot;

  BuildTree({
    required this.root,
    this.totalNodes = 1,
    this.maxDepthReached = 0,
    this.buildComplete = false,
    this.configSnapshot = const {},
  });
}

// ── Build progress ───────────────────────────────────────────────────────

class BuildProgress {
  final int totalNodes;
  final int currentDepth;
  final int maxDepthReached;
  final String? currentFen;
  final int elapsedMs;

  // Counters
  final int engineCalls;
  final int engineCacheHits;
  final int maiaCalls;
  final int lichessQueries;
  final int lichessCacheHits;

  final String message;

  // ETA estimation (filled by TreeBuildService once enough data exists)
  final double? nodesPerSecond;
  final double? observedBranchingFactor;
  final int? estimatedTotalNodes;
  final double? etaSeconds;

  const BuildProgress({
    required this.totalNodes,
    required this.currentDepth,
    this.maxDepthReached = 0,
    this.currentFen,
    this.elapsedMs = 0,
    this.engineCalls = 0,
    this.engineCacheHits = 0,
    this.maiaCalls = 0,
    this.lichessQueries = 0,
    this.lichessCacheHits = 0,
    required this.message,
    this.nodesPerSecond,
    this.observedBranchingFactor,
    this.estimatedTotalNodes,
    this.etaSeconds,
  });
}

// ── Build stats (accumulated during build) ───────────────────────────────

class BuildStats {
  int lichessQueries = 0;
  int lichessCacheHits = 0;
  double lichessTotalMs = 0.0;

  int maiaEvals = 0;
  double maiaTotalMs = 0.0;

  int sfMultipvCalls = 0;
  double sfMultipvMs = 0.0;
  int sfSingleCalls = 0;
  double sfSingleMs = 0.0;
  int sfBatchCalls = 0;
  double sfBatchMs = 0.0;

  int dbEvalHits = 0;
  int dbEvalMisses = 0;
  int dbExplorerHits = 0;
  int dbExplorerMisses = 0;

}
