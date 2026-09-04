import '../utils/chess_utils.dart' show formatEvalDisplay;
import '../utils/eval_constants.dart';

class EngineEvaluation {
  final int depth;
  final int? scoreCp; // Centipawns
  final int? scoreMate; // Mate in N
  final List<String> pv; // Best line (UCI format)
  final int nodes;
  final int nps;
  final List<int>?
  wdl; // Win/Draw/Loss probabilities [wins, draws, losses] per 1000

  EngineEvaluation({
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

  /// Human-readable score, `+0.50` / `-1.23` / `#5`.
  String get scoreString =>
      formatEvalDisplay(scoreCp: scoreCp, scoreMate: scoreMate, decimals: 2);

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
