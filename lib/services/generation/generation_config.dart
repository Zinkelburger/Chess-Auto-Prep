/// Configuration and output types for repertoire generation.
library;

// ── Selection mode ──────────────────────────────────────────────────────

enum SelectionMode {
  expectimax,
  engineOnly,
  dbWinRateOnly,
}

// ── Two-phase tree build config (matches C tree_builder) ────────────────

/// Configuration for the two-phase tree build algorithm.
///
/// Phase 1 builds a persistent tree with all evals.  Phase 2 computes
/// ease/expectimax and selects repertoire moves.
class TreeBuildConfig {
  final String startFen;
  final bool playAsWhite;

  // ── Traversal limits ──
  final double minProbability;
  final int maxPly;
  final int maxNodes;

  // ── Engine ──
  final int evalDepth;

  // ── Our-move MultiPV (constant at every depth, matches C invariant) ──
  final int ourMultipv;
  final int maxEvalLossCp;

  // ── Opponent-move selection (constant at every depth) ──
  final int oppMaxChildren;
  final double oppMassTarget;

  // ── Eval window pruning ──
  final int minEvalCp;
  final int maxEvalCp;
  final bool relativeEval;

  // ── Lichess API ──
  final bool useLichessDb;
  final bool useMasters;
  final String ratingRange;
  final String speeds;
  final int minGames;

  // ── Maia ──
  final int maiaElo;
  final double maiaMinProb;
  final bool maiaOnly;

  // ── Expectimax / repertoire selection ──
  final SelectionMode selectionMode;
  final double leafConfidence;
  final int noveltyWeight;

  const TreeBuildConfig({
    required this.startFen,
    required this.playAsWhite,
    this.minProbability = 0.0001,
    this.maxPly = 10,
    this.maxNodes = 0,
    this.evalDepth = 20,
    this.ourMultipv = 5,
    this.maxEvalLossCp = 50,
    this.oppMaxChildren = 6,
    this.oppMassTarget = 0.95,
    this.minEvalCp = 0,
    this.maxEvalCp = 200,
    this.relativeEval = false,
    this.useLichessDb = false,
    this.useMasters = false,
    this.ratingRange = '2000,2200,2500',
    this.speeds = 'blitz,rapid,classical',
    this.minGames = 10,
    this.maiaElo = 2200,
    this.maiaMinProb = 0.05,
    this.maiaOnly = true,
    this.selectionMode = SelectionMode.expectimax,
    this.leafConfidence = 1.0,
    this.noveltyWeight = 0,
  });

  factory TreeBuildConfig.fromJson(
    Map<String, dynamic> json, {
    required String startFen,
  }) {
    return TreeBuildConfig(
      startFen: startFen,
      playAsWhite: json['play_as_white'] as bool? ?? true,
      minProbability: (json['min_probability'] as num?)?.toDouble() ?? 0.0001,
      maxPly: (json['max_depth'] as num?)?.toInt() ?? 10,
      maxNodes: (json['max_nodes'] as num?)?.toInt() ?? 0,
      evalDepth: (json['eval_depth'] as num?)?.toInt() ?? 20,
      ourMultipv: (json['our_multipv'] as num?)?.toInt() ?? 5,
      maxEvalLossCp: (json['max_eval_loss_cp'] as num?)?.toInt() ?? 50,
      oppMaxChildren: (json['opp_max_children'] as num?)?.toInt() ?? 6,
      oppMassTarget: (json['opp_mass_target'] as num?)?.toDouble() ?? 0.95,
      minEvalCp: (json['min_eval_cp'] as num?)?.toInt() ?? 0,
      maxEvalCp: (json['max_eval_cp'] as num?)?.toInt() ?? 200,
      relativeEval: json['relative_eval'] as bool? ?? false,
      useLichessDb: json['use_lichess_db'] as bool? ?? false,
      useMasters: json['use_masters'] as bool? ?? false,
      ratingRange: json['rating_range'] as String? ?? '2000,2200,2500',
      speeds: json['speeds'] as String? ?? 'blitz,rapid,classical',
      minGames: (json['min_games'] as num?)?.toInt() ?? 10,
      maiaElo: (json['maia_elo'] as num?)?.toInt() ?? 2200,
      maiaMinProb: (json['maia_min_prob'] as num?)?.toDouble() ?? 0.05,
      maiaOnly: json['maia_only'] as bool? ?? true,
      selectionMode: _parseSelectionMode(json['selection_mode'] as String?),
      leafConfidence: (json['leaf_confidence'] as num?)?.toDouble() ?? 1.0,
      noveltyWeight: (json['novelty_weight'] as num?)?.toInt() ?? 0,
    );
  }

  /// Quick eval depth for the repertoire selection phase.
  int get quickEvalDepth => evalDepth > 15 ? 15 : evalDepth;

  /// Convert a white-perspective centipawn score to "our" perspective.
  int toOurPerspective(int whiteCp) => playAsWhite ? whiteCp : -whiteCp;

  /// Serialise to a JSON-compatible map for tree file metadata.
  Map<String, dynamic> toJson() => {
    'play_as_white': playAsWhite,
    'min_probability': minProbability,
    'max_depth': maxPly,
    'max_nodes': maxNodes,
    'eval_depth': evalDepth,
    'our_multipv': ourMultipv,
    'max_eval_loss_cp': maxEvalLossCp,
    'opp_max_children': oppMaxChildren,
    'opp_mass_target': oppMassTarget,
    'min_eval_cp': minEvalCp,
    'max_eval_cp': maxEvalCp,
    'relative_eval': relativeEval,
    'use_lichess_db': useLichessDb,
    'use_masters': useMasters,
    'rating_range': ratingRange,
    'speeds': speeds,
    'min_games': minGames,
    'maia_elo': maiaElo,
    'maia_min_prob': maiaMinProb,
    'maia_only': maiaOnly,
    'selection_mode': selectionMode.name,
    'leaf_confidence': leafConfidence,
    'novelty_weight': noveltyWeight,
  };
}

SelectionMode _parseSelectionMode(String? value) {
  switch (value) {
    case 'engineOnly':
      return SelectionMode.engineOnly;
    case 'dbWinRateOnly':
      return SelectionMode.dbWinRateOnly;
    default:
      return SelectionMode.expectimax;
  }
}
