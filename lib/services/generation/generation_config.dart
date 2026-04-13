/// Configuration, output types, and strategy enum for repertoire generation.
library;

// ── Strategy enum ────────────────────────────────────────────────────────

enum GenerationStrategy {
  engineOnly,
  winRateOnly,
  eca,
}

// ── Two-phase tree build config (matches C tree_builder) ────────────────

/// Configuration for the two-phase tree build algorithm.
///
/// Phase 1 builds a persistent tree with all evals.  Phase 2 computes
/// ease/ECA and selects repertoire moves.  This replaces the old
/// single-pass DFS for engine-backed strategies.
class TreeBuildConfig {
  final String startFen;
  final bool playAsWhite;

  // ── Traversal limits ──
  final double minProbability;
  final int maxDepth;
  final int maxNodes;

  // ── Engine ──
  final int evalDepth;

  // ── Our-move MultiPV (tapers linearly with depth) ──
  final int ourMultipvRoot;
  final int ourMultipvFloor;
  final int taperDepth;
  final int maxEvalLossCp;

  // ── Opponent-move mass target (tapers linearly with depth) ──
  final int oppMaxChildren;
  final double oppMassRoot;
  final double oppMassFloor;

  // ── Eval window pruning ──
  final int minEvalCp;
  final int maxEvalCp;
  final bool relativeEval;

  // ── Lichess API ──
  final bool useLichessDb;
  final String ratingRange;
  final String speeds;
  final int minGames;

  // ── Maia ──
  final int maiaElo;
  final double maiaThreshold;
  final double maiaMinProb;

  // ── ECA / repertoire selection ──
  final double depthDiscount;
  final int trickWeight;
  final double leafConfidence;

  const TreeBuildConfig({
    required this.startFen,
    required this.playAsWhite,
    this.minProbability = 0.0001,
    this.maxDepth = 30,
    this.maxNodes = 0,
    this.evalDepth = 20,
    this.ourMultipvRoot = 10,
    this.ourMultipvFloor = 2,
    this.taperDepth = 8,
    this.maxEvalLossCp = 50,
    this.oppMaxChildren = 6,
    this.oppMassRoot = 0.95,
    this.oppMassFloor = 0.50,
    this.minEvalCp = 0,
    this.maxEvalCp = 200,
    this.relativeEval = false,
    this.useLichessDb = false,
    this.ratingRange = '2000,2200,2500',
    this.speeds = 'blitz,rapid,classical',
    this.minGames = 10,
    this.maiaElo = 2200,
    this.maiaThreshold = 0.01,
    this.maiaMinProb = 0.02,
    this.depthDiscount = 0.90,
    this.trickWeight = 50,
    this.leafConfidence = 1.0,
  });

  /// Convert a white-perspective centipawn score to "our" perspective.
  int toOurPerspective(int whiteCp) => playAsWhite ? whiteCp : -whiteCp;

  /// Serialise to a JSON-compatible map for tree file metadata.
  Map<String, dynamic> toJson() => {
    'play_as_white': playAsWhite,
    'min_probability': minProbability,
    'max_depth': maxDepth,
    'max_nodes': maxNodes,
    'eval_depth': evalDepth,
    'our_multipv_root': ourMultipvRoot,
    'our_multipv_floor': ourMultipvFloor,
    'taper_depth': taperDepth,
    'max_eval_loss_cp': maxEvalLossCp,
    'opp_max_children': oppMaxChildren,
    'opp_mass_root': oppMassRoot,
    'opp_mass_floor': oppMassFloor,
    'min_eval_cp': minEvalCp,
    'max_eval_cp': maxEvalCp,
    'relative_eval': relativeEval,
    'use_lichess_db': useLichessDb,
    'rating_range': ratingRange,
    'speeds': speeds,
    'min_games': minGames,
    'maia_elo': maiaElo,
    'maia_threshold': maiaThreshold,
    'maia_min_prob': maiaMinProb,
    'depth_discount': depthDiscount,
    'trick_weight': trickWeight,
    'leaf_confidence': leafConfidence,
  };

  /// MultiPV count tapers linearly from root value to floor.
  int multipvForDepth(int depth) {
    if (depth >= taperDepth) return ourMultipvFloor;
    final span = ourMultipvRoot - ourMultipvFloor;
    return ourMultipvRoot - span * depth ~/ taperDepth;
  }

  /// Opponent mass target tapers linearly from root to floor.
  double oppMassForDepth(int depth) {
    if (depth >= taperDepth) return oppMassFloor;
    final span = oppMassRoot - oppMassFloor;
    return oppMassRoot - span * depth / taperDepth;
  }
}

// ── Configuration ────────────────────────────────────────────────────────

class RepertoireGenerationConfig {
  final String startFen;
  final bool isWhiteRepertoire;
  final double cumulativeProbabilityCutoff;
  final double opponentMassTarget;
  final int maxDepthPly;
  final int engineDepth;
  final int easeDepth;
  final int engineTopK;
  final int maxCandidates;
  final int maxEvalLossCp;
  final int minEvalCpForUs;
  final int maxEvalCpForUs;
  final int maiaElo;

  /// ECA depth-discount factor γ.  Each ply deeper is worth γ× less.
  /// 0.90 is typical: centipawn losses 10 ply deep count ~35% as much.
  final double ecaDepthDiscount;

  /// ECA-vs-eval blend weight α for our-move scoring (0 = pure ECA,
  /// 1 = pure eval, 0.4 = balanced).
  final double ecaEvalWeight;

  /// Minimum win probability to consider a candidate (eval guard).
  final double ecaEvalGuardThreshold;

  const RepertoireGenerationConfig({
    required this.startFen,
    required this.isWhiteRepertoire,
    this.cumulativeProbabilityCutoff = 0.001,
    this.opponentMassTarget = 0.80,
    this.maxDepthPly = 15,
    this.engineDepth = 20,
    this.easeDepth = 18,
    this.engineTopK = 3,
    this.maxCandidates = 8,
    this.maxEvalLossCp = 50,
    this.minEvalCpForUs = 0,
    this.maxEvalCpForUs = 200,
    this.maiaElo = 1500,
    this.ecaDepthDiscount = 0.90,
    this.ecaEvalWeight = 0.40,
    this.ecaEvalGuardThreshold = 0.35,
  });

  /// Convert a white-perspective centipawn score to "our" perspective.
  int toOurPerspective(int whiteCp) =>
      isWhiteRepertoire ? whiteCp : -whiteCp;
}

// ── Output types ─────────────────────────────────────────────────────────

class GeneratedLine {
  final List<String> movesSan;
  final double cumulativeProbability;
  final int finalEvalWhiteCp;

  const GeneratedLine({
    required this.movesSan,
    required this.cumulativeProbability,
    required this.finalEvalWhiteCp,
  });
}

class GenerationProgress {
  final int nodesVisited;
  final int linesGenerated;
  final int currentDepth;
  final int dbCalls;
  final int dbCacheHits;
  final int elapsedMs;
  final String message;

  const GenerationProgress({
    required this.nodesVisited,
    required this.linesGenerated,
    required this.currentDepth,
    this.dbCalls = 0,
    this.dbCacheHits = 0,
    this.elapsedMs = 0,
    required this.message,
  });
}
