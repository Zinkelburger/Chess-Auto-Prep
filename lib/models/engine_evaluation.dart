import '../utils/eval_constants.dart';

/// One engine search result: score, depth and principal variation.
class EngineEvaluation {
  final int depth;

  /// Centipawns, or null when the score is a mate.
  final int? scoreCp;

  /// Mate in N, or null when the score is in centipawns.
  final int? scoreMate;

  /// Best line, in UCI.
  final List<String> pv;
  final int nodes;
  final int nps;

  /// Win/draw/loss probabilities `[wins, draws, losses]` per 1000.
  final List<int>? wdl;

  const EngineEvaluation({
    this.depth = 0,
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    this.nodes = 0,
    this.nps = 0,
    this.wdl,
  });

  /// Get the best move from the principal variation (first move in PV)
  String? get bestMove => pv.isNotEmpty ? pv.first : null;

  /// Collapse mate / cp into a single comparable centipawn value.
  int get effectiveCp =>
      effectiveCpFromScores(scoreCp: scoreCp, scoreMate: scoreMate);

  EngineEvaluation copyWith({
    int? depth,
    int? scoreCp,
    int? scoreMate,
    List<String>? pv,
    int? nodes,
    int? nps,
    List<int>? wdl,
  }) {
    return EngineEvaluation(
      depth: depth ?? this.depth,
      scoreCp: scoreCp ?? this.scoreCp,
      scoreMate: scoreMate ?? this.scoreMate,
      pv: pv ?? this.pv,
      nodes: nodes ?? this.nodes,
      nps: nps ?? this.nps,
      wdl: wdl ?? this.wdl,
    );
  }
}
