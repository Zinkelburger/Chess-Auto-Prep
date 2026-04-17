/// Configuration and output types for repertoire generation.
library;

import 'dart:math' show log, pow;

// ── Build estimate ──────────────────────────────────────────────────────

class BuildEstimate {
  final int estimatedNodes;
  final double estimatedSeconds;
  final double effectiveBranchingFactor;
  final int effectiveDepth;

  const BuildEstimate({
    required this.estimatedNodes,
    required this.estimatedSeconds,
    required this.effectiveBranchingFactor,
    required this.effectiveDepth,
  });

  /// Human-readable time range (shows ×0.5 to ×2 of the estimate since
  /// the pre-build number is inherently rough).
  String get formattedTime {
    if (estimatedSeconds < 90) return '< 2 min';
    if (estimatedSeconds < 3600) {
      final mins = estimatedSeconds / 60;
      final lo = (mins * 0.5).ceil();
      final hi = (mins * 2.0).ceil();
      return '~$lo\u2013$hi min';
    }
    final hours = estimatedSeconds / 3600;
    final lo = (hours * 0.5);
    final hi = (hours * 2.0);
    String fmt(double h) => h < 10 ? h.toStringAsFixed(1) : '${h.round()}';
    return '~${fmt(lo)}\u2013${fmt(hi)} hrs';
  }
}

// ── Presets ──────────────────────────────────────────────────────────────

/// Preset modes that adjust eval tolerance and novelty weight.
/// Matches the C tree_builder's --solid / --practical / --tricky /
/// --traps / --fresh presets.
enum BuildPreset { none, solid, practical, tricky, traps, fresh }

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
  final int maxDepth;
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
  final double leafConfidence;
  final int noveltyWeight;

  const TreeBuildConfig({
    required this.startFen,
    required this.playAsWhite,
    this.minProbability = 0.0001,
    this.maxDepth = 10,
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
      maxDepth: (json['max_depth'] as num?)?.toInt() ?? 10,
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
      leafConfidence: (json['leaf_confidence'] as num?)?.toDouble() ?? 1.0,
      noveltyWeight: (json['novelty_weight'] as num?)?.toInt() ?? 0,
    );
  }

  /// Quick eval depth for the repertoire selection phase.
  int get quickEvalDepth => evalDepth > 15 ? 15 : evalDepth;

  /// Convert a white-perspective centipawn score to "our" perspective.
  int toOurPerspective(int whiteCp) => playAsWhite ? whiteCp : -whiteCp;

  /// Apply a preset, filling only fields the user hasn't overridden.
  TreeBuildConfig withPreset(BuildPreset preset) {
    if (preset == BuildPreset.none) return this;
    int newMinEval = minEvalCp;
    int newMaxEvalLoss = maxEvalLossCp;
    int newNovelty = noveltyWeight;

    switch (preset) {
      case BuildPreset.solid:
        newMinEval = playAsWhite ? 0 : -100;
        newMaxEvalLoss = 30;
      case BuildPreset.practical:
        newMinEval = playAsWhite ? -25 : -200;
        newMaxEvalLoss = 50;
      case BuildPreset.tricky:
        newMinEval = playAsWhite ? -50 : -250;
        newMaxEvalLoss = 75;
      case BuildPreset.traps:
        newMinEval = playAsWhite ? -100 : -300;
        newMaxEvalLoss = 100;
      case BuildPreset.fresh:
        newNovelty = 60;
        newMaxEvalLoss = 40;
      case BuildPreset.none:
        break;
    }

    return TreeBuildConfig(
      startFen: startFen, playAsWhite: playAsWhite,
      minProbability: minProbability, maxDepth: maxDepth,
      maxNodes: maxNodes, evalDepth: evalDepth,
      ourMultipv: ourMultipv,
      maxEvalLossCp: newMaxEvalLoss,
      oppMaxChildren: oppMaxChildren, oppMassTarget: oppMassTarget,
      minEvalCp: newMinEval, maxEvalCp: maxEvalCp,
      relativeEval: relativeEval,
      useLichessDb: useLichessDb, useMasters: useMasters,
      ratingRange: ratingRange, speeds: speeds, minGames: minGames,
      maiaElo: maiaElo, maiaMinProb: maiaMinProb, maiaOnly: maiaOnly,
      leafConfidence: leafConfidence, noveltyWeight: newNovelty,
    );
  }

  /// Estimate total nodes before any work is done.
  ///
  /// Uses simple branching-factor math: nodes ≈ b^d.
  ///
  /// Anchor: Caro-Kann (e4 c6 d4 d5 e5 Bf5) with default settings
  /// (multipv=5, evalLoss=50, oppMax=6, mass=0.95, minProb=0.0001)
  /// at depth 10 → 114,929 nodes, b = 3.22  (from analysis_10ply.db).
  ///
  /// Config params that widen the search scale b up; tighter ones
  /// scale it down.  No time estimate pre-build — we can't know
  /// per-node cost until the build starts and measures hardware speed.
  BuildEstimate estimateBuild() {
    // Anchor: default settings, depth 10, 114929 nodes → b ≈ 3.22
    const double baseB = 3.22;

    // Scale b relative to default config values.
    final ourScale = pow(ourMultipv / 5.0, 0.15).toDouble() *
                     pow(maxEvalLossCp / 50.0, 0.2).toDouble();
    final oppScale = pow(oppMaxChildren / 6.0, 0.2).toDouble() *
                     pow(oppMassTarget / 0.95, 0.15).toDouble();

    // Wider eval window lets more subtrees survive.
    final evalWindow = (maxEvalCp - minEvalCp).abs().clamp(100, 800);
    final windowScale = pow(evalWindow / 200.0, 0.1).toDouble();

    final b = (baseB * ourScale * oppScale * windowScale).clamp(1.5, 6.0);

    // Effective depth: min of maxDepth and probability-limited depth.
    final avgOppProb = oppMaxChildren > 1
        ? oppMassTarget / oppMaxChildren : 0.5;
    int effDepth = maxDepth;
    if (minProbability > 0 && avgOppProb > 0 && avgOppProb < 1.0) {
      final oppPlies = -log(minProbability) / -log(avgOppProb);
      final pd = (oppPlies * 2).round();
      if (pd < effDepth) effDepth = pd;
    }

    var estNodes = pow(b, effDepth).round().clamp(
        50, maxNodes > 0 ? maxNodes : 500000);

    return BuildEstimate(
      estimatedNodes: estNodes,
      estimatedSeconds: 0,
      effectiveBranchingFactor: b,
      effectiveDepth: effDepth,
    );
  }

  /// Serialise to a JSON-compatible map for tree file metadata.
  Map<String, dynamic> toJson() => {
    'play_as_white': playAsWhite,
    'min_probability': minProbability,
    'max_depth': maxDepth,
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
    'leaf_confidence': leafConfidence,
    'novelty_weight': noveltyWeight,
  };
}
