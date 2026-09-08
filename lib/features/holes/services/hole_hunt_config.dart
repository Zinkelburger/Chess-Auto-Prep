/// Configuration for an adversarial hole hunt over an opening tree
/// (a player's games in Player Analysis, or an imported repertoire file).
///
/// The hunt walks the tree from the attacker's side. Stockfish finds the
/// objective holes — strong attacker moves with no reply on file, and owner
/// moves with a verified refutation. The same discovery feeds a trick
/// search: near-best attacker moves and novelties are probed a few ply deep
/// with Maia expectimax, and reported when they score better in practice
/// than the engine-best move.
library;

class HoleHuntConfig {
  // ── Tree walk ────────────────────────────────────────────────────────

  /// Stockfish depth for MultiPV discovery at each node.
  final int discoveryDepth;

  /// MultiPV width for discovery.
  final int discoveryMultiPv;

  /// Maximum ply from root to walk.
  final int maxPly;

  /// An uncovered attacker move must be within this many cp of the engine
  /// best to be flagged.
  final int strongMoveWindowCp;

  /// Attacker-perspective eval floor: uncovered moves below this are not
  /// flagged at all (no point flagging strong-but-losing tries).
  final int uncoveredMinAdvantageCp;

  /// Gain floor added to uncovered-move scores so near-equal engine moves
  /// that take the owner out of book still rank.
  final int outOfBookBonusCp;

  /// Owner eval loss vs engine best (cp) to flag a repertoire move as
  /// refutable.
  final int refutationThresholdCp;

  /// Single-PV Stockfish depth used to verify a refutation and extract
  /// its PV.
  final int verifyDepth;

  // ── Trick probes ─────────────────────────────────────────────────────

  /// A trick candidate must be within this many cp of the engine best
  /// (attacker perspective) — the objective price cap for a trick.
  final int candidateWindowCp;

  /// Total number of candidates probed with a mini expectimax build. Also
  /// caps how many attacker-to-move leaves get discovery after the walk
  /// (most reachable first), which is where the hunt reaches past the
  /// recorded games. Zero turns the trick search off.
  final int probeBudget;

  /// Probe tree depth in plies past the candidate move.
  final int probePly;

  /// Stockfish eval depth inside probe builds.
  final int probeEvalDepth;

  /// Minimum net gain (probe practical eval minus the best move's raw eval,
  /// cp) for a candidate to be reported. Net gain already charges the trick
  /// its objective cost, so a tricky-but-still-worse move never surfaces.
  final int minNetGainCp;

  /// Maia ELO modeling the repertoire owner's practical replies.
  final int maiaElo;

  const HoleHuntConfig({
    this.discoveryDepth = 14,
    this.discoveryMultiPv = 4,
    this.maxPly = 30,
    this.strongMoveWindowCp = 30,
    this.uncoveredMinAdvantageCp = -25,
    this.outOfBookBonusCp = 50,
    this.refutationThresholdCp = 80,
    this.verifyDepth = 20,
    this.candidateWindowCp = 60,
    this.probeBudget = 24,
    this.probePly = 4,
    this.probeEvalDepth = 12,
    this.minNetGainCp = 40,
    this.maiaElo = 2000,
  });

  Map<String, dynamic> toMap() => {
    'discoveryDepth': discoveryDepth,
    'discoveryMultiPv': discoveryMultiPv,
    'maxPly': maxPly,
    'strongMoveWindowCp': strongMoveWindowCp,
    'uncoveredMinAdvantageCp': uncoveredMinAdvantageCp,
    'outOfBookBonusCp': outOfBookBonusCp,
    'refutationThresholdCp': refutationThresholdCp,
    'verifyDepth': verifyDepth,
    'candidateWindowCp': candidateWindowCp,
    'probeBudget': probeBudget,
    'probePly': probePly,
    'probeEvalDepth': probeEvalDepth,
    'minNetGainCp': minNetGainCp,
    'maiaElo': maiaElo,
  };

  factory HoleHuntConfig.fromMap(Map<String, dynamic> m) => HoleHuntConfig(
    discoveryDepth: m['discoveryDepth'] as int? ?? 14,
    discoveryMultiPv: m['discoveryMultiPv'] as int? ?? 4,
    maxPly: m['maxPly'] as int? ?? 30,
    strongMoveWindowCp: m['strongMoveWindowCp'] as int? ?? 30,
    uncoveredMinAdvantageCp: m['uncoveredMinAdvantageCp'] as int? ?? -25,
    outOfBookBonusCp: m['outOfBookBonusCp'] as int? ?? 50,
    refutationThresholdCp: m['refutationThresholdCp'] as int? ?? 80,
    verifyDepth: m['verifyDepth'] as int? ?? 20,
    candidateWindowCp: m['candidateWindowCp'] as int? ?? 60,
    probeBudget: m['probeBudget'] as int? ?? 24,
    probePly: m['probePly'] as int? ?? 4,
    probeEvalDepth: m['probeEvalDepth'] as int? ?? 12,
    minNetGainCp: m['minNetGainCp'] as int? ?? 40,
    maiaElo: m['maiaElo'] as int? ?? 2000,
  );

  /// Compact one-line summary for display next to a saved report.
  String get summaryLabel =>
      'SF d$discoveryDepth mpv$discoveryMultiPv · ${maxPly}ply · '
      'refute≥${refutationThresholdCp}cp · '
      '$probeBudget probes ×${probePly}ply · '
      'net≥${minNetGainCp}cp';

  HoleHuntConfig copyWith({
    int? discoveryDepth,
    int? discoveryMultiPv,
    int? maxPly,
    int? strongMoveWindowCp,
    int? uncoveredMinAdvantageCp,
    int? outOfBookBonusCp,
    int? refutationThresholdCp,
    int? verifyDepth,
    int? candidateWindowCp,
    int? probeBudget,
    int? probePly,
    int? probeEvalDepth,
    int? minNetGainCp,
    int? maiaElo,
  }) {
    return HoleHuntConfig(
      discoveryDepth: discoveryDepth ?? this.discoveryDepth,
      discoveryMultiPv: discoveryMultiPv ?? this.discoveryMultiPv,
      maxPly: maxPly ?? this.maxPly,
      strongMoveWindowCp: strongMoveWindowCp ?? this.strongMoveWindowCp,
      uncoveredMinAdvantageCp:
          uncoveredMinAdvantageCp ?? this.uncoveredMinAdvantageCp,
      outOfBookBonusCp: outOfBookBonusCp ?? this.outOfBookBonusCp,
      refutationThresholdCp:
          refutationThresholdCp ?? this.refutationThresholdCp,
      verifyDepth: verifyDepth ?? this.verifyDepth,
      candidateWindowCp: candidateWindowCp ?? this.candidateWindowCp,
      probeBudget: probeBudget ?? this.probeBudget,
      probePly: probePly ?? this.probePly,
      probeEvalDepth: probeEvalDepth ?? this.probeEvalDepth,
      minNetGainCp: minNetGainCp ?? this.minNetGainCp,
      maiaElo: maiaElo ?? this.maiaElo,
    );
  }
}
