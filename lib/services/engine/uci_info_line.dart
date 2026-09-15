/// One parsed `info … score …` line from a UCI engine.
///
/// Scores are exactly as the engine reports them: side-to-move relative.
/// Perspective flips belong to the consumer.
class UciInfoLine {
  const UciInfoLine({
    this.depth,
    this.multiPv,
    this.scoreCp,
    this.scoreMate,
    this.nodes,
    this.nps,
    this.pv,
  });

  /// Parse the token stream of one `info` line. Absent fields stay null; a
  /// `depth`, `multipv` or score value that is not an integer also reads as
  /// null, whereas a present but unparseable `nodes`/`nps` reads as 0. When
  /// both a `cp` and a `mate` score appear, the later one wins.
  factory UciInfoLine.parse(String line) {
    final parts = line.split(' ');
    int? depth, multiPv, scoreCp, scoreMate, nodes, nps;
    List<String>? pv;
    for (var i = 0; i < parts.length; i++) {
      final hasNext = i + 1 < parts.length;
      switch (parts[i]) {
        case 'depth' when hasNext:
          depth = int.tryParse(parts[i + 1]);
        case 'multipv' when hasNext:
          multiPv = int.tryParse(parts[i + 1]);
        case 'score' when i + 2 < parts.length:
          final value = int.tryParse(parts[i + 2]);
          if (value != null) {
            switch (parts[i + 1]) {
              case 'cp':
                scoreCp = value;
                scoreMate = null;
              case 'mate':
                scoreMate = value;
                scoreCp = null;
            }
          }
        case 'nodes' when hasNext:
          nodes = int.tryParse(parts[i + 1]) ?? 0;
        case 'nps' when hasNext:
          nps = int.tryParse(parts[i + 1]) ?? 0;
        case 'pv' when hasNext:
          // The principal variation runs to the end of the line.
          return UciInfoLine(
            depth: depth,
            multiPv: multiPv,
            scoreCp: scoreCp,
            scoreMate: scoreMate,
            nodes: nodes,
            nps: nps,
            pv: parts.sublist(i + 1),
          );
      }
    }
    return UciInfoLine(
      depth: depth,
      multiPv: multiPv,
      scoreCp: scoreCp,
      scoreMate: scoreMate,
      nodes: nodes,
      nps: nps,
      pv: pv,
    );
  }

  final int? depth;
  final int? multiPv;

  /// Centipawns, side-to-move relative; null when absent or a mate score.
  final int? scoreCp;

  /// Mate distance, side-to-move relative; null when absent or a cp score.
  final int? scoreMate;
  final int? nodes;
  final int? nps;

  /// Principal variation in UCI, or null when the line carries none.
  final List<String>? pv;
}
