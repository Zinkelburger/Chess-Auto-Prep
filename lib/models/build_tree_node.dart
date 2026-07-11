/// Persistent tree model for the two-phase repertoire build algorithm.
///
/// Phase 1 builds the full tree with evaluations on every node.
/// Phase 2 computes ease/expectimax and selects repertoire moves from it.
///
/// This is separate from [OpeningTreeNode] which is used for PGN-imported
/// trees and game analysis.
library;

import 'move_tree_node_view.dart';

// ── External eval skip mode ───────────────────────────────────────────────

/// When external eval sources (local ChessDB / API) should be skipped.
enum ExtEvalMode {
  /// Try external sources after project cache.
  none,

  /// Skip local ChessDB and ChessDB API; use cache then Stockfish only.
  skipExternal,
}

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

class BuildTreeNode implements MoveTreeNodeView {
  final String fen;
  final String moveSan;
  final String moveUci;
  final int ply;
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

  /// Best-first frontier priority: reach probability discounted at our-move
  /// alternatives (non-incumbent candidates get × ourAltDiscount).  Unlike
  /// [cumulativeProbability] this is a search-scheduling signal only — it
  /// never feeds expectimax or selection.  -1.0 means not set (legacy trees);
  /// consumers fall back to [cumulativeProbability].
  double searchPriority = -1.0;

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

  /// Total expected opponent CPL downstream from this node.
  /// Used by SelectionMode.trappy to pick lines that maximize opponent errors.
  double cplValue = 0.0;

  /// Max ply count below this node (0 for leaves).
  int subtreePly = 0;

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

  /// How natural our chosen move is at this position (Maia-derived).
  /// Only meaningful at our-move children. -1.0 means not computed.
  double myEase = -1.0;

  /// Engine PV continuation: opponent reply stashed from MultiPV line 0
  /// on our-move children (opponent-to-move position). Consumed when this
  /// node is expanded; injected if Maia/Lichess omit it.
  String? pvContinuationMove;

  /// True when injected from a stashed PV reply because human move sources
  /// did not include it.
  bool engineInjected = false;

  /// External eval skip flag inherited from parent on local DB hard miss.
  ExtEvalMode extEvalMode = ExtEvalMode.none;

  /// Selected as part of the repertoire during the selection phase.
  bool isRepertoireMove = false;

  /// Composite repertoire quality score (set during selection).
  double repertoireScore = 0.0;

  /// Total number of nodes in this subtree (including this node).
  /// Pre-computed by [BuildTree.computeMetadata] for O(1) access.
  int subtreeSize = 1;

  BuildTreeNode({
    required this.fen,
    required this.moveSan,
    required this.moveUci,
    required this.ply,
    required this.isWhiteToMove,
    required this.nodeId,
    this.parent,
    this.moveProbability = 1.0,
    this.cumulativeProbability = 1.0,
  });

  // ── MoveTreeNodeView ──
  @override
  String get san => moveSan;
  @override
  String get fenAfter => fen;
  @override
  List<MoveTreeNodeView> get orderedChildren => children;

  bool get hasEngineEval => engineEvalCp != null;

  /// Engine eval from our perspective (positive = good for us).
  int evalForUs(bool playAsWhite) {
    if (engineEvalCp == null) return 0;
    return isWhiteToMove == playAsWhite ? engineEvalCp! : -engineEvalCp!;
  }

  void setLichessStats(int w, int b, int d) {
    whiteWins = w;
    blackWins = b;
    draws = d;
    totalGames = w + b + d;
  }

  /// Database score for WHITE: `(whiteWins + draws/2) / totalGames`.
  ///
  /// NOTE: this is always White's perspective (Lichess DB stats), unlike
  /// [OpeningTreeNode.winRate] / [PositionStats.winRate] which are
  /// user-perspective. Use [winRateFor] to get the score for the side we
  /// are building for.
  double get whiteWinRate {
    if (totalGames == 0) return 0.0;
    return (whiteWins + 0.5 * draws) / totalGames;
  }

  /// Database score from the perspective of the side we play:
  /// [whiteWinRate] when playing White, its complement when playing Black.
  double winRateFor(bool playAsWhite) =>
      playAsWhite ? whiteWinRate : 1.0 - whiteWinRate;

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
      'BuildTreeNode(ply=$ply, ${moveSan.isEmpty ? "root" : moveSan}, '
      'eval=${engineEvalCp ?? "?"}, '
      'cumP=${(cumulativeProbability * 100).toStringAsFixed(2)}%)';
}

// ── Build tree container ─────────────────────────────────────────────────

class BuildTree {
  BuildTreeNode root;
  int totalNodes;
  int maxPlyReached;
  bool buildComplete;

  /// SAN move sequence from standard start that leads to [root].
  /// Empty when the tree starts from an arbitrary FEN with no known prefix.
  String startMoves;

  /// Config snapshot used for serialization and re-scoring.
  /// Updated when resuming a partial build with a new target depth.
  Map<String, dynamic> configSnapshot;

  /// O(1) node lookup by [BuildTreeNode.nodeId].
  /// Populated by [computeMetadata] or during build via [registerNode].
  final Map<int, BuildTreeNode> nodeIndex = {};

  BuildTree({
    required this.root,
    this.totalNodes = 1,
    this.maxPlyReached = 0,
    this.buildComplete = false,
    this.startMoves = '',
    this.configSnapshot = const {},
  });

  /// Register a single node in [nodeIndex] (used during incremental build).
  void registerNode(BuildTreeNode node) {
    nodeIndex[node.nodeId] = node;
  }

  /// Sort every node's children in-place by
  /// (isRepertoireMove desc, moveProbability desc).
  ///
  /// Call once after deserialization or after the selection phase — not
  /// per-frame.
  void sortAllChildren() {
    _sortRecursive(root);
  }

  /// Rebuild [nodeIndex] from the tree and compute [BuildTreeNode.subtreeSize]
  /// on every node via a single post-order DFS.
  void computeMetadata() {
    nodeIndex.clear();
    _metadataRecursive(root);
  }

  static void _sortRecursive(BuildTreeNode node) {
    if (node.children.length > 1) {
      node.children.sort((a, b) {
        if (a.isRepertoireMove != b.isRepertoireMove) {
          return a.isRepertoireMove ? -1 : 1;
        }
        return b.moveProbability.compareTo(a.moveProbability);
      });
    }
    for (final child in node.children) {
      _sortRecursive(child);
    }
  }

  int _metadataRecursive(BuildTreeNode node) {
    nodeIndex[node.nodeId] = node;
    int size = 1;
    for (final child in node.children) {
      size += _metadataRecursive(child);
    }
    node.subtreeSize = size;
    return size;
  }
}

// ── Build progress ───────────────────────────────────────────────────────

class BuildProgress {
  final int totalNodes;
  final int maxPlyReached;
  final int maxPlyConfig;
  final int elapsedMs;
  final double? nodesPerMinute;

  /// Deepest ply being worked on (FIFO: current BFS layer; best-first:
  /// deepest ply reached so far).
  final int currentDepth;

  /// Nodes at [currentDepth] that have not been expanded yet (FIFO only).
  final int unexploredAtDepth;

  /// Total nodes at [currentDepth] (explored + unexplored; FIFO only).
  final int totalAtDepth;

  /// Estimated seconds to finish all unexplored nodes at [currentDepth]
  /// (FIFO only — best-first never completes depth layers in order).
  final int? etaDepthSeconds;

  /// Whether the build pops the frontier best-first (Fast Expectimax).
  final bool bestFirst;

  /// Frontier nodes still queued for expansion.
  final int frontierSize;

  /// Monotone 0–1 progress of the popped-priority descent toward the
  /// search floor (best-first only, log scale).  Null in FIFO mode.
  final double? priorityProgress;

  /// Whole-run ETA from the recent [priorityProgress] descent rate
  /// (best-first only).
  final int? etaRunSeconds;

  /// Per-ply node counts, index = ply.  Empty when not computed.
  final List<int> depthTotals;

  /// Per-ply explored-node counts, aligned with [depthTotals].
  final List<int> depthExplored;

  const BuildProgress({
    required this.totalNodes,
    this.maxPlyReached = 0,
    this.maxPlyConfig = 20,
    this.elapsedMs = 0,
    this.nodesPerMinute,
    this.currentDepth = 0,
    this.unexploredAtDepth = 0,
    this.totalAtDepth = 0,
    this.etaDepthSeconds,
    this.bestFirst = false,
    this.frontierSize = 0,
    this.priorityProgress,
    this.etaRunSeconds,
    this.depthTotals = const [],
    this.depthExplored = const [],
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

  int localChessDbHits = 0;
  int localChessDbMisses = 0;
  int localChessDbShallow = 0;
  int localChessDbHardMisses = 0;

  int cdbDirectHits = 0;
  int cdbDirectMisses = 0;
  int cdbDirectShallow = 0;
  int cdbDirectHardMisses = 0;

  int chessDbApiHits = 0;
  int chessDbApiMisses = 0;
  int chessDbApiShallow = 0;
  int chessDbApiQuotaBlocked = 0;

  int transpositionEvalHits = 0;
  int extEvalSubtreeSkips = 0;

  Map<String, dynamic> toJson() => {
        'lichess_queries': lichessQueries,
        'lichess_cache_hits': lichessCacheHits,
        'lichess_total_ms': lichessTotalMs.round(),
        'maia_evals': maiaEvals,
        'maia_total_ms': maiaTotalMs.round(),
        'sf_multipv_calls': sfMultipvCalls,
        'sf_multipv_ms': sfMultipvMs.round(),
        'sf_single_calls': sfSingleCalls,
        'sf_single_ms': sfSingleMs.round(),
        'sf_batch_calls': sfBatchCalls,
        'sf_batch_ms': sfBatchMs.round(),
        'db_eval_hits': dbEvalHits,
        'db_eval_misses': dbEvalMisses,
        'db_explorer_hits': dbExplorerHits,
        'db_explorer_misses': dbExplorerMisses,
        'local_chessdb_hits': localChessDbHits,
        'local_chessdb_misses': localChessDbMisses,
        'local_chessdb_shallow': localChessDbShallow,
        'local_chessdb_hard_misses': localChessDbHardMisses,
        'cdbdirect_hits': cdbDirectHits,
        'cdbdirect_misses': cdbDirectMisses,
        'cdbdirect_shallow': cdbDirectShallow,
        'cdbdirect_hard_misses': cdbDirectHardMisses,
        'chessdb_api_hits': chessDbApiHits,
        'chessdb_api_misses': chessDbApiMisses,
        'chessdb_api_shallow': chessDbApiShallow,
        'chessdb_api_quota_blocked': chessDbApiQuotaBlocked,
        'transposition_eval_hits': transpositionEvalHits,
        'ext_eval_subtree_skips': extEvalSubtreeSkips,
      };
}
