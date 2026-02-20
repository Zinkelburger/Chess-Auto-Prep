/// Configuration, output types, and strategy enum for repertoire generation.
library;

// ── Strategy enum ────────────────────────────────────────────────────────

enum GenerationStrategy {
  engineOnly,
  winRateOnly,
  metaEval,
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
  final double metaAlpha;
  final int maiaElo;

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
    this.metaAlpha = 0.35,
    this.maiaElo = 2100,
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
  final double metaEase;

  const GeneratedLine({
    required this.movesSan,
    required this.cumulativeProbability,
    required this.finalEvalWhiteCp,
    required this.metaEase,
  });
}

class GenerationProgress {
  final int nodesVisited;
  final int linesGenerated;
  final int currentDepth;
  final String message;

  const GenerationProgress({
    required this.nodesVisited,
    required this.linesGenerated,
    required this.currentDepth,
    required this.message,
  });
}
