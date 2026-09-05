/// Engine settings model for configuring analysis parameters
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/engine_defaults.dart';
import '../utils/system_info.dart';
import 'settings_enums.dart';
import '../utils/safe_change_notifier.dart';

class EngineSettings with ChangeNotifier, SafeChangeNotifier {
  static const _prefix = 'engine_settings.';

  void _assignIfChanged<T>(T current, T next, void Function(T) assign) {
    if (current == next) return;
    assign(next);
    _persist();
    notifyListeners();
  }

  void _assignInRange<T extends num>(
    T current,
    T next,
    T min,
    T max,
    void Function(T) assign,
  ) {
    if (next < min || next > max) return;
    _assignIfChanged(current, next, assign);
  }

  // ── Stockfish settings ────────────────────────────────────────────────

  /// Number of parallel Stockfish workers (each: 1 thread, 128 MB hash).
  /// Defaults to one; users can increase this up to the logical core count.
  int _workers = kDefaultWorkers;
  int get workers => _workers;
  set workers(int value) => _assignIfChanged(
    _workers,
    value.clamp(1, systemCores),
    (v) => _workers = v,
  );

  int _depth = kDefaultDepth;
  int get depth => _depth;
  set depth(int value) =>
      _assignInRange(_depth, value, kMinDepth, kMaxDepth, (v) => _depth = v);

  int _multiPv = kDefaultMultiPv;
  int get multiPv => _multiPv;
  set multiPv(int value) => _assignInRange(
    _multiPv,
    value,
    kMinMultiPv,
    kMaxMultiPv,
    (v) => _multiPv = v,
  );

  /// Threads for the inline (PGN) engine worker.  Uses a single Stockfish
  /// process so more threads = faster search on one position.
  int _inlineThreads = kDefaultInlineThreads;
  int get inlineThreads => _inlineThreads;
  set inlineThreads(int value) => _assignIfChanged(
    _inlineThreads,
    value.clamp(1, systemCores),
    (v) => _inlineThreads = v,
  );

  /// Maximum total moves to display in the analysis table.
  /// Stockfish MultiPV lines fill guaranteed slots; remaining slots are
  /// filled by the highest-probability Maia + DB candidates.
  int _maxAnalysisMoves = kDefaultMaxAnalysisMoves;
  int get maxAnalysisMoves => _maxAnalysisMoves;
  set maxAnalysisMoves(int value) => _assignInRange(
    _maxAnalysisMoves,
    value,
    kMinMaxAnalysisMoves,
    kMaxMaxAnalysisMoves,
    (v) => _maxAnalysisMoves = v,
  );

  /// Text rows each engine row gives its principal variation. Above 1 the
  /// continuation wraps instead of being cut off at the pane edge.
  int _pvRows = kDefaultPvRows;
  int get pvRows => _pvRows;
  set pvRows(int value) => _assignInRange(
    _pvRows,
    value,
    kMinPvRows,
    kMaxPvRows,
    (v) => _pvRows = v,
  );

  // ── Panel visibility toggles ──────────────────────────────────────────

  bool _showStockfish = kDefaultShowStockfish;
  bool get showStockfish => _showStockfish;
  set showStockfish(bool value) =>
      _assignIfChanged(_showStockfish, value, (v) => _showStockfish = v);

  bool _showMaia = kDefaultShowMaia;
  bool get showMaia => _showMaia;
  set showMaia(bool value) =>
      _assignIfChanged(_showMaia, value, (v) => _showMaia = v);

  bool _showProbability = kDefaultShowProbability;
  bool get showProbability => _showProbability;
  set showProbability(bool value) =>
      _assignIfChanged(_showProbability, value, (v) => _showProbability = v);

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
  set showEngineDock(bool value) =>
      _assignIfChanged(_showEngineDock, value, (v) => _showEngineDock = v);

  bool _showExpectimaxDock = kDefaultShowExpectimaxDock;
  bool get showExpectimaxDock => _showExpectimaxDock;
  set showExpectimaxDock(bool value) => _assignIfChanged(
    _showExpectimaxDock,
    value,
    (v) => _showExpectimaxDock = v,
  );

  // ── Opponent probability source (engine table + line odds) ─────────────

  OpponentProbabilityMode _opponentProbabilityMode =
      OpponentProbabilityMode.maiaLichessFallback;
  OpponentProbabilityMode get opponentProbabilityMode =>
      _opponentProbabilityMode;
  set opponentProbabilityMode(OpponentProbabilityMode value) =>
      _assignIfChanged(
        _opponentProbabilityMode,
        value,
        (v) => _opponentProbabilityMode = v,
      );

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
    if (value != 'lichess' && value != 'masters') return;
    _assignIfChanged(_explorerDatabase, value, (v) => _explorerDatabase = v);
  }

  bool get explorerUseMasters => _explorerDatabase == 'masters';

  String _explorerSpeeds = kDefaultExplorerSpeeds;
  String get explorerSpeeds => _explorerSpeeds;
  set explorerSpeeds(String value) {
    if (value.isEmpty) return;
    _assignIfChanged(_explorerSpeeds, value, (v) => _explorerSpeeds = v);
  }

  String _explorerRatings = kDefaultExplorerRatings;
  String get explorerRatings => _explorerRatings;
  set explorerRatings(String value) {
    if (value.isEmpty) return;
    _assignIfChanged(_explorerRatings, value, (v) => _explorerRatings = v);
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
  set probabilityStartMoves(String value) => _assignIfChanged(
    _probabilityStartMoves,
    value,
    (v) => _probabilityStartMoves = v,
  );

  // ── Maia ELO setting ──────────────────────────────────────────────────

  int _maiaElo = kDefaultMaiaElo;
  int get maiaElo => _maiaElo;
  set maiaElo(int value) => _assignInRange(
    _maiaElo,
    value,
    kMinMaiaElo,
    kMaxMaiaElo,
    (v) => _maiaElo = v,
  );

  // ── Candidate source settings ──────────────────────────────────────────

  CandidateSource _candidateSourceOur = CandidateSource.maia;
  CandidateSource get candidateSourceOur => _candidateSourceOur;
  set candidateSourceOur(CandidateSource value) => _assignIfChanged(
    _candidateSourceOur,
    value,
    (v) => _candidateSourceOur = v,
  );

  CandidateSource _candidateSourceOpp = CandidateSource.maia;
  CandidateSource get candidateSourceOpp => _candidateSourceOpp;
  set candidateSourceOpp(CandidateSource value) => _assignIfChanged(
    _candidateSourceOpp,
    value,
    (v) => _candidateSourceOpp = v,
  );

  /// When using Stockfish for candidate generation, how many top moves.
  int _stockfishTopN = kDefaultStockfishTopN;
  int get stockfishTopN => _stockfishTopN;
  set stockfishTopN(int value) => _assignInRange(
    _stockfishTopN,
    value,
    kMinStockfishTopN,
    kMaxStockfishTopN,
    (v) => _stockfishTopN = v,
  );

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
      // Clamp persisted ints to their valid ranges: prefs written by an older
      // build (or on a machine with more cores) may fall outside them, and
      // out-of-range values crash the settings sliders.
      int loadInt(String key, int def, int min, int max) =>
          (prefs.getInt('$_prefix$key') ?? def).clamp(min, max);

      _workers = loadInt('workers', kDefaultWorkers, 1, systemCores);
      _depth = loadInt('depth', kDefaultDepth, kMinDepth, kMaxDepth);
      _multiPv = loadInt('multi_pv', kDefaultMultiPv, kMinMultiPv, kMaxMultiPv);
      _inlineThreads = loadInt(
        'inline_threads',
        kDefaultInlineThreads,
        1,
        systemCores,
      );
      _maxAnalysisMoves = loadInt(
        'max_analysis_moves',
        kDefaultMaxAnalysisMoves,
        kMinMaxAnalysisMoves,
        kMaxMaxAnalysisMoves,
      );
      _pvRows = loadInt('pv_rows', kDefaultPvRows, kMinPvRows, kMaxPvRows);
      _showStockfish =
          prefs.getBool('${_prefix}show_stockfish') ?? kDefaultShowStockfish;
      _showMaia = prefs.getBool('${_prefix}show_maia') ?? kDefaultShowMaia;
      _showProbability =
          prefs.getBool('${_prefix}show_probability') ??
          kDefaultShowProbability;
      _showEngineDock =
          prefs.getBool('${_prefix}show_engine_dock') ?? kDefaultShowEngineDock;
      _showExpectimaxDock =
          prefs.getBool('${_prefix}show_expectimax_dock') ??
          kDefaultShowExpectimaxDock;
      _opponentProbabilityMode = OpponentProbabilityMode.fromStorageKey(
        prefs.getString('${_prefix}opponent_prob_mode') ??
            'maia_lichess_fallback',
      );
      _explorerDatabase =
          prefs.getString('${_prefix}explorer_database') ??
          kDefaultExplorerDatabase;
      _explorerSpeeds =
          prefs.getString('${_prefix}explorer_speeds') ??
          kDefaultExplorerSpeeds;
      _explorerRatings =
          prefs.getString('${_prefix}explorer_ratings') ??
          kDefaultExplorerRatings;
      _maiaElo = loadInt('maia_elo', kDefaultMaiaElo, kMinMaiaElo, kMaxMaiaElo);
      _candidateSourceOur = CandidateSource.fromStorageKey(
        prefs.getString('${_prefix}candidate_source_our') ?? 'maia',
      );
      _candidateSourceOpp = CandidateSource.fromStorageKey(
        prefs.getString('${_prefix}candidate_source_opp') ?? 'maia',
      );
      _stockfishTopN = loadInt(
        'stockfish_top_n',
        kDefaultStockfishTopN,
        kMinStockfishTopN,
        kMaxStockfishTopN,
      );
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

  void _persist() {
    unawaited(_writePrefs());
  }

  Future<void> _writePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('${_prefix}workers', _workers);
      await prefs.setInt('${_prefix}depth', _depth);
      await prefs.setInt('${_prefix}multi_pv', _multiPv);
      await prefs.setInt('${_prefix}inline_threads', _inlineThreads);
      await prefs.setInt('${_prefix}max_analysis_moves', _maxAnalysisMoves);
      await prefs.setInt('${_prefix}pv_rows', _pvRows);
      await prefs.setBool('${_prefix}show_stockfish', _showStockfish);
      await prefs.setBool('${_prefix}show_maia', _showMaia);
      await prefs.setBool('${_prefix}show_probability', _showProbability);
      await prefs.setBool('${_prefix}show_engine_dock', _showEngineDock);
      await prefs.setBool(
        '${_prefix}show_expectimax_dock',
        _showExpectimaxDock,
      );
      await prefs.setString(
        '${_prefix}opponent_prob_mode',
        _opponentProbabilityMode.storageKey,
      );
      await prefs.setString('${_prefix}explorer_database', _explorerDatabase);
      await prefs.setString('${_prefix}explorer_speeds', _explorerSpeeds);
      await prefs.setString('${_prefix}explorer_ratings', _explorerRatings);
      await prefs.setInt('${_prefix}maia_elo', _maiaElo);
      await prefs.setString(
        '${_prefix}candidate_source_our',
        _candidateSourceOur.storageKey,
      );
      await prefs.setString(
        '${_prefix}candidate_source_opp',
        _candidateSourceOpp.storageKey,
      );
      await prefs.setInt('${_prefix}stockfish_top_n', _stockfishTopN);
      await prefs.setString(
        '${_prefix}probability_start_moves',
        _probabilityStartMoves,
      );
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
    _workers = kDefaultWorkers;
    _depth = kDefaultDepth;
    _multiPv = kDefaultMultiPv;
    _inlineThreads = kDefaultInlineThreads;
    _maxAnalysisMoves = kDefaultMaxAnalysisMoves;
    _pvRows = kDefaultPvRows;
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
    _mutedAnalysisColumns.clear();
    _persist();
    notifyListeners();
  }
}
