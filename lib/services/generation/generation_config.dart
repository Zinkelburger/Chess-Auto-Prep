/// Configuration, output types, and strategy enum for repertoire generation.
library;

// ── Strategy enum ────────────────────────────────────────────────────────

enum GenerationStrategy {
  engineOnly,
  winRateOnly,
  eca,
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
    this.maiaElo = 2100,
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
