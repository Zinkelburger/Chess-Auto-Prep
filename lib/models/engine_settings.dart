/// Engine settings model for configuring analysis parameters
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/system_info.dart';

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

  int _depth = 15;
  int get depth => _depth;
  set depth(int value) {
    if (value != _depth && value >= 1 && value <= 99) {
      _depth = value;
      _persist();
      notifyListeners();
    }
  }


  int _multiPv = 3;
  int get multiPv => _multiPv;
  set multiPv(int value) {
    if (value != _multiPv && value >= 1 && value <= 10) {
      _multiPv = value;
      _persist();
      notifyListeners();
    }
  }

  /// Threads for the inline (PGN) engine worker.  Uses a single Stockfish
  /// process so more threads = faster search on one position.
  int _inlineThreads = 1;
  int get inlineThreads => _inlineThreads;
  set inlineThreads(int value) {
    final clamped = value.clamp(1, systemCores);
    if (clamped != _inlineThreads) {
      _inlineThreads = clamped;
      notifyListeners();
    }
  }

  /// Maximum total moves to display in the analysis table.
  /// Stockfish MultiPV lines fill guaranteed slots; remaining slots are
  /// filled by the highest-probability Maia + DB candidates.
  int _maxAnalysisMoves = 8;
  int get maxAnalysisMoves => _maxAnalysisMoves;
  set maxAnalysisMoves(int value) {
    if (value != _maxAnalysisMoves && value >= 3 && value <= 20) {
      _maxAnalysisMoves = value;
      notifyListeners();
    }
  }

  // ── Panel visibility toggles ──────────────────────────────────────────

  bool _showStockfish = true;
  bool get showStockfish => _showStockfish;
  set showStockfish(bool value) {
    if (value != _showStockfish) {
      _showStockfish = value;
      _persist();
      notifyListeners();
    }
  }

  bool _showMaia = true;
  bool get showMaia => _showMaia;
  set showMaia(bool value) {
    if (value != _showMaia) {
      _showMaia = value;
      _persist();
      notifyListeners();
    }
  }

  bool _showProbability = true;
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

  bool _showEngineDock = true;
  bool get showEngineDock => _showEngineDock;
  set showEngineDock(bool value) {
    if (value != _showEngineDock) {
      _showEngineDock = value;
      _persist();
      notifyListeners();
    }
  }

  bool _showExpectimaxDock = true;
  bool get showExpectimaxDock => _showExpectimaxDock;
  set showExpectimaxDock(bool value) {
    if (value != _showExpectimaxDock) {
      _showExpectimaxDock = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Opponent probability source (engine table + line odds) ─────────────

  /// `maia` | `lichess` | `maia_lichess_fallback`
  String _opponentProbabilityMode = 'maia_lichess_fallback';
  String get opponentProbabilityMode => _opponentProbabilityMode;
  set opponentProbabilityMode(String value) {
    if (value != _opponentProbabilityMode &&
        (value == 'maia' ||
            value == 'lichess' ||
            value == 'maia_lichess_fallback')) {
      _opponentProbabilityMode = value;
      _persist();
      notifyListeners();
    }
  }

  bool get fetchMaiaForOpponent =>
      opponentProbabilityMode == 'maia' ||
      opponentProbabilityMode == 'maia_lichess_fallback';

  bool get fetchLichessForOpponent =>
      opponentProbabilityMode == 'lichess' ||
      opponentProbabilityMode == 'maia_lichess_fallback';

  /// `lichess` or `masters` (Lichess Explorer API).
  String _explorerDatabase = 'lichess';
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

  String _explorerSpeeds = 'blitz,rapid,classical';
  String get explorerSpeeds => _explorerSpeeds;
  set explorerSpeeds(String value) {
    if (value != _explorerSpeeds && value.isNotEmpty) {
      _explorerSpeeds = value;
      _persist();
      notifyListeners();
    }
  }

  String _explorerRatings = '1800,2000,2200,2500';
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
      notifyListeners();
    }
  }

  // ── Maia ELO setting ──────────────────────────────────────────────────

  int _maiaElo = 2200;
  int get maiaElo => _maiaElo;
  set maiaElo(int value) {
    if (value != _maiaElo && value >= 600 && value <= 2400) {
      _maiaElo = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Candidate source settings ──────────────────────────────────────────

  /// Candidate source for our moves: 'maia' (default) or 'stockfish'.
  String _candidateSourceOur = 'maia';
  String get candidateSourceOur => _candidateSourceOur;
  set candidateSourceOur(String value) {
    if (value != _candidateSourceOur &&
        (value == 'maia' || value == 'stockfish')) {
      _candidateSourceOur = value;
      _persist();
      notifyListeners();
    }
  }

  /// Candidate source for opponent moves: 'maia' (default) or 'stockfish'.
  String _candidateSourceOpp = 'maia';
  String get candidateSourceOpp => _candidateSourceOpp;
  set candidateSourceOpp(String value) {
    if (value != _candidateSourceOpp &&
        (value == 'maia' || value == 'stockfish')) {
      _candidateSourceOpp = value;
      _persist();
      notifyListeners();
    }
  }

  /// When using Stockfish for candidate generation, how many top moves.
  int _stockfishTopN = 3;
  int get stockfishTopN => _stockfishTopN;
  set stockfishTopN(int value) {
    if (value != _stockfishTopN && value >= 1 && value <= 10) {
      _stockfishTopN = value;
      _persist();
      notifyListeners();
    }
  }

  /// Max BFS depth for on-the-fly expectimax (plies from current position).
  int _onTheFlyMaxDepth = 5;
  int get onTheFlyMaxDepth => _onTheFlyMaxDepth;
  set onTheFlyMaxDepth(int value) {
    if (value != _onTheFlyMaxDepth && value >= 1 && value <= 12) {
      _onTheFlyMaxDepth = value;
      _persist();
      notifyListeners();
    }
  }

  // ── Expectimax tree build settings ────────────────────────────────────

  int _expectimaxOurMultipv = 4;
  int get expectimaxOurMultipv => _expectimaxOurMultipv;
  set expectimaxOurMultipv(int v) {
    if (v != _expectimaxOurMultipv && v >= 1 && v <= 8) {
      _expectimaxOurMultipv = v; _persist(); notifyListeners();
    }
  }

  int _expectimaxOppMaxChildren = 4;
  int get expectimaxOppMaxChildren => _expectimaxOppMaxChildren;
  set expectimaxOppMaxChildren(int v) {
    if (v != _expectimaxOppMaxChildren && v >= 1 && v <= 12) {
      _expectimaxOppMaxChildren = v; _persist(); notifyListeners();
    }
  }

  double _expectimaxOppMassTarget = 0.80;
  double get expectimaxOppMassTarget => _expectimaxOppMassTarget;
  set expectimaxOppMassTarget(double v) {
    if (v != _expectimaxOppMassTarget && v >= 0.5 && v <= 1.0) {
      _expectimaxOppMassTarget = v; _persist(); notifyListeners();
    }
  }

  double _expectimaxMinProb = 0.02;
  double get expectimaxMinProb => _expectimaxMinProb;
  set expectimaxMinProb(double v) {
    if (v != _expectimaxMinProb && v >= 0.005 && v <= 0.2) {
      _expectimaxMinProb = v; _persist(); notifyListeners();
    }
  }

  int _expectimaxMaxEvalLoss = 80;
  int get expectimaxMaxEvalLoss => _expectimaxMaxEvalLoss;
  set expectimaxMaxEvalLoss(int v) {
    if (v != _expectimaxMaxEvalLoss && v >= 20 && v <= 300) {
      _expectimaxMaxEvalLoss = v; _persist(); notifyListeners();
    }
  }

  int _expectimaxEvalDepth = 12;
  int get expectimaxEvalDepth => _expectimaxEvalDepth;
  set expectimaxEvalDepth(int v) {
    if (v != _expectimaxEvalDepth && v >= 6 && v <= 20) {
      _expectimaxEvalDepth = v; _persist(); notifyListeners();
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
        opponentProbabilityMode,
        explorerDatabase,
        explorerSpeeds,
        explorerRatings,
        maiaElo,
        candidateSourceOur,
        candidateSourceOpp,
        stockfishTopN,
      );

  /// Detected logical CPU cores.
  static final int systemCores = getLogicalCores();

  static final EngineSettings _instance = EngineSettings._internal();
  factory EngineSettings() => _instance;
  EngineSettings._internal();

  /// Load saved settings from SharedPreferences.
  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _workers = prefs.getInt('${_prefix}workers') ??
          (systemCores ~/ 2).clamp(1, systemCores);
      _depth = prefs.getInt('${_prefix}depth') ?? 15;
      _multiPv = prefs.getInt('${_prefix}multi_pv') ?? 3;
      _inlineThreads = prefs.getInt('${_prefix}inline_threads') ?? 1;
      _maxAnalysisMoves = prefs.getInt('${_prefix}max_analysis_moves') ?? 8;
      _showStockfish = prefs.getBool('${_prefix}show_stockfish') ?? true;
      _showMaia = prefs.getBool('${_prefix}show_maia') ?? true;
      _showProbability = prefs.getBool('${_prefix}show_probability') ?? true;
      _showEngineDock = prefs.getBool('${_prefix}show_engine_dock') ?? true;
      _showExpectimaxDock =
          prefs.getBool('${_prefix}show_expectimax_dock') ?? true;
      _opponentProbabilityMode =
          prefs.getString('${_prefix}opponent_prob_mode') ??
              'maia_lichess_fallback';
      _explorerDatabase =
          prefs.getString('${_prefix}explorer_database') ?? 'lichess';
      _explorerSpeeds =
          prefs.getString('${_prefix}explorer_speeds') ?? 'blitz,rapid,classical';
      _explorerRatings = prefs.getString('${_prefix}explorer_ratings') ??
          '1800,2000,2200,2500';
      _maiaElo = prefs.getInt('${_prefix}maia_elo') ?? 2200;
      _candidateSourceOur =
          prefs.getString('${_prefix}candidate_source_our') ?? 'maia';
      _candidateSourceOpp =
          prefs.getString('${_prefix}candidate_source_opp') ?? 'maia';
      _stockfishTopN = prefs.getInt('${_prefix}stockfish_top_n') ?? 3;
      _onTheFlyMaxDepth = prefs.getInt('${_prefix}on_the_fly_max_depth') ?? 5;
      _expectimaxOurMultipv = prefs.getInt('${_prefix}exp_our_multipv') ?? 4;
      _expectimaxOppMaxChildren =
          prefs.getInt('${_prefix}exp_opp_max_children') ?? 4;
      _expectimaxOppMassTarget =
          prefs.getDouble('${_prefix}exp_opp_mass') ?? 0.80;
      _expectimaxMinProb = prefs.getDouble('${_prefix}exp_min_prob') ?? 0.02;
      _expectimaxMaxEvalLoss = prefs.getInt('${_prefix}exp_max_eval_loss') ?? 80;
      _expectimaxEvalDepth = prefs.getInt('${_prefix}exp_eval_depth') ?? 12;
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
      await prefs.setBool('${_prefix}show_expectimax_dock', _showExpectimaxDock);
      await prefs.setString(
          '${_prefix}opponent_prob_mode', _opponentProbabilityMode);
      await prefs.setString('${_prefix}explorer_database', _explorerDatabase);
      await prefs.setString('${_prefix}explorer_speeds', _explorerSpeeds);
      await prefs.setString('${_prefix}explorer_ratings', _explorerRatings);
      await prefs.setInt('${_prefix}maia_elo', _maiaElo);
      await prefs.setString(
          '${_prefix}candidate_source_our', _candidateSourceOur);
      await prefs.setString(
          '${_prefix}candidate_source_opp', _candidateSourceOpp);
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
    _depth = 15;
    _multiPv = 3;
    _inlineThreads = 1;
    _maxAnalysisMoves = 8;
    _showStockfish = true;
    _showMaia = true;
    _showProbability = true;
    _showEngineDock = true;
    _showExpectimaxDock = true;
    _opponentProbabilityMode = 'maia_lichess_fallback';
    _explorerDatabase = 'lichess';
    _explorerSpeeds = 'blitz,rapid,classical';
    _explorerRatings = '1800,2000,2200,2500';
    _probabilityStartMoves = '';
    _maiaElo = 2200;
    _candidateSourceOur = 'maia';
    _candidateSourceOpp = 'maia';
    _stockfishTopN = 3;
    _onTheFlyMaxDepth = 5;
    _expectimaxOurMultipv = 4;
    _expectimaxOppMaxChildren = 4;
    _expectimaxOppMassTarget = 0.80;
    _expectimaxMinProb = 0.02;
    _expectimaxMaxEvalLoss = 80;
    _expectimaxEvalDepth = 12;
    _mutedAnalysisColumns.clear();
    _persist();
    notifyListeners();
  }
}
