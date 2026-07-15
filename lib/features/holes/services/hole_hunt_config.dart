/// Configuration for an adversarial hole hunt over a loaded repertoire.
library;

class HoleHuntConfig {
  /// Framing only: true = "attack this repertoire" (find holes to exploit),
  /// false = "stress-test my own repertoire". The math is identical either
  /// way — the attacker is always the side opposite the repertoire's color.
  final bool attackerIsUser;

  // ── Pass 1: tree walk ────────────────────────────────────────────────

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

  // ── Pass 2: leaf expectimax ──────────────────────────────────────────

  /// Number of top-reach-probability leaves to expectimax.
  final int trapLeafCount;

  /// Expectimax tree depth (plies past the leaf).
  final int trapSearchPly;

  /// Stockfish eval depth inside trap builds.
  final int trapEvalDepth;

  /// Minimum practical-vs-raw eval gap (cp, attacker perspective) to flag
  /// a leaf as a practical trap.
  final int practicalGapThresholdCp;

  /// Maia ELO modeling the repertoire owner's practical play.
  final int maiaElo;

  /// Whether trap builds may blend Lichess Explorer stats into the
  /// opponent model.
  final bool useLichessInTraps;

  // ── Report ───────────────────────────────────────────────────────────

  /// Default cap on findings shown in the report panel.
  final int maxReportSize;

  const HoleHuntConfig({
    this.attackerIsUser = true,
    this.discoveryDepth = 14,
    this.discoveryMultiPv = 4,
    this.maxPly = 30,
    this.strongMoveWindowCp = 30,
    this.uncoveredMinAdvantageCp = -25,
    this.outOfBookBonusCp = 50,
    this.refutationThresholdCp = 80,
    this.verifyDepth = 20,
    this.trapLeafCount = 12,
    this.trapSearchPly = 6,
    this.trapEvalDepth = 12,
    this.practicalGapThresholdCp = 60,
    this.maiaElo = 2000,
    this.useLichessInTraps = true,
    this.maxReportSize = 10,
  });

  Map<String, dynamic> toMap() => {
        'attackerIsUser': attackerIsUser,
        'discoveryDepth': discoveryDepth,
        'discoveryMultiPv': discoveryMultiPv,
        'maxPly': maxPly,
        'strongMoveWindowCp': strongMoveWindowCp,
        'uncoveredMinAdvantageCp': uncoveredMinAdvantageCp,
        'outOfBookBonusCp': outOfBookBonusCp,
        'refutationThresholdCp': refutationThresholdCp,
        'verifyDepth': verifyDepth,
        'trapLeafCount': trapLeafCount,
        'trapSearchPly': trapSearchPly,
        'trapEvalDepth': trapEvalDepth,
        'practicalGapThresholdCp': practicalGapThresholdCp,
        'maiaElo': maiaElo,
        'useLichessInTraps': useLichessInTraps,
        'maxReportSize': maxReportSize,
      };

  factory HoleHuntConfig.fromMap(Map<String, dynamic> m) => HoleHuntConfig(
        attackerIsUser: m['attackerIsUser'] as bool? ?? true,
        discoveryDepth: m['discoveryDepth'] as int? ?? 14,
        discoveryMultiPv: m['discoveryMultiPv'] as int? ?? 4,
        maxPly: m['maxPly'] as int? ?? 30,
        strongMoveWindowCp: m['strongMoveWindowCp'] as int? ?? 30,
        uncoveredMinAdvantageCp: m['uncoveredMinAdvantageCp'] as int? ?? -25,
        outOfBookBonusCp: m['outOfBookBonusCp'] as int? ?? 50,
        refutationThresholdCp: m['refutationThresholdCp'] as int? ?? 80,
        verifyDepth: m['verifyDepth'] as int? ?? 20,
        trapLeafCount: m['trapLeafCount'] as int? ?? 12,
        trapSearchPly: m['trapSearchPly'] as int? ?? 6,
        trapEvalDepth: m['trapEvalDepth'] as int? ?? 12,
        practicalGapThresholdCp: m['practicalGapThresholdCp'] as int? ?? 60,
        maiaElo: m['maiaElo'] as int? ?? 2000,
        useLichessInTraps: m['useLichessInTraps'] as bool? ?? true,
        maxReportSize: m['maxReportSize'] as int? ?? 10,
      );

  /// Compact one-line summary for display in the Jobs tab.
  String get summaryLabel =>
      'SF d$discoveryDepth mpv$discoveryMultiPv · ${maxPly}ply · '
      'refute≥${refutationThresholdCp}cp · '
      '$trapLeafCount leaves ×${trapSearchPly}ply · '
      'gap≥${practicalGapThresholdCp}cp';

  HoleHuntConfig copyWith({
    bool? attackerIsUser,
    int? discoveryDepth,
    int? discoveryMultiPv,
    int? maxPly,
    int? strongMoveWindowCp,
    int? uncoveredMinAdvantageCp,
    int? outOfBookBonusCp,
    int? refutationThresholdCp,
    int? verifyDepth,
    int? trapLeafCount,
    int? trapSearchPly,
    int? trapEvalDepth,
    int? practicalGapThresholdCp,
    int? maiaElo,
    bool? useLichessInTraps,
    int? maxReportSize,
  }) {
    return HoleHuntConfig(
      attackerIsUser: attackerIsUser ?? this.attackerIsUser,
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
      trapLeafCount: trapLeafCount ?? this.trapLeafCount,
      trapSearchPly: trapSearchPly ?? this.trapSearchPly,
      trapEvalDepth: trapEvalDepth ?? this.trapEvalDepth,
      practicalGapThresholdCp:
          practicalGapThresholdCp ?? this.practicalGapThresholdCp,
      maiaElo: maiaElo ?? this.maiaElo,
      useLichessInTraps: useLichessInTraps ?? this.useLichessInTraps,
      maxReportSize: maxReportSize ?? this.maxReportSize,
    );
  }
}
