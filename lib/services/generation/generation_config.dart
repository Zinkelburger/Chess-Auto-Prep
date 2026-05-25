/// Configuration and output types for repertoire generation.
library;

// ── Selection mode ──────────────────────────────────────────────────────

enum SelectionMode {
  expectimax,
  engineOnly,
  dbWinRateOnly,
}

// ── Two-phase tree build config (matches C tree_builder) ────────────────

/// Configuration for the two-phase tree build algorithm.
///
/// Phase 1 builds a persistent tree with all evals.  Phase 2 computes
/// ease/expectimax and selects repertoire moves.
class TreeBuildConfig {
  final String startFen;
  final bool playAsWhite;

  // ── Traversal limits ──
  final double minProbability;
  final int maxPly;
  final int maxNodes;

  // ── Engine ──
  final int evalDepth;

  // ── Our-move MultiPV (constant at every depth, matches C invariant) ──
  final int ourMultipv;
  final int maxEvalLossCp;

  // ── Opponent-move selection (constant at every depth) ──
  final int oppMaxChildren;
  final double oppMassTarget;

  // ── Eval window pruning ──
  final int minEvalCp;
  final int maxEvalCp;
  final bool relativeEval;

  // ── Lichess API ──
  final bool useLichessDb;
  final bool useMasters;
  final String ratingRange;
  final String speeds;
  final int minGames;

  // ── Maia ──
  final int maiaElo;
  final double maiaMinProb;
  final bool maiaOnly;

  // ── Expectimax / repertoire selection ──
  final SelectionMode selectionMode;
  final double leafConfidence;
  final int noveltyWeight;

  // ── External eval sources (ChessDB local + API) ──
  final bool enableCdbDirect;
  final String cdbDirectPath;
  final bool cdbDirectReadAhead;
  final bool batchEvalLookups;
  final bool enableLocalChessDb;
  final String localChessDbPath;
  final bool enableChessDbApi;
  final int chessDbApiDailyQuota;
  final int chessDbApiConcurrency;
  final bool enableExtEvalSubtreeSkip;
  final int minAcceptableEvalDepth;

  const TreeBuildConfig({
    required this.startFen,
    required this.playAsWhite,
    this.minProbability = 0.0001,
    this.maxPly = 10,
    this.maxNodes = 0,
    this.evalDepth = 20,
    this.ourMultipv = 5,
    this.maxEvalLossCp = 50,
    this.oppMaxChildren = 6,
    this.oppMassTarget = 0.95,
    this.minEvalCp = 0,
    this.maxEvalCp = 200,
    this.relativeEval = false,
    this.useLichessDb = false,
    this.useMasters = false,
    this.ratingRange = '2000,2200,2500',
    this.speeds = 'blitz,rapid,classical',
    this.minGames = 10,
    this.maiaElo = 2200,
    this.maiaMinProb = 0.05,
    this.maiaOnly = true,
    this.selectionMode = SelectionMode.expectimax,
    this.leafConfidence = 1.0,
    this.noveltyWeight = 0,
    this.enableCdbDirect = false,
    this.cdbDirectPath = '',
    this.cdbDirectReadAhead = false,
    this.batchEvalLookups = false,
    this.enableLocalChessDb = false,
    this.localChessDbPath = '',
    this.enableChessDbApi = false,
    this.chessDbApiDailyQuota = 5000,
    this.chessDbApiConcurrency = 2,
    this.enableExtEvalSubtreeSkip = true,
    this.minAcceptableEvalDepth = 0,
  });

  factory TreeBuildConfig.fromJson(
    Map<String, dynamic> json, {
    required String startFen,
  }) {
    return TreeBuildConfig(
      startFen: startFen,
      playAsWhite: json['play_as_white'] as bool? ?? true,
      minProbability: (json['min_probability'] as num?)?.toDouble() ?? 0.0001,
      maxPly: (json['max_depth'] as num?)?.toInt() ?? 10,
      maxNodes: (json['max_nodes'] as num?)?.toInt() ?? 0,
      evalDepth: (json['eval_depth'] as num?)?.toInt() ?? 20,
      ourMultipv: (json['our_multipv'] as num?)?.toInt() ?? 5,
      maxEvalLossCp: (json['max_eval_loss_cp'] as num?)?.toInt() ?? 50,
      oppMaxChildren: (json['opp_max_children'] as num?)?.toInt() ?? 6,
      oppMassTarget: (json['opp_mass_target'] as num?)?.toDouble() ?? 0.95,
      minEvalCp: (json['min_eval_cp'] as num?)?.toInt() ?? 0,
      maxEvalCp: (json['max_eval_cp'] as num?)?.toInt() ?? 200,
      relativeEval: json['relative_eval'] as bool? ?? false,
      useLichessDb: json['use_lichess_db'] as bool? ?? false,
      useMasters: json['use_masters'] as bool? ?? false,
      ratingRange: json['rating_range'] as String? ?? '2000,2200,2500',
      speeds: json['speeds'] as String? ?? 'blitz,rapid,classical',
      minGames: (json['min_games'] as num?)?.toInt() ?? 10,
      maiaElo: (json['maia_elo'] as num?)?.toInt() ?? 2200,
      maiaMinProb: (json['maia_min_prob'] as num?)?.toDouble() ?? 0.05,
      maiaOnly: json['maia_only'] as bool? ?? true,
      selectionMode: _parseSelectionMode(json['selection_mode'] as String?),
      leafConfidence: (json['leaf_confidence'] as num?)?.toDouble() ?? 1.0,
      noveltyWeight: (json['novelty_weight'] as num?)?.toInt() ?? 0,
      enableCdbDirect: json['enable_cdbdirect'] as bool? ?? false,
      cdbDirectPath: json['cdbdirect_path'] as String? ?? '',
      cdbDirectReadAhead: json['cdbdirect_read_ahead'] as bool? ?? false,
      batchEvalLookups: json['batch_eval_lookups'] as bool? ?? false,
      enableLocalChessDb: json['enable_local_chessdb'] as bool? ?? false,
      localChessDbPath: json['local_chessdb_path'] as String? ?? '',
      enableChessDbApi: json['enable_chessdb_api'] as bool? ?? false,
      chessDbApiDailyQuota:
          (json['chessdb_api_daily_quota'] as num?)?.toInt() ?? 5000,
      chessDbApiConcurrency:
          (json['chessdb_api_concurrency'] as num?)?.toInt() ?? 2,
      enableExtEvalSubtreeSkip:
          json['enable_ext_eval_subtree_skip'] as bool? ?? true,
      minAcceptableEvalDepth:
          (json['min_acceptable_eval_depth'] as num?)?.toInt() ?? 0,
    );
  }

  /// Minimum depth required from external eval sources.
  int get effectiveMinEvalDepth =>
      minAcceptableEvalDepth > 0 ? minAcceptableEvalDepth : evalDepth;

  /// Quick eval depth for the repertoire selection phase.
  int get quickEvalDepth => evalDepth > 15 ? 15 : evalDepth;

  /// Convert a white-perspective centipawn score to "our" perspective.
  int toOurPerspective(int whiteCp) => playAsWhite ? whiteCp : -whiteCp;

  /// Serialise to a JSON-compatible map for tree file metadata.
  Map<String, dynamic> toJson() => {
        'play_as_white': playAsWhite,
        'min_probability': minProbability,
        'max_depth': maxPly,
        'max_nodes': maxNodes,
        'eval_depth': evalDepth,
        'our_multipv': ourMultipv,
        'max_eval_loss_cp': maxEvalLossCp,
        'opp_max_children': oppMaxChildren,
        'opp_mass_target': oppMassTarget,
        'min_eval_cp': minEvalCp,
        'max_eval_cp': maxEvalCp,
        'relative_eval': relativeEval,
        'use_lichess_db': useLichessDb,
        'use_masters': useMasters,
        'rating_range': ratingRange,
        'speeds': speeds,
        'min_games': minGames,
        'maia_elo': maiaElo,
        'maia_min_prob': maiaMinProb,
        'maia_only': maiaOnly,
        'selection_mode': selectionMode.name,
        'leaf_confidence': leafConfidence,
        'novelty_weight': noveltyWeight,
        'enable_cdbdirect': enableCdbDirect,
        'cdbdirect_path': cdbDirectPath,
        'cdbdirect_read_ahead': cdbDirectReadAhead,
        'batch_eval_lookups': batchEvalLookups,
        'enable_local_chessdb': enableLocalChessDb,
        'local_chessdb_path': localChessDbPath,
        'enable_chessdb_api': enableChessDbApi,
        'chessdb_api_daily_quota': chessDbApiDailyQuota,
        'chessdb_api_concurrency': chessDbApiConcurrency,
        'enable_ext_eval_subtree_skip': enableExtEvalSubtreeSkip,
        'min_acceptable_eval_depth': minAcceptableEvalDepth,
      };

  TreeBuildConfig copyWith({
    String? startFen,
    bool? playAsWhite,
    double? minProbability,
    int? maxPly,
    int? maxNodes,
    int? evalDepth,
    int? ourMultipv,
    int? maxEvalLossCp,
    int? oppMaxChildren,
    double? oppMassTarget,
    int? minEvalCp,
    int? maxEvalCp,
    bool? relativeEval,
    bool? useLichessDb,
    bool? useMasters,
    String? ratingRange,
    String? speeds,
    int? minGames,
    int? maiaElo,
    double? maiaMinProb,
    bool? maiaOnly,
    SelectionMode? selectionMode,
    double? leafConfidence,
    int? noveltyWeight,
    bool? enableCdbDirect,
    String? cdbDirectPath,
    bool? cdbDirectReadAhead,
    bool? batchEvalLookups,
    bool? enableLocalChessDb,
    String? localChessDbPath,
    bool? enableChessDbApi,
    int? chessDbApiDailyQuota,
    int? chessDbApiConcurrency,
    bool? enableExtEvalSubtreeSkip,
    int? minAcceptableEvalDepth,
  }) {
    return TreeBuildConfig(
      startFen: startFen ?? this.startFen,
      playAsWhite: playAsWhite ?? this.playAsWhite,
      minProbability: minProbability ?? this.minProbability,
      maxPly: maxPly ?? this.maxPly,
      maxNodes: maxNodes ?? this.maxNodes,
      evalDepth: evalDepth ?? this.evalDepth,
      ourMultipv: ourMultipv ?? this.ourMultipv,
      maxEvalLossCp: maxEvalLossCp ?? this.maxEvalLossCp,
      oppMaxChildren: oppMaxChildren ?? this.oppMaxChildren,
      oppMassTarget: oppMassTarget ?? this.oppMassTarget,
      minEvalCp: minEvalCp ?? this.minEvalCp,
      maxEvalCp: maxEvalCp ?? this.maxEvalCp,
      relativeEval: relativeEval ?? this.relativeEval,
      useLichessDb: useLichessDb ?? this.useLichessDb,
      useMasters: useMasters ?? this.useMasters,
      ratingRange: ratingRange ?? this.ratingRange,
      speeds: speeds ?? this.speeds,
      minGames: minGames ?? this.minGames,
      maiaElo: maiaElo ?? this.maiaElo,
      maiaMinProb: maiaMinProb ?? this.maiaMinProb,
      maiaOnly: maiaOnly ?? this.maiaOnly,
      selectionMode: selectionMode ?? this.selectionMode,
      leafConfidence: leafConfidence ?? this.leafConfidence,
      noveltyWeight: noveltyWeight ?? this.noveltyWeight,
      enableCdbDirect: enableCdbDirect ?? this.enableCdbDirect,
      cdbDirectPath: cdbDirectPath ?? this.cdbDirectPath,
      cdbDirectReadAhead: cdbDirectReadAhead ?? this.cdbDirectReadAhead,
      batchEvalLookups: batchEvalLookups ?? this.batchEvalLookups,
      enableLocalChessDb: enableLocalChessDb ?? this.enableLocalChessDb,
      localChessDbPath: localChessDbPath ?? this.localChessDbPath,
      enableChessDbApi: enableChessDbApi ?? this.enableChessDbApi,
      chessDbApiDailyQuota:
          chessDbApiDailyQuota ?? this.chessDbApiDailyQuota,
      chessDbApiConcurrency:
          chessDbApiConcurrency ?? this.chessDbApiConcurrency,
      enableExtEvalSubtreeSkip:
          enableExtEvalSubtreeSkip ?? this.enableExtEvalSubtreeSkip,
      minAcceptableEvalDepth:
          minAcceptableEvalDepth ?? this.minAcceptableEvalDepth,
    );
  }
}

SelectionMode _parseSelectionMode(String? value) {
  switch (value) {
    case 'engineOnly':
      return SelectionMode.engineOnly;
    case 'dbWinRateOnly':
      return SelectionMode.dbWinRateOnly;
    default:
      return SelectionMode.expectimax;
  }
}
