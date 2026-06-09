/// Configuration for a repertoire audit pass.
library;

class AuditConfig {
  /// Centipawn loss threshold to flag a move as a mistake.
  final int mistakeThresholdCp;

  /// Centipawn loss threshold to flag a move as an inaccuracy
  /// (must be less than [mistakeThresholdCp]).
  final int inaccuracyThresholdCp;

  /// Minimum Lichess Explorer game count for a missing opponent response
  /// to be flagged.
  final int minGames;

  /// Minimum Maia probability (0.0–1.0) for a missing response to be flagged.
  final double minMaiaProb;

  /// Absolute eval threshold (white-normalized cp, from our perspective)
  /// below which a position is flagged as weak.
  /// E.g. -100 means we flag positions where we're down 1 pawn.
  final int weakPositionThresholdCp;

  /// Minimum opponent continuations at a leaf to flag a dead end.
  final int deadEndMinContinuations;

  /// Stockfish search depth for evaluating our moves.
  final int evalDepth;

  /// Maximum ply from root (or subtree start) to audit.
  final int maxPly;

  /// Maia ELO for opponent modeling.
  final int maiaElo;

  /// Whether to use Stockfish for our-move quality checks.
  final bool useStockfish;

  /// Whether to use the Lichess Explorer for missing opponent responses.
  final bool useLichessDb;

  /// Whether to use Maia for missing opponent responses.
  final bool useMaia;

  /// Lichess Explorer configuration.
  final String explorerSpeeds;
  final String explorerRatings;

  /// Number of MultiPV lines for Stockfish discovery.
  final int multiPv;

  const AuditConfig({
    this.mistakeThresholdCp = 100,
    this.inaccuracyThresholdCp = 40,
    this.minGames = 50,
    this.minMaiaProb = 0.10,
    this.weakPositionThresholdCp = -150,
    this.deadEndMinContinuations = 2,
    this.evalDepth = 14,
    this.maxPly = 30,
    this.maiaElo = 2200,
    this.useStockfish = true,
    this.useLichessDb = true,
    this.useMaia = true,
    this.explorerSpeeds = 'blitz,rapid,classical',
    this.explorerRatings = '1800,2000,2200,2500',
    this.multiPv = 3,
  });

  AuditConfig copyWith({
    int? mistakeThresholdCp,
    int? inaccuracyThresholdCp,
    int? minGames,
    double? minMaiaProb,
    int? weakPositionThresholdCp,
    int? deadEndMinContinuations,
    int? evalDepth,
    int? maxPly,
    int? maiaElo,
    bool? useStockfish,
    bool? useLichessDb,
    bool? useMaia,
    String? explorerSpeeds,
    String? explorerRatings,
    int? multiPv,
  }) {
    return AuditConfig(
      mistakeThresholdCp: mistakeThresholdCp ?? this.mistakeThresholdCp,
      inaccuracyThresholdCp:
          inaccuracyThresholdCp ?? this.inaccuracyThresholdCp,
      minGames: minGames ?? this.minGames,
      minMaiaProb: minMaiaProb ?? this.minMaiaProb,
      weakPositionThresholdCp:
          weakPositionThresholdCp ?? this.weakPositionThresholdCp,
      deadEndMinContinuations:
          deadEndMinContinuations ?? this.deadEndMinContinuations,
      evalDepth: evalDepth ?? this.evalDepth,
      maxPly: maxPly ?? this.maxPly,
      maiaElo: maiaElo ?? this.maiaElo,
      useStockfish: useStockfish ?? this.useStockfish,
      useLichessDb: useLichessDb ?? this.useLichessDb,
      useMaia: useMaia ?? this.useMaia,
      explorerSpeeds: explorerSpeeds ?? this.explorerSpeeds,
      explorerRatings: explorerRatings ?? this.explorerRatings,
      multiPv: multiPv ?? this.multiPv,
    );
  }
}
