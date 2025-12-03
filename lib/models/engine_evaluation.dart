class EngineEvaluation {
  final int depth;
  final int? scoreCp; // Centipawns
  final int? scoreMate; // Mate in N
  final List<String> pv; // Best line (UCI format)
  final int nodes;
  final int nps;
  final List<int>? wdl; // Win/Draw/Loss probabilities [wins, draws, losses] per 1000

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

  /// Get effective centipawn score (converts mate to large cp value)
  int get effectiveCp {
    if (scoreMate != null) {
      return scoreMate! > 0 ? 10000 - scoreMate! : -10000 - scoreMate!;
    }
    return scoreCp ?? 0;
  }

  String get scoreString {
    if (scoreMate != null) {
      return 'M$scoreMate';
    }
    if (scoreCp != null) {
      final double eval = scoreCp! / 100.0;
      return eval > 0 ? '+${eval.toStringAsFixed(2)}' : eval.toStringAsFixed(2);
    }
    return '...';
  }
  
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





