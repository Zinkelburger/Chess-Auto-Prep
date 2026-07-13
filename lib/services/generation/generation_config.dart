/// Configuration and output types for repertoire generation.
library;

import '../../constants/engine_defaults.dart';
import '../../utils/system_info.dart';

// ── Selection mode ──────────────────────────────────────────────────────

enum SelectionMode {
  expectimax,
  engineOnly,
  dbWinRateOnly,
  playable,
  trappy,
}

// ── Tree build algorithm mode ───────────────────────────────────────────

/// Fundamentally different tree-building algorithms (not parameter presets).
enum BuildMode {
  /// Stockfish MultiPV + Maia/Lichess opponent moves + expectimax (default).
  stockfishExpectimax,

  /// Top-N Maia moves for our side, DB evals only, stop on DB miss.
  maiaDbExplore,

  /// PGN database-seeded tree: parse game files, build frequency map,
  /// then BFS with eval enrichment — matches C `--build-mode db-explorer`.
  dbExplorer,

  /// Maia × eval surprise highlights — not yet implemented in Flutter.
  trapFinder,
}

// ── Search algorithm (frontier discipline + pruning preset) ─────────────

/// How the Phase 1 frontier is ordered and how aggressively rare lines are
/// pruned.  Expectimax valuation (Phase 2) is identical in both — the
/// algorithm only shapes which nodes exist in the tree.
enum SearchAlgorithm {
  /// Exhaustive level-order BFS: every candidate above the probability
  /// floor is explored at full MultiPV / full eval window.  Slowest but
  /// leaves nothing on the table.
  pure,

  /// Best-first (highest reach-priority node expands next) plus pruning
  /// that spends less effort on rarely-reached positions: our-move
  /// alternatives below the priority floor are skipped, MultiPV and the
  /// eval-loss window shrink in cold subtrees, and opponent fan-out is
  /// capped harder.  The coverage floor ([TreeBuildConfig.coverMinProb])
  /// is always honored, so Fast never creates silent holes.
  fast,
}

/// Default engine thread count: half of logical cores, minimum 1.
int defaultEngineThreads() {
  final cores = getLogicalCores();
  return (cores ~/ 2).clamp(1, cores);
}

/// Clamp [threads] to [1, logical core count].
int clampEngineThreads(int threads) {
  final cores = getLogicalCores();
  return threads.clamp(1, cores);
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

  // ── Frontier discipline + pruning preset ──
  /// Pure = exhaustive FIFO BFS; Fast = best-first expansion with
  /// priority-scaled pruning.  See [SearchAlgorithm].
  final SearchAlgorithm searchAlgorithm;

  /// Best-first frontier ordering (pop the highest search priority — reach
  /// probability × our-alternative discount — instead of FIFO level order).
  /// Makes the build an anytime algorithm: at any node budget the tree is
  /// concentrated on the likeliest opponent lines.
  bool get bestFirst => searchAlgorithm == SearchAlgorithm.fast;

  /// Priority multiplier applied to non-incumbent our-move candidates
  /// (the incumbent — best eval at expansion time — inherits the parent's
  /// priority unchanged).  Lower = spend less of the budget verifying
  /// alternatives, more on deepening the current repertoire spine.
  /// Only affects expansion order/depth, never expectimax or selection.
  final double ourAltDiscount;

  /// Fast only: our-move alternatives more than this many centipawns behind
  /// the incumbent stay as evaluated leaves — no subtree.  Selection still
  /// sees them (leaf value from the static eval) and the verification pass
  /// deep-checks whatever gets picked, so the insurance subtrees are only
  /// grown for alternatives close enough to plausibly win the argmax.
  /// 0 disables the gate.  Ignored under trappy selection, where
  /// worse-eval moves are the point and need their subtrees searched.
  final int fastAltGapCp;

  /// Dirichlet prior weight (λ, in virtual games) for smoothing DB opponent
  /// move frequencies with Maia's policy:
  ///   p = (count + λ·maiaP) / (N + λ)
  /// Replaces the hard DB→Maia fallback cliff at sparsely covered positions.
  /// 0 disables smoothing (raw frequencies + hard fallback).
  final double maiaPriorGames;

  // ── Coverage guarantee ──
  /// No-silent-holes floor: any opponent reply whose LOCAL (per-position)
  /// smoothed probability is at or above this value must have a repertoire
  /// answer, even when its reach probability falls below [minProbability] or
  /// the mass/children budgets are exhausted.  Such nodes get a coverage-only
  /// expansion (one evaluated answer, no subtree).  At the end of the build,
  /// any our-turn leaf still lacking an answer is either coverage-expanded
  /// (local prob ≥ floor) or removed from the tree so uncovered mass is
  /// honestly returned to the expectimax tail term.  0 disables the floor
  /// (legacy behavior: rare replies silently dropped).
  final double coverMinProb;

  // ── Final verification pass ──
  /// Re-evaluate every selected repertoire move at [resolvedVerifyDepth]
  /// after selection.  Moves whose deep eval loses more than [maxEvalLossCp]
  /// against the best deep sibling are demoted and selection re-runs, so the
  /// exported repertoire carries a depth guarantee instead of trusting the
  /// shallower build-time evals.
  final bool verifyFinal;

  /// Stockfish depth for the verification pass. 0 = auto
  /// (max(evalDepth + 6, 20)).
  final int verifyDepth;

  // ── Preferred setup (consistency bias) ──
  /// Space/comma-separated SAN moves of a system to play whenever sound
  /// (e.g. "Be3 Qd2 f3 O-O-O h4 Nh3" for the 150 Attack).  Legal setup
  /// moves are injected as candidates at our-move nodes, and selection
  /// prefers a setup move within [setupToleranceCp] of the best child
  /// eval.  Expectimax values are untouched — the bias only constrains
  /// the argmax, so when the opponent makes consistency expensive the
  /// eval guard deviates automatically.  Empty disables.
  final String setupMoves;

  /// Max centipawns a setup move may lose vs the best child eval and
  /// still be preferred by selection.
  final int setupToleranceCp;

  // ── Build algorithm ──
  final BuildMode buildMode;

  // ── Engine ──
  final int evalDepth;

  /// UCI Threads per Stockfish worker during tree build (1 = single-threaded).
  /// Use [resolvedEngineThreads] for the clamped value.
  final int engineThreads;

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

  // ── PGN export ──
  /// Sort extracted lines by cumulative probability (most likely first).
  final bool rankLinesByImportance;

  /// Annotate opponent moves with move-likelihood comments in PGN.
  final bool annotateMoveProbabilities;

  /// When annotating: use Maia only. When false, prefer Lichess human
  /// frequencies from the build and fall back to Maia.
  final bool annotateMaiaOnly;

  // ── Expectimax / repertoire selection ──
  final SelectionMode selectionMode;
  final double leafConfidence;
  final int noveltyWeight;

  // ── DB Explorer (PGN frequency seeding) ──
  final List<String> pgnFilePaths;
  final int dbMinGames;
  final double dbMinProb;
  final int minElo;

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
    this.maxPly = 20,
    this.maxNodes = 0,
    this.searchAlgorithm = SearchAlgorithm.fast,
    this.ourAltDiscount = 0.25,
    this.fastAltGapCp = 30,
    this.maiaPriorGames = 30.0,
    this.coverMinProb = 0.05,
    this.verifyFinal = true,
    this.verifyDepth = 0,
    this.setupMoves = '',
    this.setupToleranceCp = 30,
    this.buildMode = BuildMode.stockfishExpectimax,
    this.evalDepth = kDefaultGenerationEvalDepth,
    this.engineThreads = 0,
    this.ourMultipv = 4,
    this.maxEvalLossCp = 50,
    this.oppMaxChildren = 4,
    this.oppMassTarget = 0.80,
    this.minEvalCp = 0,
    this.maxEvalCp = 200,
    this.relativeEval = true,
    this.useLichessDb = false,
    this.useMasters = false,
    this.ratingRange = '2000,2200,2500',
    this.speeds = 'blitz,rapid,classical',
    this.minGames = 10,
    this.maiaElo = 2200,
    this.maiaMinProb = 0.05,
    this.maiaOnly = true,
    this.rankLinesByImportance = true,
    this.annotateMoveProbabilities = true,
    this.annotateMaiaOnly = true,
    this.selectionMode = SelectionMode.expectimax,
    this.leafConfidence = 1.0,
    this.noveltyWeight = 0,
    this.pgnFilePaths = const [],
    this.dbMinGames = 5,
    this.dbMinProb = 0.05,
    this.minElo = 0,
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
      maxPly: (json['max_depth'] as num?)?.toInt() ?? 20,
      maxNodes: (json['max_nodes'] as num?)?.toInt() ?? 0,
      searchAlgorithm: _parseSearchAlgorithm(
        json['search_algorithm'] as String?,
        legacyBestFirst: json['best_first'] as bool?,
      ),
      ourAltDiscount: (json['our_alt_discount'] as num?)?.toDouble() ?? 0.25,
      fastAltGapCp: (json['fast_alt_gap_cp'] as num?)?.toInt() ?? 30,
      maiaPriorGames: (json['maia_prior_games'] as num?)?.toDouble() ?? 30.0,
      coverMinProb: (json['cover_min_prob'] as num?)?.toDouble() ?? 0.05,
      verifyFinal: json['verify_final'] as bool? ?? true,
      verifyDepth: (json['verify_depth'] as num?)?.toInt() ?? 0,
      setupMoves: json['setup_moves'] as String? ?? '',
      setupToleranceCp: (json['setup_tolerance_cp'] as num?)?.toInt() ?? 30,
      buildMode: _parseBuildMode(json['build_mode'] as String?),
      evalDepth:
          (json['eval_depth'] as num?)?.toInt() ?? kDefaultGenerationEvalDepth,
      engineThreads: (json['engine_threads'] as num?)?.toInt() ?? 0,
      ourMultipv: (json['our_multipv'] as num?)?.toInt() ?? 4,
      maxEvalLossCp: (json['max_eval_loss_cp'] as num?)?.toInt() ?? 50,
      oppMaxChildren: (json['opp_max_children'] as num?)?.toInt() ?? 4,
      oppMassTarget: (json['opp_mass_target'] as num?)?.toDouble() ?? 0.80,
      minEvalCp: (json['min_eval_cp'] as num?)?.toInt() ?? 0,
      maxEvalCp: (json['max_eval_cp'] as num?)?.toInt() ?? 200,
      relativeEval: json['relative_eval'] as bool? ?? true,
      useLichessDb: json['use_lichess_db'] as bool? ?? false,
      useMasters: json['use_masters'] as bool? ?? false,
      ratingRange: json['rating_range'] as String? ?? '2000,2200,2500',
      speeds: json['speeds'] as String? ?? 'blitz,rapid,classical',
      minGames: (json['min_games'] as num?)?.toInt() ?? 10,
      maiaElo: (json['maia_elo'] as num?)?.toInt() ?? 2200,
      maiaMinProb: (json['maia_min_prob'] as num?)?.toDouble() ?? 0.05,
      maiaOnly: json['maia_only'] as bool? ?? true,
      rankLinesByImportance: json['rank_lines_by_importance'] as bool? ?? true,
      annotateMoveProbabilities:
          json['annotate_move_probabilities'] as bool? ?? true,
      annotateMaiaOnly: json['annotate_maia_only'] as bool? ?? true,
      selectionMode: _parseSelectionMode(json['selection_mode'] as String?),
      leafConfidence: (json['leaf_confidence'] as num?)?.toDouble() ?? 1.0,
      noveltyWeight: (json['novelty_weight'] as num?)?.toInt() ?? 0,
      pgnFilePaths:
          (json['pgn_file_paths'] as List<dynamic>?)?.cast<String>() ??
              const [],
      dbMinGames: (json['db_min_games'] as num?)?.toInt() ?? 5,
      dbMinProb: (json['db_min_prob'] as num?)?.toDouble() ?? 0.05,
      minElo: (json['min_elo'] as num?)?.toInt() ?? 0,
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

  /// Whether this build uses Stockfish during BFS tree construction.
  /// DB Explorer defers engine startup to the eval enrichment phase.
  bool get usesStockfish => buildMode == BuildMode.stockfishExpectimax;

  /// Whether the build needs Stockfish at any phase (build or enrichment).
  bool get needsStockfish =>
      buildMode == BuildMode.stockfishExpectimax ||
      buildMode == BuildMode.dbExplorer;

  /// Clamped engine thread count (defaults to half of logical cores).
  int get resolvedEngineThreads => engineThreads > 0
      ? clampEngineThreads(engineThreads)
      : defaultEngineThreads();

  /// Short label for the active build algorithm.
  String get buildModeLabel => switch (buildMode) {
        BuildMode.stockfishExpectimax => 'Stockfish + expectimax',
        BuildMode.maiaDbExplore => 'Maia DB explore',
        BuildMode.dbExplorer => 'DB Explorer',
        BuildMode.trapFinder => 'Trap finder',
      };

  /// Compact one-line summary for Jobs panel and status displays.
  String get summaryLabel {
    final parts = <String>[
      buildModeLabel,
      searchAlgorithm == SearchAlgorithm.pure ? 'Pure' : 'Fast',
      '${maxPly}ply',
    ];
    if (usesStockfish) {
      parts.add('SF d$evalDepth');
    }
    if (buildMode == BuildMode.dbExplorer && pgnFilePaths.isNotEmpty) {
      parts.add('${pgnFilePaths.length} PGN');
    }
    if (maiaOnly || buildMode == BuildMode.maiaDbExplore) {
      parts.add('Maia $maiaElo');
    } else if (useLichessDb) {
      parts.add(useMasters ? 'Masters' : 'Lichess');
    }
    return parts.join(' · ');
  }

  /// Engine resource summary when Stockfish is used.
  String get engineResourceLabel =>
      '$resolvedEngineThreads thread${resolvedEngineThreads == 1 ? '' : 's'}';

  /// Verification depth with the 0 = auto rule applied.
  int get resolvedVerifyDepth =>
      verifyDepth > 0 ? verifyDepth : (evalDepth + 6 < 20 ? 20 : evalDepth + 6);

  /// Minimum depth required from external eval sources.
  int get effectiveMinEvalDepth =>
      minAcceptableEvalDepth > 0 ? minAcceptableEvalDepth : evalDepth;

  // ── Fast Expectimax priority-scaled pruning ──
  //
  // Fast splits the tree into hot / warm / cold zones by reach priority.
  // Hot nodes (opponent reaches them often) get the full configured search;
  // warm ones lose one MultiPV line; cold ones (rarely reached — expectimax
  // weighs them by reach probability, so eval noise there barely moves the
  // root value) get minimum MultiPV, a halved eval-loss window, and halved
  // opponent fan-out.  Pure ignores the zones entirely.

  /// Reach-priority floor of the hot zone (full configured search).
  static const double fastWarmPriority = 0.02;

  /// Reach-priority floor of the warm zone; below this is cold.
  static const double fastColdPriority = 0.002;

  /// Fast only: cap on how many gap-qualifying our-move alternatives get a
  /// subtree per node (the incumbent always does).  One strong alternative
  /// is the insurance against a wrong incumbent judgment; a second covers
  /// near-ties.  Beyond that, alternatives stay evaluated leaves.
  static const int fastMaxExpandedAlts = 2;

  /// Root nodes always get at least this wide a MultiPV sweep regardless of
  /// the configured [ourMultipv] — every line in the repertoire descends
  /// from the root, so a narrow first fan-out can never be recovered later.
  static const int rootMultipvFloor = 10;

  /// Hard cap on candidate our-moves considered at a single node, whatever
  /// the source (MultiPV lines, Maia policy entries).  Bounds engine work
  /// and keeps pathological policy outputs from exploding the tree.
  static const int maxOurCandidates = 16;

  /// Our-move MultiPV at a node with reach priority [priority].
  int effectiveMultipv(double priority) {
    if (searchAlgorithm == SearchAlgorithm.pure) return ourMultipv;
    if (priority >= fastWarmPriority) return ourMultipv;
    final reduced = priority >= fastColdPriority ? ourMultipv - 1 : 2;
    return reduced.clamp(2, ourMultipv < 2 ? 2 : ourMultipv);
  }

  /// Our-move MultiPV at the root: the configured width, floored at
  /// [rootMultipvFloor].
  int get rootMultipv =>
      ourMultipv >= rootMultipvFloor ? ourMultipv : rootMultipvFloor;

  /// Max centipawns an our-move candidate may lose vs the best sibling and
  /// still enter the tree, at reach priority [priority].
  int effectiveMaxEvalLossCp(double priority) {
    if (searchAlgorithm == SearchAlgorithm.pure) return maxEvalLossCp;
    if (priority >= fastColdPriority) return maxEvalLossCp;
    return (maxEvalLossCp / 2).round();
  }

  /// Opponent fan-out cap at reach priority [priority] (0 = unlimited).
  /// Coverage-floor replies bypass this cap at the call sites, so the
  /// no-silent-holes guarantee survives Fast pruning.
  int effectiveOppMaxChildren(double priority) {
    if (searchAlgorithm == SearchAlgorithm.pure) return oppMaxChildren;
    if (priority >= fastColdPriority) return oppMaxChildren;
    if (oppMaxChildren <= 0) return 3;
    return oppMaxChildren <= 4 ? 2 : oppMaxChildren ~/ 2;
  }

  /// Whether an our-move alternative sitting [gapCp] behind the incumbent
  /// gets a subtree, given [altsAlreadyExpanded] siblings already granted
  /// one.  See [fastAltGapCp]; the incumbent itself never passes through
  /// this gate.
  bool expandAlternative({
    required int gapCp,
    required int altsAlreadyExpanded,
  }) {
    if (searchAlgorithm == SearchAlgorithm.pure) return true;
    if (selectionMode == SelectionMode.trappy) return true;
    if (fastAltGapCp <= 0) return true;
    if (gapCp > fastAltGapCp) return false;
    return altsAlreadyExpanded < fastMaxExpandedAlts;
  }

  /// Short label for the frontier/pruning algorithm.
  String get searchAlgorithmLabel => switch (searchAlgorithm) {
        SearchAlgorithm.pure => 'Pure Expectimax',
        SearchAlgorithm.fast => 'Fast Expectimax',
      };

  /// Convert a white-perspective centipawn score to "our" perspective.
  int toOurPerspective(int whiteCp) => playAsWhite ? whiteCp : -whiteCp;

  /// Serialise to a JSON-compatible map for tree file metadata.
  Map<String, dynamic> toJson() => {
        'play_as_white': playAsWhite,
        'min_probability': minProbability,
        'max_depth': maxPly,
        'max_nodes': maxNodes,
        'search_algorithm': searchAlgorithm.name,
        // Legacy key so older builds of the app can still read tree metadata.
        'best_first': bestFirst,
        'our_alt_discount': ourAltDiscount,
        'fast_alt_gap_cp': fastAltGapCp,
        'maia_prior_games': maiaPriorGames,
        'cover_min_prob': coverMinProb,
        'verify_final': verifyFinal,
        'verify_depth': verifyDepth,
        'setup_moves': setupMoves,
        'setup_tolerance_cp': setupToleranceCp,
        'build_mode': buildMode.name,
        'eval_depth': evalDepth,
        'engine_threads': resolvedEngineThreads,
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
        'rank_lines_by_importance': rankLinesByImportance,
        'annotate_move_probabilities': annotateMoveProbabilities,
        'annotate_maia_only': annotateMaiaOnly,
        'selection_mode': selectionMode.name,
        'leaf_confidence': leafConfidence,
        'novelty_weight': noveltyWeight,
        'pgn_file_paths': pgnFilePaths,
        'db_min_games': dbMinGames,
        'db_min_prob': dbMinProb,
        'min_elo': minElo,
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
    SearchAlgorithm? searchAlgorithm,
    double? ourAltDiscount,
    int? fastAltGapCp,
    double? maiaPriorGames,
    double? coverMinProb,
    bool? verifyFinal,
    int? verifyDepth,
    String? setupMoves,
    int? setupToleranceCp,
    BuildMode? buildMode,
    int? evalDepth,
    int? engineThreads,
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
    bool? rankLinesByImportance,
    bool? annotateMoveProbabilities,
    bool? annotateMaiaOnly,
    SelectionMode? selectionMode,
    double? leafConfidence,
    int? noveltyWeight,
    List<String>? pgnFilePaths,
    int? dbMinGames,
    double? dbMinProb,
    int? minElo,
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
      searchAlgorithm: searchAlgorithm ?? this.searchAlgorithm,
      ourAltDiscount: ourAltDiscount ?? this.ourAltDiscount,
      fastAltGapCp: fastAltGapCp ?? this.fastAltGapCp,
      maiaPriorGames: maiaPriorGames ?? this.maiaPriorGames,
      coverMinProb: coverMinProb ?? this.coverMinProb,
      verifyFinal: verifyFinal ?? this.verifyFinal,
      verifyDepth: verifyDepth ?? this.verifyDepth,
      setupMoves: setupMoves ?? this.setupMoves,
      setupToleranceCp: setupToleranceCp ?? this.setupToleranceCp,
      buildMode: buildMode ?? this.buildMode,
      evalDepth: evalDepth ?? this.evalDepth,
      engineThreads: engineThreads ?? this.engineThreads,
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
      rankLinesByImportance:
          rankLinesByImportance ?? this.rankLinesByImportance,
      annotateMoveProbabilities:
          annotateMoveProbabilities ?? this.annotateMoveProbabilities,
      annotateMaiaOnly: annotateMaiaOnly ?? this.annotateMaiaOnly,
      selectionMode: selectionMode ?? this.selectionMode,
      leafConfidence: leafConfidence ?? this.leafConfidence,
      noveltyWeight: noveltyWeight ?? this.noveltyWeight,
      pgnFilePaths: pgnFilePaths ?? this.pgnFilePaths,
      dbMinGames: dbMinGames ?? this.dbMinGames,
      dbMinProb: dbMinProb ?? this.dbMinProb,
      minElo: minElo ?? this.minElo,
      enableCdbDirect: enableCdbDirect ?? this.enableCdbDirect,
      cdbDirectPath: cdbDirectPath ?? this.cdbDirectPath,
      cdbDirectReadAhead: cdbDirectReadAhead ?? this.cdbDirectReadAhead,
      batchEvalLookups: batchEvalLookups ?? this.batchEvalLookups,
      enableLocalChessDb: enableLocalChessDb ?? this.enableLocalChessDb,
      localChessDbPath: localChessDbPath ?? this.localChessDbPath,
      enableChessDbApi: enableChessDbApi ?? this.enableChessDbApi,
      chessDbApiDailyQuota: chessDbApiDailyQuota ?? this.chessDbApiDailyQuota,
      chessDbApiConcurrency:
          chessDbApiConcurrency ?? this.chessDbApiConcurrency,
      enableExtEvalSubtreeSkip:
          enableExtEvalSubtreeSkip ?? this.enableExtEvalSubtreeSkip,
      minAcceptableEvalDepth:
          minAcceptableEvalDepth ?? this.minAcceptableEvalDepth,
    );
  }
}

SearchAlgorithm _parseSearchAlgorithm(
  String? value, {
  bool? legacyBestFirst,
}) {
  switch (value) {
    case 'pure':
      return SearchAlgorithm.pure;
    case 'fast':
      return SearchAlgorithm.fast;
  }
  // Configs written before the algorithm enum carry only best_first.
  if (legacyBestFirst == false) return SearchAlgorithm.pure;
  return SearchAlgorithm.fast;
}

SelectionMode _parseSelectionMode(String? value) {
  switch (value) {
    case 'engineOnly':
      return SelectionMode.engineOnly;
    case 'dbWinRateOnly':
      return SelectionMode.dbWinRateOnly;
    case 'playable':
      return SelectionMode.playable;
    case 'trappy':
      return SelectionMode.trappy;
    default:
      return SelectionMode.expectimax;
  }
}

BuildMode _parseBuildMode(String? value) {
  switch (value) {
    case 'maiaDbExplore':
      return BuildMode.maiaDbExplore;
    case 'dbExplorer':
      return BuildMode.dbExplorer;
    case 'trapFinder':
      return BuildMode.trapFinder;
    default:
      return BuildMode.stockfishExpectimax;
  }
}
