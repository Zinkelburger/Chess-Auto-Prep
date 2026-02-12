/// Data classes for the MultiPV discovery phase of the analysis pool.
library;

/// A single line from the MultiPV discovery search.
class DiscoveryLine {
  final int pvNumber;
  final int depth;
  final int? scoreCp;     // White-normalized
  final int? scoreMate;   // White-normalized
  final List<String> pv;
  final int nodes;
  final int nps;

  const DiscoveryLine({
    required this.pvNumber,
    required this.depth,
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    this.nodes = 0,
    this.nps = 0,
  });

  String get moveUci => pv.isNotEmpty ? pv.first : '';

  int get effectiveCp {
    if (scoreMate != null) {
      return scoreMate! > 0
          ? 10000 - scoreMate!.abs()
          : -(10000 - scoreMate!.abs());
    }
    return scoreCp ?? 0;
  }
}

/// Result of the MultiPV discovery phase.
class DiscoveryResult {
  final List<DiscoveryLine> lines;
  final int depth;
  final int nodes;
  final int nps;

  const DiscoveryResult({
    this.lines = const [],
    this.depth = 0,
    this.nodes = 0,
    this.nps = 0,
  });
}
