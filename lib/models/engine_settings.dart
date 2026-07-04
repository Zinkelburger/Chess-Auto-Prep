/// Engine settings model for configuring analysis parameters
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/engine_defaults.dart';
import '../utils/system_info.dart';
import 'settings_enums.dart';

class EngineSettings with ChangeNotifier {
  static const _prefix = 'engine_settings.';

  // ── Stockfish settings ────────────────────────────────────────────────

  /// Number of parallel Stockfish workers (each: 1 thread, 128 MB hash).
  /// Defaults to half the logical cores, minimum 1.
  int _workers = (getLogicalCores() ~/ 2).clamp(1, getLogicalCores());
  int get workers => _workers;
  set workers(int value) {
    final clamped = value.clamp(1, systemCores);
    if (clamped != _workers) {
      _workers = clamped;
      _persist();
      notifyListeners();
    }
  }

  int _depth = kDefaultDepth;
  int get depth => _depth;
  set depth(int value) {
    if (value != _depth && value >= kMinDepth && value <= kMaxDepth) {
      _depth = value;
      _persist();
      notifyListeners();
    }
  }

  int _multiPv = kDefaultMultiPv;
  int get multiPv => _multiPv;
  set multiPv(int value) {
    if (value != _multiPv && value >= kMinMultiPv && value <= kMaxMultiPv) {
      _multiPv = value;
      _persist();
      notifyListeners();
    }
  }

  /// Threads for the inline (PGN) engine worker.  Uses a single Stockfish
  /// process so more threads = faster search on one position.
  int _inlineThreads = kDefaultInlineThreads;
  int get inlineThreads => _inlineThreads;
  set inlineThreads(int value) {
    final clamped = value.clamp(1, systemCores);
    if (clamped != _inlineThreads) {
      _inlineThreads = clamped;
      _persist();
      notifyListeners();
    }
  }

  /// Maximum total moves to display in the analysis table.
  /// Stockfish MultiPV lines fill guaranteed slots; remaining slots are
  /// filled by the highest-probability Maia + DB candidates.
  int _maxAnalysisMoves = kDefaultMaxAnalysisMoves;
  int get maxAnalysisMoves => _maxAnalysisMoves;
  set maxAnalysisMoves(int value) {
    if (value != _maxAnalysisMoves &&
        value >= kMinMaxAnalysisMoves &&
        value <= kMaxMaxAnalysisMoves) {
      _maxAnalysisMoves = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Panel visibility toggles ──────────────────────────────────────────

  bool _showStockfish = kDefaultShowStockfish;
  bool get showStockfish => _showStockfish;
  set showStockfish(bool value) {
    if (value != _showStockfish) {
      _showStockfish = value;
      _persist();
      notifyListeners();
    }
  }

  bool _showMaia = kDefaultShowMaia;
  bool get showMaia => _showMaia;
  set showMaia(bool value) {
    if (value != _showMaia) {
      _showMaia = value;
      _persist();
      notifyListeners();
    }
  }

  bool _showProbability = kDefaultShowProbability;
  bool get showProbability => _showProbability;
  set showProbability(bool value) {
    if (value != _showProbability) {
      _showProbability = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Column focus (tap header in engine table to dim) ────────────────────

  static const colEval = 'eval';
  static const colLine = 'line';
  static const colDb = 'db';
  static const colMaia = 'maia';
  final Set<String> _mutedAnalysisColumns = {};
  Set<String> get mutedAnalysisColumns =>
      Set<String>.unmodifiable(_mutedAnalysisColumns);

  bool isAnalysisColumnMuted(String columnId) =>
      _mutedAnalysisColumns.contains(columnId);

  void toggleAnalysisColumnMuted(String columnId) {
    if (_mutedAnalysisColumns.contains(columnId)) {
      _mutedAnalysisColumns.remove(columnId);
    } else {
      _mutedAnalysisColumns.add(columnId);
    }
    _persist();
    notifyListeners();
  }

  void clearMutedAnalysisColumns() {
    if (_mutedAnalysisColumns.isEmpty) return;
    _mutedAnalysisColumns.clear();
    _persist();
    notifyListeners();
  }

  bool _showEngineDock = kDefaultShowEngineDock;
  bool get showEngineDock => _showEngineDock;
  set showEngineDock(bool value) {
    if (value != _showEngineDock) {
      _showEngineDock = value;
      _persist();
      notifyListeners();
    }
  }

  bool _showExpectimaxDock = kDefaultShowExpectimaxDock;
  bool get showExpectimaxDock => _showExpectimaxDock;
  set showExpectimaxDock(bool value) {
    if (value != _showExpectimaxDock) {
      _showExpectimaxDock = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Opponent probability source (engine table + line odds) ─────────────

  OpponentProbabilityMode _opponentProbabilityMode =
      OpponentProbabilityMode.maiaLichessFallback;
  OpponentProbabilityMode get opponentProbabilityMode =>
      _opponentProbabilityMode;
  set opponentProbabilityMode(OpponentProbabilityMode value) {
    if (value != _opponentProbabilityMode) {
      _opponentProbabilityMode = value;
      _persist();
      notifyListeners();
    }
  }

  bool get fetchMaiaForOpponent =>
      _opponentProbabilityMode == OpponentProbabilityMode.maia ||
      _opponentProbabilityMode == OpponentProbabilityMode.maiaLichessFallback;

  bool get fetchLichessForOpponent =>
      _opponentProbabilityMode == OpponentProbabilityMode.lichess ||
      _opponentProbabilityMode == OpponentProbabilityMode.maiaLichessFallback;

  /// `lichess` or `masters` (Lichess Explorer API).
  String _explorerDatabase = kDefaultExplorerDatabase;
  String get explorerDatabase => _explorerDatabase;
  set explorerDatabase(String value) {
    if (value != _explorerDatabase &&
        (value == 'lichess' || value == 'masters')) {
      _explorerDatabase = value;
      _persist();
      notifyListeners();
    }
  }

  bool get explorerUseMasters => _explorerDatabase == 'masters';

  String _explorerSpeeds = kDefaultExplorerSpeeds;
  String get explorerSpeeds => _explorerSpeeds;
  set explorerSpeeds(String value) {
    if (value != _explorerSpeeds && value.isNotEmpty) {
      _explorerSpeeds = value;
      _persist();
      notifyListeners();
    }
  }

  String _explorerRatings = kDefaultExplorerRatings;
  String get explorerRatings => _explorerRatings;
  set explorerRatings(String value) {
    if (value != _explorerRatings && value.isNotEmpty) {
      _explorerRatings = value;
      _persist();
      notifyListeners();
    }
  }

  Set<String> get explorerSpeedSet => _explorerSpeeds
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  Set<String> get explorerRatingSet => _explorerRatings
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  void setExplorerSpeedSet(Set<String> speeds) {
    if (speeds.isEmpty) return;
    explorerSpeeds = speeds.join(',');
  }

  void setExplorerRatingSet(Set<String> ratings) {
    if (ratings.isEmpty) return;
    explorerRatings = ratings.join(',');
  }

  // ── Probability settings ──────────────────────────────────────────────

  String _probabilityStartMoves = '';
  String get probabilityStartMoves => _probabilityStartMoves;
  set probabilityStartMoves(String value) {
    if (value != _probabilityStartMoves) {
      _probabilityStartMoves = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Maia ELO setting ──────────────────────────────────────────────────

  int _maiaElo = kDefaultMaiaElo;
  int get maiaElo => _maiaElo;
  set maiaElo(int value) {
    if (value != _maiaElo && value >= kMinMaiaElo && value <= kMaxMaiaElo) {
      _maiaElo = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Candidate source settings ──────────────────────────────────────────

  CandidateSource _candidateSourceOur = CandidateSource.maia;
  CandidateSource get candidateSourceOur => _candidateSourceOur;
  set candidateSourceOur(CandidateSource value) {
    if (value != _candidateSourceOur) {
      _candidateSourceOur = value;
      _persist();
      notifyListeners();
    }
  }

  CandidateSource _candidateSourceOpp = CandidateSource.maia;
  CandidateSource get candidateSourceOpp => _candidateSourceOpp;
  set candidateSourceOpp(CandidateSource value) {
    if (value != _candidateSourceOpp) {
      _candidateSourceOpp = value;
      _persist();
      notifyListeners();
    }
  }

  /// When using Stockfish for candidate generation, how many top moves.
  int _stockfishTopN = kDefaultStockfishTopN;
  int get stockfishTopN => _stockfishTopN;
  set stockfishTopN(int value) {
    if (value != _stockfishTopN &&
        value >= kMinStockfishTopN &&
        value <= kMaxStockfishTopN) {
      _stockfishTopN = value;
      _persist();
      notifyListeners();
    }
  }

  /// Max BFS depth for on-the-fly expectimax (plies from current position).
  int _onTheFlyMaxDepth = kDefaultOnTheFlyMaxDepth;
  int get onTheFlyMaxDepth => _onTheFlyMaxDepth;
  set onTheFlyMaxDepth(int value) {
    if (value != _onTheFlyMaxDepth &&
        value >= kMinOnTheFlyMaxDepth &&
        value <= kMaxOnTheFlyMaxDepth) {
      _onTheFlyMaxDepth = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Expectimax tree build settings ────────────────────────────────────

  int _expectimaxOurMultipv = kDefaultExpOurMultipv;
  int get expectimaxOurMultipv => _expectimaxOurMultipv;
  set expectimaxOurMultipv(int v) {
    if (v != _expectimaxOurMultipv &&
        v >= kMinExpOurMultipv &&
        v <= kMaxExpOurMultipv) {
      _expectimaxOurMultipv = v;
      _persist();
      notifyListeners();
    }
  }

  int _expectimaxOppMaxChildren = kDefaultExpOppMaxChildren;
  int get expectimaxOppMaxChildren => _expectimaxOppMaxChildren;
  set expectimaxOppMaxChildren(int v) {
    if (v != _expectimaxOppMaxChildren &&
        v >= kMinExpOppMaxChildren &&
        v <= kMaxExpOppMaxChildren) {
      _expectimaxOppMaxChildren = v;
      _persist();
      notifyListeners();
    }
  }

  double _expectimaxOppMassTarget = kDefaultExpOppMassTarget;
  double get expectimaxOppMassTarget => _expectimaxOppMassTarget;
  set expectimaxOppMassTarget(double v) {
    if (v != _expectimaxOppMassTarget &&
        v >= kMinExpOppMassTarget &&
        v <= kMaxExpOppMassTarget) {
      _expectimaxOppMassTarget = v;
      _persist();
      notifyListeners();
    }
  }

  double _expectimaxMinProb = kDefaultExpMinProb;
  double get expectimaxMinProb => _expectimaxMinProb;
  set expectimaxMinProb(double v) {
    if (v != _expectimaxMinProb && v >= kMinExpMinProb && v <= kMaxExpMinProb) {
      _expectimaxMinProb = v;
      _persist();
      notifyListeners();
    }
  }

  int _expectimaxMaxEvalLoss = kDefaultExpMaxEvalLoss;
  int get expectimaxMaxEvalLoss => _expectimaxMaxEvalLoss;
  set expectimaxMaxEvalLoss(int v) {
    if (v != _expectimaxMaxEvalLoss &&
        v >= kMinExpMaxEvalLoss &&
        v <= kMaxExpMaxEvalLoss) {
      _expectimaxMaxEvalLoss = v;
      _persist();
      notifyListeners();
    }
  }

  int _expectimaxEvalDepth = kDefaultExpEvalDepth;
  int get expectimaxEvalDepth => _expectimaxEvalDepth;
  set expectimaxEvalDepth(int v) {
    if (v != _expectimaxEvalDepth &&
        v >= kMinExpEvalDepth &&
        v <= kMaxExpEvalDepth) {
      _expectimaxEvalDepth = v;
      _persist();
      notifyListeners();
    }
  }

  // ── Singleton + system detection ─────────────────────────────────────

  /// Changes when analysis inputs change (not column dim state).
  int get analysisConfigRevision => Object.hash(
        depth,
        multiPv,
        maxAnalysisMoves,
        showStockfish,
        showMaia,
        showProbability,
        _opponentProbabilityMode,
        _explorerDatabase,
        _explorerSpeeds,
        _explorerRatings,
        _maiaElo,
        _candidateSourceOur,
        _candidateSourceOpp,
        _stockfishTopN,
      );

  /// Detected logical CPU cores.
  static final int systemCores = getLogicalCores();

  /// Application-wide shared instance.
  static final EngineSettings instance = EngineSettings._internal();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  EngineSettings.fresh() : this._internal();

  EngineSettings._internal();

  /// Load saved settings from SharedPreferences.
  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _workers = prefs.getInt('${_prefix}workers') ??
          (systemCores ~/ 2).clamp(1, systemCores);
      _depth = prefs.getInt('${_prefix}depth') ?? kDefaultDepth;
      _multiPv = prefs.getInt('${_prefix}multi_pv') ?? kDefaultMultiPv;
      _inlineThreads =
          prefs.getInt('${_prefix}inline_threads') ?? kDefaultInlineThreads;
      _maxAnalysisMoves = prefs.getInt('${_prefix}max_analysis_moves') ??
          kDefaultMaxAnalysisMoves;
      _showStockfish =
          prefs.getBool('${_prefix}show_stockfish') ?? kDefaultShowStockfish;
      _showMaia = prefs.getBool('${_prefix}show_maia') ?? kDefaultShowMaia;
      _showProbability = prefs.getBool('${_prefix}show_probability') ??
          kDefaultShowProbability;
      _showEngineDock =
          prefs.getBool('${_prefix}show_engine_dock') ?? kDefaultShowEngineDock;
      _showExpectimaxDock = prefs.getBool('${_prefix}show_expectimax_dock') ??
          kDefaultShowExpectimaxDock;
      _opponentProbabilityMode = OpponentProbabilityMode.fromStorageKey(
          prefs.getString('${_prefix}opponent_prob_mode') ??
              'maia_lichess_fallback');
      _explorerDatabase = prefs.getString('${_prefix}explorer_database') ??
          kDefaultExplorerDatabase;
      _explorerSpeeds = prefs.getString('${_prefix}explorer_speeds') ??
          kDefaultExplorerSpeeds;
      _explorerRatings = prefs.getString('${_prefix}explorer_ratings') ??
          kDefaultExplorerRatings;
      _maiaElo = prefs.getInt('${_prefix}maia_elo') ?? kDefaultMaiaElo;
      _candidateSourceOur = CandidateSource.fromStorageKey(
          prefs.getString('${_prefix}candidate_source_our') ?? 'maia');
      _candidateSourceOpp = CandidateSource.fromStorageKey(
          prefs.getString('${_prefix}candidate_source_opp') ?? 'maia');
      _stockfishTopN =
          prefs.getInt('${_prefix}stockfish_top_n') ?? kDefaultStockfishTopN;
      _onTheFlyMaxDepth = prefs.getInt('${_prefix}on_the_fly_max_depth') ??
          kDefaultOnTheFlyMaxDepth;
      _expectimaxOurMultipv =
          prefs.getInt('${_prefix}exp_our_multipv') ?? kDefaultExpOurMultipv;
      _expectimaxOppMaxChildren =
          prefs.getInt('${_prefix}exp_opp_max_children') ??
              kDefaultExpOppMaxChildren;
      _expectimaxOppMassTarget =
          prefs.getDouble('${_prefix}exp_opp_mass') ?? kDefaultExpOppMassTarget;
      _expectimaxMinProb =
          prefs.getDouble('${_prefix}exp_min_prob') ?? kDefaultExpMinProb;
      _expectimaxMaxEvalLoss =
          prefs.getInt('${_prefix}exp_max_eval_loss') ?? kDefaultExpMaxEvalLoss;
      _expectimaxEvalDepth =
          prefs.getInt('${_prefix}exp_eval_depth') ?? kDefaultExpEvalDepth;
      _probabilityStartMoves =
          prefs.getString('${_prefix}probability_start_moves') ?? '';
      _mutedAnalysisColumns
        ..clear()
        ..addAll(
          (prefs.getString('${_prefix}muted_columns') ?? '')
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty),
        );
      notifyListeners();
    } catch (e) {
      debugPrint('[EngineSettings] Failed to load prefs: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('${_prefix}workers', _workers);
      await prefs.setInt('${_prefix}depth', _depth);
      await prefs.setInt('${_prefix}multi_pv', _multiPv);
      await prefs.setInt('${_prefix}inline_threads', _inlineThreads);
      await prefs.setInt('${_prefix}max_analysis_moves', _maxAnalysisMoves);
      await prefs.setBool('${_prefix}show_stockfish', _showStockfish);
      await prefs.setBool('${_prefix}show_maia', _showMaia);
      await prefs.setBool('${_prefix}show_probability', _showProbability);
      await prefs.setBool('${_prefix}show_engine_dock', _showEngineDock);
      await prefs.setBool(
          '${_prefix}show_expectimax_dock', _showExpectimaxDock);
      await prefs.setString(
          '${_prefix}opponent_prob_mode', _opponentProbabilityMode.storageKey);
      await prefs.setString('${_prefix}explorer_database', _explorerDatabase);
      await prefs.setString('${_prefix}explorer_speeds', _explorerSpeeds);
      await prefs.setString('${_prefix}explorer_ratings', _explorerRatings);
      await prefs.setInt('${_prefix}maia_elo', _maiaElo);
      await prefs.setString(
          '${_prefix}candidate_source_our', _candidateSourceOur.storageKey);
      await prefs.setString(
          '${_prefix}candidate_source_opp', _candidateSourceOpp.storageKey);
      await prefs.setInt('${_prefix}stockfish_top_n', _stockfishTopN);
      await prefs.setInt('${_prefix}on_the_fly_max_depth', _onTheFlyMaxDepth);
      await prefs.setInt('${_prefix}exp_our_multipv', _expectimaxOurMultipv);
      await prefs.setInt(
          '${_prefix}exp_opp_max_children', _expectimaxOppMaxChildren);
      await prefs.setDouble('${_prefix}exp_opp_mass', _expectimaxOppMassTarget);
      await prefs.setDouble('${_prefix}exp_min_prob', _expectimaxMinProb);
      await prefs.setInt('${_prefix}exp_max_eval_loss', _expectimaxMaxEvalLoss);
      await prefs.setInt('${_prefix}exp_eval_depth', _expectimaxEvalDepth);
      await prefs.setString(
          '${_prefix}probability_start_moves', _probabilityStartMoves);
      await prefs.setString(
        '${_prefix}muted_columns',
        _mutedAnalysisColumns.join(','),
      );
    } catch (e) {
      debugPrint('[EngineSettings] Failed to persist prefs: $e');
    }
  }

  /// Reset all settings to defaults
  void resetToDefaults() {
    _workers = (systemCores ~/ 2).clamp(1, systemCores);
    _depth = kDefaultDepth;
    _multiPv = kDefaultMultiPv;
    _inlineThreads = kDefaultInlineThreads;
    _maxAnalysisMoves = kDefaultMaxAnalysisMoves;
    _showStockfish = kDefaultShowStockfish;
    _showMaia = kDefaultShowMaia;
    _showProbability = kDefaultShowProbability;
    _showEngineDock = kDefaultShowEngineDock;
    _showExpectimaxDock = kDefaultShowExpectimaxDock;
    _opponentProbabilityMode = OpponentProbabilityMode.maiaLichessFallback;
    _explorerDatabase = kDefaultExplorerDatabase;
    _explorerSpeeds = kDefaultExplorerSpeeds;
    _explorerRatings = kDefaultExplorerRatings;
    _probabilityStartMoves = '';
    _maiaElo = kDefaultMaiaElo;
    _candidateSourceOur = CandidateSource.maia;
    _candidateSourceOpp = CandidateSource.maia;
    _stockfishTopN = kDefaultStockfishTopN;
    _onTheFlyMaxDepth = kDefaultOnTheFlyMaxDepth;
    _expectimaxOurMultipv = kDefaultExpOurMultipv;
    _expectimaxOppMaxChildren = kDefaultExpOppMaxChildren;
    _expectimaxOppMassTarget = kDefaultExpOppMassTarget;
    _expectimaxMinProb = kDefaultExpMinProb;
    _expectimaxMaxEvalLoss = kDefaultExpMaxEvalLoss;
    _expectimaxEvalDepth = kDefaultExpEvalDepth;
    _mutedAnalysisColumns.clear();
    _persist();
    notifyListeners();
  }
}
