class EngineEvaluation {
  final int depth;
  final int? scoreCp; // Centipawns
  final int? scoreMate; // Mate in N
  final List<String> pv; // Best line
  final int nodes;
  final int nps;

  EngineEvaluation({
    this.depth = 0,
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    this.nodes = 0,
    this.nps = 0,
  });

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
  
  // Basic copyWith
  EngineEvaluation copyWith({
    int? depth,
    int? scoreCp,
    int? scoreMate,
    List<String>? pv,
    int? nodes,
    int? nps,
  }) {
    return EngineEvaluation(
      depth: depth ?? this.depth,
      scoreCp: scoreCp ?? this.scoreCp,
      scoreMate: scoreMate ?? this.scoreMate,
      pv: pv ?? this.pv,
      nodes: nodes ?? this.nodes,
      nps: nps ?? this.nps,
    );
  }
}


