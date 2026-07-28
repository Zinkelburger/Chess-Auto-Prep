/// Configuration for a trick hunt over an opening tree (a player's games in
/// Player Analysis, or an imported repertoire/course file).
///
/// The hunt walks every position where the trickster — the side opposite the
/// tree's owner — is to move, discovers near-best engine alternatives, and
/// probes the most reachable ones a few ply deep with expectimax to find
/// moves that score better in practice than the engine-best move.
library;

class TrickHuntConfig {
  // ── Stage A: tree walk (engine-free) ─────────────────────────────────

  /// Maximum ply from root to walk.
  final int maxPly;

  /// Positions below this reach probability never get engine discovery.
  final double minReachProb;

  /// Cap on trickster positions that get MultiPV discovery, taken in
  /// descending reach order.
  final int maxDiscoveryNodes;

  // ── Stage B: candidate discovery ─────────────────────────────────────

  /// Stockfish depth for MultiPV discovery at each position.
  final int discoveryDepth;

  /// MultiPV width for discovery.
  final int discoveryMultiPv;

  /// A candidate must be within this many cp of the engine best (trickster
  /// perspective) to be considered — the objective price cap for a trick.
  final int candidateWindowCp;

  /// At most this many candidates per position enter the probe pool, so one
  /// hot position cannot eat the whole probe budget. An in-tree move that
  /// made the window is always kept in addition.
  final int maxCandidatesPerNode;

  // ── Stage C: expectimax probes ───────────────────────────────────────

  /// Total number of candidates probed with a mini expectimax build.
  final int probeBudget;

  /// Probe tree depth in plies past the candidate move.
  final int probePly;

  /// Stockfish eval depth inside probe builds.
  final int probeEvalDepth;

  /// Wall-clock budget per probe build, in seconds.
  final int probeTimeoutSeconds;

  /// Maia ELO modeling the tree owner's practical replies.
  final int maiaElo;

  /// Whether probe builds may blend Lichess Explorer stats into the
  /// opponent model (falls back to Maia off the explorer's book).
  final bool useLichessInProbes;

  // ── Thresholds ───────────────────────────────────────────────────────

  /// Minimum net gain (probe practical eval minus the best move's raw eval,
  /// cp) for a candidate to be reported. Net gain already charges the trick
  /// its objective cost, so a tricky-but-still-worse move never surfaces.
  final int minNetGainCp;

  const TrickHuntConfig({
    this.maxPly = 30,
    this.minReachProb = 0.005,
    this.maxDiscoveryNodes = 200,
    this.discoveryDepth = 14,
    this.discoveryMultiPv = 4,
    this.candidateWindowCp = 60,
    this.maxCandidatesPerNode = 3,
    this.probeBudget = 24,
    this.probePly = 4,
    this.probeEvalDepth = 12,
    this.probeTimeoutSeconds = 60,
    this.maiaElo = 2000,
    this.useLichessInProbes = true,
    this.minNetGainCp = 40,
  });

  Map<String, dynamic> toMap() => {
    'maxPly': maxPly,
    'minReachProb': minReachProb,
    'maxDiscoveryNodes': maxDiscoveryNodes,
    'discoveryDepth': discoveryDepth,
    'discoveryMultiPv': discoveryMultiPv,
    'candidateWindowCp': candidateWindowCp,
    'maxCandidatesPerNode': maxCandidatesPerNode,
    'probeBudget': probeBudget,
    'probePly': probePly,
    'probeEvalDepth': probeEvalDepth,
    'probeTimeoutSeconds': probeTimeoutSeconds,
    'maiaElo': maiaElo,
    'useLichessInProbes': useLichessInProbes,
    'minNetGainCp': minNetGainCp,
  };

  factory TrickHuntConfig.fromMap(Map<String, dynamic> m) => TrickHuntConfig(
    maxPly: m['maxPly'] as int? ?? 30,
    minReachProb: (m['minReachProb'] as num?)?.toDouble() ?? 0.005,
    maxDiscoveryNodes: m['maxDiscoveryNodes'] as int? ?? 200,
    discoveryDepth: m['discoveryDepth'] as int? ?? 14,
    discoveryMultiPv: m['discoveryMultiPv'] as int? ?? 4,
    candidateWindowCp: m['candidateWindowCp'] as int? ?? 60,
    maxCandidatesPerNode: m['maxCandidatesPerNode'] as int? ?? 3,
    probeBudget: m['probeBudget'] as int? ?? 24,
    probePly: m['probePly'] as int? ?? 4,
    probeEvalDepth: m['probeEvalDepth'] as int? ?? 12,
    probeTimeoutSeconds: m['probeTimeoutSeconds'] as int? ?? 60,
    maiaElo: m['maiaElo'] as int? ?? 2000,
    useLichessInProbes: m['useLichessInProbes'] as bool? ?? true,
    minNetGainCp: m['minNetGainCp'] as int? ?? 40,
  );

  /// Compact one-line summary for display next to a saved report.
  String get summaryLabel =>
      'SF d$discoveryDepth mpv$discoveryMultiPv · '
      '≤${candidateWindowCp}cp off best · '
      '$probeBudget probes ×${probePly}ply · '
      'net≥${minNetGainCp}cp';

  TrickHuntConfig copyWith({
    int? maxPly,
    double? minReachProb,
    int? maxDiscoveryNodes,
    int? discoveryDepth,
    int? discoveryMultiPv,
    int? candidateWindowCp,
    int? maxCandidatesPerNode,
    int? probeBudget,
    int? probePly,
    int? probeEvalDepth,
    int? probeTimeoutSeconds,
    int? maiaElo,
    bool? useLichessInProbes,
    int? minNetGainCp,
  }) {
    return TrickHuntConfig(
      maxPly: maxPly ?? this.maxPly,
      minReachProb: minReachProb ?? this.minReachProb,
      maxDiscoveryNodes: maxDiscoveryNodes ?? this.maxDiscoveryNodes,
      discoveryDepth: discoveryDepth ?? this.discoveryDepth,
      discoveryMultiPv: discoveryMultiPv ?? this.discoveryMultiPv,
      candidateWindowCp: candidateWindowCp ?? this.candidateWindowCp,
      maxCandidatesPerNode: maxCandidatesPerNode ?? this.maxCandidatesPerNode,
      probeBudget: probeBudget ?? this.probeBudget,
      probePly: probePly ?? this.probePly,
      probeEvalDepth: probeEvalDepth ?? this.probeEvalDepth,
      probeTimeoutSeconds: probeTimeoutSeconds ?? this.probeTimeoutSeconds,
      maiaElo: maiaElo ?? this.maiaElo,
      useLichessInProbes: useLichessInProbes ?? this.useLichessInProbes,
      minNetGainCp: minNetGainCp ?? this.minNetGainCp,
    );
  }
}
