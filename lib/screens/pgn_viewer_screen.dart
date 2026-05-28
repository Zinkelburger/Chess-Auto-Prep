/// PGN Viewer mode — browse master game collections for study.
///
/// Features: file picker, position/header-based dataset slicing, game-by-game
/// navigation with counter, auto-play with configurable delay, 1-5 star game
/// rating (persisted as [StudyRating] PGN header, auto-saved), full-game
/// Stockfish analysis with eval graph, inline engine bar, and comment editing.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../models/opening_tree.dart';
import '../services/game_analysis_controller.dart';
import '../services/opening_tree_builder.dart';
import '../utils/fen_utils.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../services/default_pgn_service.dart';
import '../widgets/fullscreen_game_view.dart';
import '../widgets/game_analysis_tab.dart';
import '../widgets/game_nav_bar.dart';
import '../widgets/opening_tree_widget.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/pgn_slice_dialog.dart';

// ---------------------------------------------------------------------------
// Lightweight model wrapping a single parsed game + its raw text for rewrite.
// ---------------------------------------------------------------------------
class _PgnGameEntry {
  final Map<String, String> headers;
  String pgnText; // full single-game PGN (headers + moves)
  int studyRating; // 0 = unrated, 1-5
  String studySummary; // user's one-line summary of the game

  _PgnGameEntry({
    required this.headers,
    required this.pgnText,
    this.studyRating = 0,
    this.studySummary = '',
  });

  String get label {
    final w = headers['White'] ?? '?';
    final b = headers['Black'] ?? '?';
    final wElo = headers['WhiteElo'];
    final bElo = headers['BlackElo'];
    final wStr =
        wElo != null && wElo.isNotEmpty && wElo != '?' ? '$w ($wElo)' : w;
    final bStr =
        bElo != null && bElo.isNotEmpty && bElo != '?' ? '$b ($bElo)' : b;
    final d = headers['Date'] ?? '';
    return '$wStr vs $bStr  $d';
  }
}

// Sort mode is now GameSortMode from game_nav_bar.dart

final _digitKeys = {
  LogicalKeyboardKey.digit0: 0,
  LogicalKeyboardKey.digit1: 1,
  LogicalKeyboardKey.digit2: 2,
  LogicalKeyboardKey.digit3: 3,
  LogicalKeyboardKey.digit4: 4,
  LogicalKeyboardKey.digit5: 5,
};

/// Board perspective mode persisted as [StudyPerspective] header on first game.
enum _PerspectiveMode { white, black, player }

class _Perspective {
  final _PerspectiveMode mode;
  final String playerName; // only meaningful when mode == player

  const _Perspective(
      {this.mode = _PerspectiveMode.white, this.playerName = ''});

  String toHeaderValue() => switch (mode) {
        _PerspectiveMode.white => 'white',
        _PerspectiveMode.black => 'black',
        _PerspectiveMode.player => playerName,
      };

  static _Perspective fromHeaderValue(String value) {
    final v = value.trim();
    if (v.isEmpty || v == 'white' || v == 'auto') {
      return const _Perspective();
    }
    if (v == 'black') return const _Perspective(mode: _PerspectiveMode.black);
    return _Perspective(mode: _PerspectiveMode.player, playerName: v);
  }
}

class PgnViewerScreen extends StatefulWidget {
  const PgnViewerScreen({super.key});

  @override
  State<PgnViewerScreen> createState() => _PgnViewerScreenState();
}

// ---------------------------------------------------------------------------
// Top-level helpers used inside Isolate.run closures.
// Must NOT be class statics — Dart captures the enclosing class context
// when referencing static members from a closure, which pulls unsendable
// State/Widget objects into the isolate message.
// ---------------------------------------------------------------------------

final _chunkSplitRe = RegExp(r'(?<=\n)\n*(?=\[Event )');
final _headerRe = RegExp(r'\[(\w+)\s+"([^"]*)"\]');

List<_PgnGameEntry> _parseMultiGamePgn(String content) {
  final entries = <_PgnGameEntry>[];
  final chunks = content.split(_chunkSplitRe);
  for (final chunk in chunks) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
    final headers = <String, String>{};
    for (final m in _headerRe.allMatches(trimmed)) {
      headers[m.group(1)!] = m.group(2)!;
    }
    final rating = int.tryParse(headers['StudyRating'] ?? '') ?? 0;
    entries.add(_PgnGameEntry(
      headers: headers,
      pgnText: trimmed,
      studyRating: rating.clamp(0, 5),
      studySummary: headers['StudySummary'] ?? '',
    ));
  }
  return entries;
}

bool _gamePassesThroughPosition(
    Map<String, String> headers, String pgnText, String targetFen) {
  try {
    final game = PgnGame.parsePgn(pgnText);
    final mainline = game.moves.mainline().toList();

    Position pos;
    final setupFlag = headers['SetUp'] ?? headers['Setup'] ?? '';
    final fenHeader = headers['FEN'] ?? '';
    if (setupFlag == '1' && fenHeader.isNotEmpty) {
      pos = Chess.fromSetup(Setup.parseFen(expandFen(fenHeader)));
    } else {
      pos = Chess.initial;
    }

    if (normalizeFen(pos.fen) == targetFen) return true;
    for (final moveData in mainline) {
      final move = pos.parseSan(moveData.san);
      if (move == null) break;
      pos = pos.play(move);
      if (normalizeFen(pos.fen) == targetFen) return true;
    }
  } catch (_) { /* invalid position — will return false */ }
  return false;
}

bool _matchesFieldStatic(String headerVal, String query, MatchMode mode) {
  switch (mode) {
    case MatchMode.contains:
      return headerVal.toLowerCase().contains(query.toLowerCase());
    case MatchMode.exact:
      return headerVal.toLowerCase() == query.toLowerCase();
    case MatchMode.regex:
      try {
        return RegExp(query, caseSensitive: false).hasMatch(headerVal);
      } catch (_) {
        return false;
      }
    case MatchMode.after:
      return headerVal.compareTo(query) >= 0;
    case MatchMode.before:
      return headerVal.compareTo(query) <= 0;
  }
}

Future<List<int>> _applySliceConfig(
    SliceConfig config, List<GameRecord> games) {
  final posInput = config.positionInput;
  final filters = config.headerFilters
      .map((f) => (field: f.field, value: f.value, mode: f.mode))
      .toList();
  final gameData = games
      .map((g) =>
          (headers: Map<String, String>.from(g.headers), pgnText: g.pgnText))
      .toList();

  final seqPattern = config.sequencePattern;
  final seqGroups = (seqPattern != null && seqPattern.isNotEmpty)
      ? parseSequenceGroups(seqPattern)
      : const <List<String>>[];
  final seqGap = config.sequenceGap;
  final seqGroupsCopy = seqGroups.map((g) => List<String>.from(g)).toList();

  return Isolate.run(() {
    String? targetFen;
    if (posInput != null && posInput.isNotEmpty) {
      final input = posInput.trim();
      if (input.contains('/')) {
        try {
          final full = expandFen(input);
          Chess.fromSetup(Setup.parseFen(full));
          targetFen = normalizeFen(full);
        } catch (_) { /* invalid FEN input */ }
      } else {
        final tokens = input
            .replaceAll(RegExp(r'\d+\.+'), '')
            .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), '')
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList();
        if (tokens.isNotEmpty) {
          Position pos = Chess.initial;
          bool valid = true;
          for (final t in tokens) {
            final move = pos.parseSan(t);
            if (move == null) {
              valid = false;
              break;
            }
            pos = pos.play(move);
          }
          if (valid) targetFen = normalizeFen(pos.fen);
        }
      }
    }

    final indices = <int>[];
    for (int i = 0; i < gameData.length; i++) {
      final game = gameData[i];
      bool matches = true;

      if (targetFen != null) {
        matches =
            _gamePassesThroughPosition(game.headers, game.pgnText, targetFen);
      }

      if (matches && seqGroupsCopy.isNotEmpty) {
        matches = gameMatchesSequence(game.pgnText, seqGroupsCopy, seqGap);
      }

      if (matches) {
        for (final f in filters) {
          if (f.value.isEmpty) continue;
          final headerVal = game.headers[f.field] ?? '';
          if (!_matchesFieldStatic(headerVal, f.value, f.mode)) {
            matches = false;
            break;
          }
        }
      }

      if (matches) indices.add(i);
    }
    return indices;
  });
}

final _studyRatingRe = RegExp(r'\[StudyRating\s+"[^"]*"\]');
final _studyRatingLineRe = RegExp(r'\[StudyRating\s+"[^"]*"\]\n?');
final _studySummaryRe = RegExp(r'\[StudySummary\s+"[^"]*"\]');
final _studySummaryLineRe = RegExp(r'\[StudySummary\s+"[^"]*"\]\n?');

List<String> _buildMetadataOutput(
    List<({String pgn, int rating, String summary})> gameData) {
  final results = <String>[];
  for (final game in gameData) {
    var pgn = game.pgn;

    if (game.rating > 0) {
      if (_studyRatingRe.hasMatch(pgn)) {
        pgn =
            pgn.replaceFirst(_studyRatingRe, '[StudyRating "${game.rating}"]');
      } else {
        final firstNewline = pgn.indexOf('\n');
        if (firstNewline != -1) {
          pgn =
              '${pgn.substring(0, firstNewline)}\n[StudyRating "${game.rating}"]${pgn.substring(firstNewline)}';
        }
      }
    } else {
      pgn = pgn.replaceFirst(_studyRatingLineRe, '');
    }

    if (game.summary.isNotEmpty) {
      final escaped = game.summary.replaceAll('"', "'");
      if (_studySummaryRe.hasMatch(pgn)) {
        pgn = pgn.replaceFirst(_studySummaryRe, '[StudySummary "$escaped"]');
      } else {
        final firstNewline = pgn.indexOf('\n');
        if (firstNewline != -1) {
          pgn =
              '${pgn.substring(0, firstNewline)}\n[StudySummary "$escaped"]${pgn.substring(firstNewline)}';
        }
      }
    } else {
      pgn = pgn.replaceFirst(_studySummaryLineRe, '');
    }

    results.add(pgn);
  }
  return results;
}

String? _detectProtagonistFrom(List<_PgnGameEntry> games) {
  if (games.length < 2) return null;
  final sample = games.take(math.min(4, games.length));
  final counts = <String, int>{};
  for (final g in sample) {
    final w = g.headers['White'];
    final b = g.headers['Black'];
    if (w != null && w.isNotEmpty && w != '?') {
      counts[w] = (counts[w] ?? 0) + 1;
    }
    if (b != null && b.isNotEmpty && b != '?') {
      counts[b] = (counts[b] ?? 0) + 1;
    }
  }
  final sampleSize = sample.length;
  for (final entry in counts.entries) {
    if (entry.value >= sampleSize) return entry.key;
  }
  return null;
}

class _PgnViewerScreenState extends State<PgnViewerScreen>
    with TickerProviderStateMixin, WindowListener {
  // File state
  String? _filePath;
  List<_PgnGameEntry> _allGames = [];
  List<_PgnGameEntry> _filteredGames = []; // after slicing
  bool _hasActiveFilters = false;

  // Active slice (kept in sync with the dialog result)
  SliceConfig _activeSliceConfig = const SliceConfig.empty();
  static const _slicePrefsPrefix = 'pgn_slice:';

  // Current game
  int _currentGameIndex = 0;
  final PgnViewerController _pgnController = PgnViewerController();
  Position _currentPosition = Chess.initial;
  bool _boardFlipped = false;

  // Board perspective (persisted as [StudyPerspective] on first game)
  _Perspective _perspective = const _Perspective();

  // Tabs
  late final TabController _tabController;

  // Opening tree
  bool _showOpeningTree = false;
  OpeningTree? _openingTree;
  bool _buildingTree = false;
  int _treeBuildProcessed = 0;
  int _treeBuildTotal = 0;
  int _treeBuildGeneration = 0;
  final Map<String, List<int>> _treePositionGameCache = {};
  List<String> _treeCurrentMoveSequence = [];

  // Game analysis
  final GameAnalysisController _analysisController = GameAnalysisController();

  // Focus node for keyboard shortcuts
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnViewerScreen');

  // Loading state for heavy async operations
  bool _isLoading = false;

  // Auto-play
  Timer? _autoPlayTimer;
  bool _isAutoPlaying = false;
  bool _autoNextGame = false;
  double _autoPlayDelaySec = 1.0;
  bool _isFirstAutoPlayStep = false;
  DateTime? _lastAutoPlayStepTime;

  // Tracks which best-line / engine-line move is highlighted
  int? _activeEngineLineMoveIdx; // 0-based index within engine PV

  void _setAutoPlaySpeed(double val) {
    setState(() => _autoPlayDelaySec = val);
    if (!_isAutoPlaying || _lastAutoPlayStepTime == null) return;

    _autoPlayTimer?.cancel();
    final elapsedMs =
        DateTime.now().difference(_lastAutoPlayStepTime!).inMilliseconds;
    final newDelayMs = (val * 1000).round();
    final remainingMs = newDelayMs - elapsedMs;

    if (remainingMs <= 0) {
      _autoPlayStep();
    } else {
      _autoPlayTimer =
          Timer(Duration(milliseconds: remainingMs), _autoPlayStep);
    }
  }

  // Sorting
  GameSortMode _sortMode = GameSortMode.fileOrder;

  // Recent files
  List<String> _recentFiles = [];
  static const _recentFilesKey = 'pgn_viewer_recent_files';
  static const _maxRecentFiles = 10;

  // Default directory for the file picker (bundled collections folder)
  String? _collectionsDir;

  // Fullscreen watch mode
  bool _isFullScreen = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _analysisController.addListener(_onAnalysisUpdate);
    windowManager.addListener(this);
    _loadRecentFiles();
    _loadCollections();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().addListener(_onAppStateChanged);
      }
    });
  }

  void _onAppStateChanged() {
    final appState = context.read<AppState>();
    if (appState.currentMode == AppMode.pgnViewer) {
      _reclaimFocus();
    }
  }

  Future<void> _loadRecentFiles() async {
    final prefs = await SharedPreferences.getInstance();
    final files = prefs.getStringList(_recentFilesKey) ?? [];
    // Filter to only files that still exist
    final existing = <String>[];
    for (final f in files) {
      if (await io.File(f).exists()) existing.add(f);
    }
    if (mounted) setState(() => _recentFiles = existing);
  }

  Future<void> _loadCollections() async {
    final dir = await DefaultPgnService.collectionsPath;
    if (mounted) setState(() => _collectionsDir = dir);
  }

  Future<void> _addToRecentFiles(String path) async {
    _recentFiles.remove(path);
    _recentFiles.insert(0, path);
    if (_recentFiles.length > _maxRecentFiles) {
      _recentFiles = _recentFiles.sublist(0, _maxRecentFiles);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentFilesKey, _recentFiles);
  }

  void _onAnalysisUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _analysisController.removeListener(_onAnalysisUpdate);
    _analysisController.dispose();
    _autoPlayTimer?.cancel();
    _persistDebounce?.cancel();
    _tabController.dispose();
    _focusNode.dispose();
    try {
      context.read<AppState>().removeListener(_onAppStateChanged);
    } catch (_) { /* provider may already be disposed */ }
    super.dispose();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted && _isFullScreen) {
      setState(() => _isFullScreen = false);
    }
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted && !_isFullScreen) {
      setState(() => _isFullScreen = true);
    }
  }

  /// Re-claim keyboard focus after any interaction (button click, popup, etc.)
  /// that may have moved focus away from the root Focus node.
  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  // -----------------------------------------------------------------------
  // File loading
  // -----------------------------------------------------------------------

  Future<void> _pickFile() async {
    String? initialDir;
    if (_filePath != null) {
      initialDir = io.File(_filePath!).parent.path;
    } else if (_recentFiles.isNotEmpty) {
      initialDir = io.File(_recentFiles.first).parent.path;
    } else if (_collectionsDir != null) {
      initialDir = _collectionsDir;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
      initialDirectory: initialDir,
    );
    if (result == null || result.files.single.path == null) return;
    await _loadFile(result.files.single.path!);
  }

  Future<void> _loadFile(String path) async {
    final file = io.File(path);
    if (!await file.exists()) return;
    setState(() => _isLoading = true);
    final content = await file.readAsString();
    final entries = await compute(_parseMultiGamePgn, content);
    if (!mounted) return;
    // Read file-level perspective from first game's headers
    final perspectiveRaw = entries.isNotEmpty
        ? (entries.first.headers['StudyPerspective'] ?? '')
        : '';
    var perspective = _Perspective.fromHeaderValue(perspectiveRaw);

    // No explicit perspective saved — auto-detect the protagonist.
    if (perspectiveRaw.trim().isEmpty && entries.length >= 2) {
      final protagonist = _detectProtagonistFrom(entries);
      if (protagonist != null) {
        perspective = _Perspective(
          mode: _PerspectiveMode.player,
          playerName: protagonist,
        );
      }
    }

    setState(() {
      _isLoading = false;
      _filePath = path;
      _allGames = entries;
      _filteredGames = List.of(entries);
      _hasActiveFilters = false;
      _activeSliceConfig = const SliceConfig.empty();
      _sortMode = GameSortMode.fileOrder;
      _currentGameIndex = 0;
      _perspective = perspective;
      _openingTree = null;
      _showOpeningTree = false;
      _treeCurrentMoveSequence = [];
    });
    _addToRecentFiles(path);

    // Restore saved slice for this file, if any.
    await _tryRestoreSavedSlice(path, entries);

    _loadCurrentGame(); // also reclaims focus
  }

  Future<void> _tryRestoreSavedSlice(
      String path, List<_PgnGameEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('$_slicePrefsPrefix$path');
    if (json == null) return;
    final config = SliceConfig.fromJsonString(json);
    if (config.isEmpty) return;

    // Re-apply the saved slice.
    final allRecords =
        entries.map((g) => (headers: g.headers, pgnText: g.pgnText)).toList();
    setState(() => _isLoading = true);
    final indices = await _applySliceConfig(config, allRecords);
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (indices.length == entries.length) return; // no actual filtering

    if (!mounted) return;
    setState(() {
      _filteredGames = indices.map((i) => _allGames[i]).toList();
      _hasActiveFilters = true;
      _activeSliceConfig = config;
      _currentGameIndex = 0;
    });

    // Brief notification
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Restored last slice (${_filteredGames.length}/${_allGames.length} games)'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: _resetFilters,
        ),
      ));
    }
  }

  // -----------------------------------------------------------------------
  // Board perspective
  // -----------------------------------------------------------------------

  void _orientBoardForCurrentGame() {
    if (_filteredGames.isEmpty) return;
    final game = _filteredGames[_currentGameIndex];
    final w = (game.headers['White'] ?? '').toLowerCase().trim();
    final b = (game.headers['Black'] ?? '').toLowerCase().trim();

    switch (_perspective.mode) {
      case _PerspectiveMode.white:
        setState(() => _boardFlipped = false);
      case _PerspectiveMode.black:
        setState(() => _boardFlipped = true);
      case _PerspectiveMode.player:
        final target = _perspective.playerName.toLowerCase().trim();
        if (b == target) {
          setState(() => _boardFlipped = true);
        } else if (w == target) {
          setState(() => _boardFlipped = false);
        }
    }
  }

  void _setPerspective(_Perspective p) {
    setState(() => _perspective = p);
    _persistPerspective();
    _orientBoardForCurrentGame();
    _reclaimFocus();
  }

  /// Persist perspective as [StudyPerspective] header on the first game.
  Future<void> _persistPerspective() async {
    if (_allGames.isEmpty) return;
    final first = _allGames.first;
    final value = _perspective.toHeaderValue();
    first.headers['StudyPerspective'] = value;

    var pgn = first.pgnText;
    if (pgn.contains(RegExp(r'\[StudyPerspective\s+"[^"]*"\]'))) {
      pgn = pgn.replaceFirst(
        RegExp(r'\[StudyPerspective\s+"[^"]*"\]'),
        '[StudyPerspective "$value"]',
      );
    } else {
      final firstNewline = pgn.indexOf('\n');
      if (firstNewline != -1) {
        pgn =
            '${pgn.substring(0, firstNewline)}\n[StudyPerspective "$value"]${pgn.substring(firstNewline)}';
      }
    }
    first.pgnText = pgn;

    _persistMetadata();
  }

  /// Detect a likely "protagonist" by looking at the first few games.
  /// If one player appears in all of them, they're probably the focus.
  String? _detectProtagonist() => _detectProtagonistFrom(_allGames);

  // -----------------------------------------------------------------------
  // Game navigation
  // -----------------------------------------------------------------------

  Future<void> _loadCurrentGame() async {
    if (_filteredGames.isEmpty) return;
    _stopAutoPlay();
    _analysisController.cancel();
    _orientBoardForCurrentGame();
    final game = _filteredGames[_currentGameIndex];
    await _analysisController.tryLoadFromPgn(game.pgnText);
    if (!mounted) return;
    setState(() {});
    _reclaimFocus();
  }

  void _nextGame() {
    if (_filteredGames.isEmpty) return;
    setState(() {
      _currentGameIndex =
          (_currentGameIndex + 1).clamp(0, _filteredGames.length - 1);
    });
    _loadCurrentGame();
  }

  void _prevGame() {
    if (_filteredGames.isEmpty) return;
    setState(() {
      _currentGameIndex =
          (_currentGameIndex - 1).clamp(0, _filteredGames.length - 1);
    });
    _loadCurrentGame();
  }

  void _goToGame(int index) {
    if (index < 0 || index >= _filteredGames.length) return;
    setState(() => _currentGameIndex = index);
    _loadCurrentGame();
  }

  // -----------------------------------------------------------------------
  // Auto-play
  // -----------------------------------------------------------------------

  void _toggleAutoPlay() {
    if (_isAutoPlaying) {
      _stopAutoPlay();
    } else {
      _startAutoPlay();
    }
    _reclaimFocus();
  }

  void _startAutoPlay() {
    _isFirstAutoPlayStep = true;
    setState(() => _isAutoPlaying = true);
    _scheduleNextAutoPlayStep();
  }

  void _stopAutoPlay() {
    _autoPlayTimer?.cancel();
    _autoPlayTimer = null;
    if (_isAutoPlaying) {
      setState(() => _isAutoPlaying = false);
    }
  }

  void _scheduleNextAutoPlayStep() {
    _autoPlayTimer?.cancel();
    if (!_isAutoPlaying) return;
    final delayMs = _isFirstAutoPlayStep
        ? 300
        : (_autoPlayDelaySec * 1000).round();
    _isFirstAutoPlayStep = false;
    _autoPlayTimer = Timer(Duration(milliseconds: delayMs), _autoPlayStep);
  }

  void _autoPlayStep() {
    if (!mounted || !_isAutoPlaying) return;
    if (_pgnController.currentFen == null) return;
    _lastAutoPlayStepTime = DateTime.now();

    final fenBefore = _pgnController.currentFen;
    _pgnController.goForward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isAutoPlaying) return;
      final fenAfter = _pgnController.currentFen;
      if (fenAfter == fenBefore) {
        // Position didn't change — we're at the end
        if (_autoNextGame && _currentGameIndex < _filteredGames.length - 1) {
          _nextGame();
          _startAutoPlay();
        } else {
          _stopAutoPlay();
        }
      } else {
        _scheduleNextAutoPlayStep();
      }
    });
  }

  // -----------------------------------------------------------------------
  // Fullscreen watch mode
  // -----------------------------------------------------------------------

  Future<void> _toggleFullScreen() async {
    final entering = !_isFullScreen;
    await windowManager.setFullScreen(entering);
    if (mounted) {
      setState(() => _isFullScreen = entering);
      _reclaimFocus();
    }
  }

  Future<void> _exitFullScreen() async {
    if (!_isFullScreen) return;
    await windowManager.setFullScreen(false);
    if (mounted) {
      setState(() => _isFullScreen = false);
      _reclaimFocus();
    }
  }

  // -----------------------------------------------------------------------
  // Rating
  // -----------------------------------------------------------------------

  void _setRating(int stars) {
    if (_filteredGames.isEmpty) return;
    final game = _filteredGames[_currentGameIndex];
    setState(() => game.studyRating = stars);
    _persistMetadata();
    _reclaimFocus();
  }

  Timer? _persistDebounce;

  Future<void> _persistMetadata() async {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 300), () {
      _doPersistMetadata();
    });
  }

  Future<void> _doPersistMetadata() async {
    if (_filePath == null) return;
    final gameData = _allGames
        .map((g) =>
            (pgn: g.pgnText, rating: g.studyRating, summary: g.studySummary))
        .toList();

    final result = await compute(_buildMetadataOutput, gameData);

    if (!mounted) return;
    for (int i = 0; i < result.length && i < _allGames.length; i++) {
      _allGames[i].pgnText = result[i];
    }
    try {
      await io.File(_filePath!).writeAsString('${result.join('\n\n')}\n');
    } catch (e) {
      debugPrint('Failed to persist metadata: $e');
    }
  }

  /// Persist updated move comments back to the PGN file for the current game.
  void _persistMoveComments(String updatedPgnMovetext) {
    if (_filteredGames.isEmpty || _filePath == null) return;
    final game = _filteredGames[_currentGameIndex];

    // Replace the movetext portion of the PGN (everything after the headers)
    final headerEnd = RegExp(r'\]\s*\n').allMatches(game.pgnText).last;
    final headerPart = game.pgnText.substring(0, headerEnd.end);
    game.pgnText = '$headerPart\n$updatedPgnMovetext\n';

    _persistMetadata();
  }

  // -----------------------------------------------------------------------
  // Slicing
  // -----------------------------------------------------------------------

  void _openSliceDialog() {
    showDialog(
      context: context,
      builder: (ctx) => PgnSliceDialog(
        allGames: _allGames
            .map((g) => (headers: g.headers, pgnText: g.pgnText))
            .toList(),
        currentFen: normalizeFen(_currentPosition.fen),
        initialConfig: _activeSliceConfig.isEmpty ? null : _activeSliceConfig,
        onApply: (indices, config) {
          setState(() {
            _filteredGames = indices.map((i) => _allGames[i]).toList();
            _hasActiveFilters = _filteredGames.length != _allGames.length;
            _activeSliceConfig = config;
            _currentGameIndex = 0;
            _openingTree = null;
          });
          _persistSliceConfig(config);
          if (_showOpeningTree) _rebuildOpeningTree();
          _loadCurrentGame(); // also reclaims focus
        },
      ),
    ).then((_) => _reclaimFocus());
  }

  void _resetFilters() {
    setState(() {
      _filteredGames = List.of(_allGames);
      _hasActiveFilters = false;
      _activeSliceConfig = const SliceConfig.empty();
      _currentGameIndex = 0;
      _openingTree = null;
    });
    _clearSavedSlice();
    _applySortMode();
    if (_showOpeningTree) _rebuildOpeningTree();
    _loadCurrentGame(); // also reclaims focus
  }

  /// Remove a single filter chip by its index in the active config's chip
  /// labels and re-apply the remaining filters.
  Future<void> _removeSliceChip(int chipIndex) async {
    final labels = _activeSliceConfig.chipLabels;
    if (chipIndex < 0 || chipIndex >= labels.length) return;

    final hasPos = _activeSliceConfig.positionInput != null &&
        _activeSliceConfig.positionInput!.isNotEmpty;
    final hasSeq = _activeSliceConfig.sequencePattern != null &&
        _activeSliceConfig.sequencePattern!.isNotEmpty;
    String? newPositionInput = _activeSliceConfig.positionInput;
    String? newSequencePattern = _activeSliceConfig.sequencePattern;
    int newSequenceGap = _activeSliceConfig.sequenceGap;
    final newHeaders =
        List<HeaderFilterConfig>.from(_activeSliceConfig.headerFilters);

    int idx = chipIndex;
    if (hasPos && idx == 0) {
      newPositionInput = null;
      idx = -1;
    } else if (hasPos) {
      idx--;
    }

    if (idx >= 0 && hasSeq && idx == 0) {
      newSequencePattern = null;
      idx = -1;
    } else if (hasSeq && idx >= 0) {
      idx--;
    }

    if (idx >= 0) {
      int count = -1;
      for (int i = 0; i < newHeaders.length; i++) {
        if (newHeaders[i].value.isNotEmpty) count++;
        if (count == idx) {
          newHeaders.removeAt(i);
          break;
        }
      }
    }

    final newConfig = SliceConfig(
        positionInput: newPositionInput,
        headerFilters: newHeaders,
        sequencePattern: newSequencePattern,
        sequenceGap: newSequenceGap);

    if (newConfig.isEmpty) {
      _resetFilters();
      return;
    }

    final allRecords =
        _allGames.map((g) => (headers: g.headers, pgnText: g.pgnText)).toList();
    setState(() => _isLoading = true);
    final indices = await _applySliceConfig(newConfig, allRecords);
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _filteredGames = indices.map((i) => _allGames[i]).toList();
      _hasActiveFilters = _filteredGames.length != _allGames.length;
      _activeSliceConfig = newConfig;
      _currentGameIndex = 0;
      _openingTree = null;
    });
    _persistSliceConfig(newConfig);
    if (_showOpeningTree) _rebuildOpeningTree();
    _loadCurrentGame();
  }

  Future<void> _persistSliceConfig(SliceConfig config) async {
    if (_filePath == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (config.isEmpty) {
      await prefs.remove('$_slicePrefsPrefix$_filePath');
    } else {
      await prefs.setString(
          '$_slicePrefsPrefix$_filePath', config.toJsonString());
    }
  }

  Future<void> _clearSavedSlice() async {
    if (_filePath == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_slicePrefsPrefix$_filePath');
  }

  void _setSortMode(GameSortMode mode) {
    setState(() => _sortMode = mode);
    _applySortMode();
    setState(() => _currentGameIndex = 0);
    _loadCurrentGame(); // also reclaims focus
  }

  void _applySortMode() {
    _treePositionGameCache.clear();
    switch (_sortMode) {
      case GameSortMode.fileOrder:
        // Re-derive from _allGames in original order, preserving filters
        if (_hasActiveFilters) {
          final filteredSet = _filteredGames.toSet();
          _filteredGames =
              _allGames.where((g) => filteredSet.contains(g)).toList();
        } else {
          _filteredGames = List.of(_allGames);
        }
      case GameSortMode.ratingDesc:
        _filteredGames.sort((a, b) {
          final aSort = a.studyRating == 0 ? 3 : a.studyRating;
          final bSort = b.studyRating == 0 ? 3 : b.studyRating;
          return bSort.compareTo(aSort);
        });
      case GameSortMode.ratingAsc:
        _filteredGames.sort((a, b) {
          final aSort = a.studyRating == 0 ? 3 : a.studyRating;
          final bSort = b.studyRating == 0 ? 3 : b.studyRating;
          return aSort.compareTo(bSort);
        });
    }
  }

  void _onPositionChanged(Position pos) {
    setState(() {
      _currentPosition = pos;
      // Clear engine line highlight only when leaving the variation entirely
      if (_activeEngineLineMoveIdx != null &&
          _pgnController.variationDepth == 0) {
        _activeEngineLineMoveIdx = null;
      }
    });
  }

  // -----------------------------------------------------------------------
  // Opening tree
  // -----------------------------------------------------------------------

  void _toggleOpeningTree() {
    setState(() => _showOpeningTree = !_showOpeningTree);
    if (_showOpeningTree && _openingTree == null && _filteredGames.isNotEmpty) {
      _rebuildOpeningTree();
    }
    _reclaimFocus();
  }

  Future<void> _rebuildOpeningTree() async {
    final generation = ++_treeBuildGeneration;
    if (_filteredGames.isEmpty) {
      setState(() {
        _openingTree = null;
        _buildingTree = false;
        _treeBuildProcessed = 0;
        _treeBuildTotal = 0;
        _treePositionGameCache.clear();
      });
      return;
    }
    setState(() {
      _buildingTree = true;
      _treeBuildProcessed = 0;
      _treeBuildTotal = _filteredGames.length;
      _treePositionGameCache.clear();
    });
    try {
      final tree = await OpeningTreeBuilder.buildTree(
        pgnList: _filteredGames.map((g) => g.pgnText).toList(),
        username: '',
        userIsWhite: null,
        strictPlayerMatching: false,
        maxDepth: 50,
        onProgress: (processed, total) {
          if (!mounted || generation != _treeBuildGeneration) return;
          setState(() {
            _treeBuildProcessed = processed;
            _treeBuildTotal = total;
          });
        },
      );
      if (!mounted || generation != _treeBuildGeneration) return;
      setState(() {
        _openingTree = tree;
        _buildingTree = false;
        _treeBuildProcessed = _treeBuildTotal;
        _treeCurrentMoveSequence = [];
      });
    } catch (e) {
      if (!mounted || generation != _treeBuildGeneration) return;
      setState(() {
        _buildingTree = false;
        _openingTree = null;
        _treeBuildProcessed = 0;
        _treeBuildTotal = 0;
      });
      debugPrint('Failed to build opening tree: $e');
    }
  }

  void _onTreeMoveSelected(String move) {
    if (_openingTree == null) return;
    _openingTree!.makeMove(move);
    setState(() {
      _treeCurrentMoveSequence = _openingTree!.currentNode.getMovePath();
    });
  }

  void _onTreeGoBack() {
    if (_openingTree == null) return;
    _openingTree!.goBack();
    setState(() {
      _treeCurrentMoveSequence = _openingTree!.currentNode.getMovePath();
    });
  }

  void _onTreeGoForward() {
    if (_openingTree == null) return;
    final children = _openingTree!.currentNode.sortedChildren;
    if (children.isNotEmpty) {
      _onTreeMoveSelected(children.first.move);
    }
  }

  static const _maxTreeCacheEntries = 500;

  /// Find games from the filtered set that pass through the current tree position.
  List<int> _gamesAtTreePosition() {
    if (_openingTree == null) return [];
    final fen = normalizeFen(_openingTree!.currentNode.fen);
    return _treePositionGameCache.putIfAbsent(fen, () {
      if (_treePositionGameCache.length >= _maxTreeCacheEntries) {
        // Evict oldest entries to bound memory.
        final keysToRemove = _treePositionGameCache.keys
            .take(_maxTreeCacheEntries ~/ 4)
            .toList();
        for (final k in keysToRemove) {
          _treePositionGameCache.remove(k);
        }
      }
      final results = <int>[];
      for (int i = 0; i < _filteredGames.length; i++) {
        if (_gamePassesThroughPosition(
            _filteredGames[i].headers, _filteredGames[i].pgnText, fen)) {
          results.add(i);
        }
      }
      return results;
    });
  }

  void _loadGameFromTree(int filteredIndex) {
    setState(() {
      _showOpeningTree = false;
      _currentGameIndex = filteredIndex;
    });
    _loadCurrentGame();
  }

  // -----------------------------------------------------------------------
  // Export
  // -----------------------------------------------------------------------

  Future<void> _exportSlice() async {
    if (_filteredGames.isEmpty || _filePath == null) return;

    final defaultName = '${p.basenameWithoutExtension(_filePath!)}_slice.pgn';

    final outPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export ${_filteredGames.length} filtered games',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: ['pgn'],
      initialDirectory: p.dirname(_filePath!),
    );
    if (outPath == null) {
      _reclaimFocus();
      return;
    }

    final savePath = outPath.endsWith('.pgn') ? outPath : '$outPath.pgn';
    final content = _filteredGames.map((g) => g.pgnText).join('\n\n');
    try {
      await io.File(savePath).writeAsString('$content\n');
      if (!mounted) return;
      final fileName = p.basename(savePath);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Exported ${_filteredGames.length} games to $fileName'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => _loadFile(savePath),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
    _reclaimFocus();
  }

  // -----------------------------------------------------------------------
  // Keyboard
  // -----------------------------------------------------------------------

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Don't intercept keys when a text field is focused
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null && primaryFocus.context != null) {
      final widget = primaryFocus.context!.widget;
      if (widget is EditableText) return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // Move navigation
    if (key == LogicalKeyboardKey.arrowLeft) {
      _stopAutoPlay();
      _pgnController.goBack();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _stopAutoPlay();
      _pgnController.goForward();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.home) {
      _stopAutoPlay();
      _pgnController.clearEphemeralMoves();
      _pgnController.jumpToMove(1, true);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.end) {
      _stopAutoPlay();
      final len = _pgnController.mainLineLength;
      if (len > 0) {
        final moveNum = (len + 1) ~/ 2;
        final isWhite = len % 2 == 1;
        _pgnController.jumpToMove(moveNum, isWhite);
      }
      return KeyEventResult.handled;

      // Game navigation
    } else if (key == LogicalKeyboardKey.keyN) {
      _nextGame();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyP) {
      _prevGame();
      return KeyEventResult.handled;

      // Fullscreen (Ctrl+F, Shift+F, or F11)
    } else if (key == LogicalKeyboardKey.f11) {
      _toggleFullScreen();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyF &&
        (HardwareKeyboard.instance.isShiftPressed ||
         HardwareKeyboard.instance.isControlPressed)) {
      _toggleFullScreen();
      return KeyEventResult.handled;

      // Board & engine
    } else if (key == LogicalKeyboardKey.keyF) {
      setState(() => _boardFlipped = !_boardFlipped);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyE) {
      InlineEngineBar.toggleEngine();
      return KeyEventResult.handled;

      // Playback
    } else if (key == LogicalKeyboardKey.space) {
      _toggleAutoPlay();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyA) {
      setState(() => _autoNextGame = !_autoNextGame);
      return KeyEventResult.handled;

      // Rating (1-5 toggles, 0 clears)
    } else if (_digitKeys.containsKey(key)) {
      final star = _digitKeys[key]!;
      final current = _filteredGames.isNotEmpty
          ? _filteredGames[_currentGameIndex].studyRating
          : 0;
      _setRating(current == star ? 0 : star);
      return KeyEventResult.handled;

      // Escape: exit fullscreen first, then clear analysis
    } else if (key == LogicalKeyboardKey.escape) {
      if (_isFullScreen) {
        _exitFullScreen();
      } else {
        _pgnController.clearEphemeralMoves();
      }
      return KeyEventResult.handled;

      // Tabs
    } else if (key == LogicalKeyboardKey.tab) {
      _tabController
          .animateTo((_tabController.index + 1) % _tabController.length);
      return KeyEventResult.handled;

      // Opening tree toggle
    } else if (key == LogicalKeyboardKey.keyT) {
      _toggleOpeningTree();
      return KeyEventResult.handled;

      // Export
    } else if (key == LogicalKeyboardKey.keyE &&
        HardwareKeyboard.instance.isControlPressed) {
      _exportSlice();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -----------------------------------------------------------------------
  // Analysis node context menu (right-click / long-press on variation moves)
  // -----------------------------------------------------------------------

  void _showAnalysisNodeMenu(int nodeId, Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    showMenu<String>(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Delete variation'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'clear_all',
          child: Row(
            children: [
              Icon(Icons.clear_all, size: 18),
              SizedBox(width: 8),
              Text('Clear all analysis'),
            ],
          ),
        ),
      ],
    ).then((action) {
      if (action == 'delete') {
        _pgnController.deleteAnalysisNode(nodeId);
      } else if (action == 'clear_all') {
        _pgnController.clearEphemeralMoves();
      }
      _reclaimFocus();
    });
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _reclaimFocus,
        child: _isFullScreen
            ? _buildFullScreenView(theme)
            : SafeArea(
                bottom: false,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        _buildTopBar(theme),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              if (constraints.maxWidth >= 960) {
                                return _buildWideLayout();
                              }
                              return _buildNarrowLayout();
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_isLoading)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black26,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  // ── Fullscreen watch view ──

  Widget _buildFullScreenView(ThemeData theme) {
    return FullscreenGameView(
      position: _currentPosition,
      boardFlipped: _boardFlipped,
      gameLabel: _filteredGames.isNotEmpty
          ? _filteredGames[_currentGameIndex].label
          : '',
      currentIndex: _currentGameIndex,
      totalGames: _filteredGames.length,
      isAutoPlaying: _isAutoPlaying,
      autoPlayDelaySec: _autoPlayDelaySec,
      autoNextGame: _autoNextGame,
      onBoardMove: (san) {
        _stopAutoPlay();
        _pgnController.addEphemeralMove(san);
      },
      onPrev: _prevGame,
      onNext: _nextGame,
      onGoBack: () {
        _stopAutoPlay();
        _pgnController.goBack();
      },
      onGoForward: () {
        _stopAutoPlay();
        _pgnController.goForward();
      },
      onToggleAutoPlay: _toggleAutoPlay,
      onExit: _exitFullScreen,
      onSetSpeed: _setAutoPlaySpeed,
      onSetAutoNext: (v) => setState(() => _autoNextGame = v),
    );
  }

  // ── Top bar ──

  Widget _buildTopBar(ThemeData theme) {
    final fileName = _filePath != null
        ? _filePath!.split(io.Platform.pathSeparator).last
        : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Text('PGN Viewer', style: theme.textTheme.titleMedium),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(fileName.isEmpty ? 'Open PGN' : fileName),
          ),
          if (_allGames.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(child: _buildSliceChips()),
          ] else
            const Spacer(),
          if (_filteredGames.isNotEmpty) ...[
            IconButton(
              onPressed: _exportSlice,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: 'Export filtered games (Ctrl+E)',
            ),
            IconButton(
              onPressed: () => setState(() => _boardFlipped = !_boardFlipped),
              icon: const Icon(Icons.swap_vert, size: 20),
              tooltip: 'Flip board (F)',
            ),
            _buildPerspectiveButton(),
          ],
          const AppModeMenuButton(),
        ],
      ),
    );
  }

  /// Inline filter chips showing active slice criteria + an "add" chip.
  Widget _buildSliceChips() {
    final chipLabels = _activeSliceConfig.chipLabels;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // Active filter chips
          for (int i = 0; i < chipLabels.length; i++) ...[
            _buildActiveChip(chipLabels[i], i),
            const SizedBox(width: 4),
          ],
          // Add / Slice chip
          _buildAddSliceChip(),
          if (_hasActiveFilters) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: Colors.blue.withAlpha(60), width: 0.5),
              ),
              child: Text(
                '${_filteredGames.length}/${_allGames.length}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue[300],
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveChip(String label, int index) {
    return GestureDetector(
      onTap: _openSliceDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.blue[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withAlpha(60), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.blue[100],
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _removeSliceChip(index),
              child: Icon(Icons.close,
                  size: 13, color: Colors.blue[300]!.withAlpha(180)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddSliceChip() {
    return Tooltip(
      message: _hasActiveFilters ? 'Edit filters' : 'Add filter',
      child: GestureDetector(
        onTap: _openSliceDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hasActiveFilters
                  ? Colors.blue.withAlpha(40)
                  : Colors.grey[700]!,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add,
                size: 13,
                color: _hasActiveFilters ? Colors.blue[300] : Colors.grey[400],
              ),
              const SizedBox(width: 3),
              Text(
                _hasActiveFilters ? 'Edit' : 'Slice',
                style: TextStyle(
                  fontSize: 11,
                  color:
                      _hasActiveFilters ? Colors.blue[300] : Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPerspectiveButton() {
    final protagonist = _detectProtagonist();
    final isPlayerMode = _perspective.mode == _PerspectiveMode.player;
    final isWhiteMode = _perspective.mode == _PerspectiveMode.white;
    final isBlackMode = _perspective.mode == _PerspectiveMode.black;

    final label = switch (_perspective.mode) {
      _PerspectiveMode.white => 'White',
      _PerspectiveMode.black => 'Black',
      _PerspectiveMode.player => _perspective.playerName,
    };

    return PopupMenuButton<_Perspective>(
      tooltip: 'Default view as',
      onSelected: _setPerspective,
      itemBuilder: (ctx) => [
        if (protagonist != null)
          PopupMenuItem(
            value: _Perspective(
                mode: _PerspectiveMode.player, playerName: protagonist),
            child: Row(children: [
              if (isPlayerMode && _perspective.playerName == protagonist)
                const Icon(Icons.check, size: 16)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(protagonist),
            ]),
          ),
        PopupMenuItem(
          value: const _Perspective(mode: _PerspectiveMode.white),
          child: Row(children: [
            if (isWhiteMode)
              const Icon(Icons.check, size: 16)
            else
              const SizedBox(width: 16),
            const SizedBox(width: 8),
            const Text('Always White'),
          ]),
        ),
        PopupMenuItem(
          value: const _Perspective(mode: _PerspectiveMode.black),
          child: Row(children: [
            if (isBlackMode)
              const Icon(Icons.check, size: 16)
            else
              const SizedBox(width: 16),
            const SizedBox(width: 8),
            const Text('Always Black'),
          ]),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[700]!),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  // ── Wide layout ──

  Widget _buildWideLayout() {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: _buildBoardPane(),
        ),
        Container(width: 1, color: Colors.grey[700]),
        Expanded(
          flex: 5,
          child: _buildSidePanel(),
        ),
      ],
    );
  }

  // ── Narrow layout ──

  Widget _buildNarrowLayout() {
    return Column(
      children: [
        Expanded(flex: 4, child: _buildBoardPane()),
        const Divider(height: 1),
        Expanded(flex: 6, child: _buildSidePanel()),
      ],
    );
  }

  // ── Board ──

  Widget _buildBoardPane() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: ChessBoardWidget(
            position: _currentPosition,
            flipped: _boardFlipped,
            onMove: (move) {
              _stopAutoPlay();
              _pgnController.addEphemeralMove(move.san);
            },
          ),
        ),
      ),
    );
  }

  // ── Side panel (tabs + game nav) ──

  Widget _buildSidePanel() {
    if (_showOpeningTree) return _buildOpeningTreePanel();
    return Column(
      children: [
        // Tabs header with tree toggle
        Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                tabs: [
                  const Tab(text: 'Game'),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Analysis'),
                        if (_analysisController.isAnalyzing) ...[
                          const SizedBox(width: 6),
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_filteredGames.isNotEmpty)
              Tooltip(
                message: 'Opening tree (T)',
                child: IconButton(
                  icon: Icon(Icons.account_tree,
                      size: 20, color: Colors.grey[400]),
                  onPressed: _toggleOpeningTree,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildGameTab(),
              GameAnalysisTab(
                analysisController: _analysisController,
                pgnController: _pgnController,
                currentPly: _currentPly,
                variationDepth: _pgnController.variationDepth,
                gamePgnText: _filteredGames.isNotEmpty
                    ? _filteredGames[_currentGameIndex].pgnText
                    : null,
                onAnnotatedMovetext: _persistMoveComments,
                onUserNavigation: () {
                  _stopAutoPlay();
                  _reclaimFocus();
                },
              ),
            ],
          ),
        ),
        // Game navigation bar
        if (_filteredGames.isNotEmpty)
          GameNavBar(
            games: _filteredGames
                .map((g) => GameNavItem(
                      label: g.label,
                      studyRating: g.studyRating,
                      studySummary: g.studySummary,
                    ))
                .toList(),
            currentIndex: _currentGameIndex,
            currentRating: _filteredGames[_currentGameIndex].studyRating,
            sortMode: _sortMode,
            isAutoPlaying: _isAutoPlaying,
            autoPlayDelaySec: _autoPlayDelaySec,
            autoNextGame: _autoNextGame,
            onPrev: _prevGame,
            onNext: _nextGame,
            onGoToGame: _goToGame,
            onSetRating: _setRating,
            onSetSortMode: _setSortMode,
            onToggleAutoPlay: _toggleAutoPlay,
            onToggleFullScreen: _toggleFullScreen,
            onSetSpeed: _setAutoPlaySpeed,
            onSetAutoNext: (v) => setState(() => _autoNextGame = v),
          ),
      ],
    );
  }

  // ── Opening tree panel ──

  Widget _buildOpeningTreePanel() {
    return Column(
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey[700]!),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: _toggleOpeningTree,
                tooltip: 'Back to Game/Analysis (T)',
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Text(
                'Opening Tree',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.grey[200],
                ),
              ),
              const Spacer(),
              if (_buildingTree)
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _treeBuildTotal > 0
                              ? 'Building $_treeBuildProcessed / $_treeBuildTotal'
                              : 'Building tree...',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[400],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // Tree content
        if (_buildingTree)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _treeBuildTotal > 0
                        ? 'Building tree... $_treeBuildProcessed / $_treeBuildTotal games'
                        : 'Building tree...',
                    style: TextStyle(color: Colors.grey[300], fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  if (_treeBuildTotal > 0)
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value: _treeBuildProcessed / _treeBuildTotal,
                      ),
                    ),
                ],
              ),
            ),
          )
        else if (_openingTree == null)
          Expanded(
            child: Center(
              child: Text(
                'No tree available.\nLoad games to build.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500]),
              ),
            ),
          )
        else ...[
          Expanded(
            child: OpeningTreeWidget(
              tree: _openingTree!,
              onMoveSelected: _onTreeMoveSelected,
              onGoBack: _onTreeGoBack,
              onGoForward: _onTreeGoForward,
              currentMoveSequence: _treeCurrentMoveSequence,
            ),
          ),
          _buildTreeGamesList(),
        ],
      ],
    );
  }

  Widget _buildTreeGamesList() {
    final matchingIndices = _gamesAtTreePosition();
    if (matchingIndices.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey[700]!)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              '${matchingIndices.length} game${matchingIndices.length == 1 ? '' : 's'} at this position',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[400],
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: matchingIndices.length,
              itemBuilder: (context, idx) {
                final gi = matchingIndices[idx];
                final game = _filteredGames[gi];
                return InkWell(
                  onTap: () => _loadGameFromTree(gi),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    child: Row(
                      children: [
                        Icon(Icons.play_arrow,
                            size: 14, color: Colors.blue[300]),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            game.label,
                            style: const TextStyle(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (game.studyRating > 0) ...[
                          const Icon(Icons.star, size: 12, color: Colors.amber),
                          Text('${game.studyRating}',
                              style: const TextStyle(fontSize: 10)),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Game tab ──

  Widget _buildGameTab() {
    if (_filteredGames.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 16),
              Text(
                'No PGN loaded',
                style: TextStyle(color: Colors.grey[400], fontSize: 16),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _pickFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open PGN File'),
              ),
              if (_recentFiles.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Recent',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                for (final path in _recentFiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: InkWell(
                      onTap: () => _loadFile(path),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.grey[800]!),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.description,
                                size: 16, color: Colors.grey[500]),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                path.split(io.Platform.pathSeparator).last,
                                style: TextStyle(
                                  color: Colors.blue[300],
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    }
    final game = _filteredGames[_currentGameIndex];
    return Column(
      children: [
        InlineEngineBar(
          fen: _currentPosition.fen,
          onLineMoveTapped: _onEngineLineMoveTapped,
          activeLineMoveIndex: _activeEngineLineMoveIdx != null
              ? (_pgnController.variationDepth > 0
                  ? _pgnController.variationDepth - 1
                  : _activeEngineLineMoveIdx)
              : null,
        ),
        const Divider(height: 1),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('game_$_currentGameIndex'),
            pgnText: game.pgnText,
            controller: _pgnController,
            onPositionChanged: _onPositionChanged,
            onAnalysisNodeAction: _showAnalysisNodeMenu,
            onCommentsChanged: _persistMoveComments,
          ),
        ),
      ],
    );
  }

  // ── Analysis tab (delegated to GameAnalysisTab widget) ──

  /// Handle a click on a move in an engine line (inline engine bar).
  /// Adds moves 0..clickedIndex as ephemeral variations from the current position.
  void _onEngineLineMoveTapped(List<String> sanMoves, int clickedIndex) {
    if (sanMoves.isEmpty || clickedIndex < 0) return;
    _stopAutoPlay();

    // Add entire line so arrow keys can continue past the clicked move
    for (final san in sanMoves) {
      _pgnController.addEphemeralMove(san);
    }

    // Navigate back to the clicked position
    final stepsBack = sanMoves.length - 1 - clickedIndex;
    for (int i = 0; i < stepsBack; i++) {
      _pgnController.goBack();
    }

    setState(() {
      _activeEngineLineMoveIdx = clickedIndex;
    });
    _reclaimFocus();
  }

  int get _currentPly {
    return _pgnController.mainLineIndex;
  }


  // ── Game navigation bar ──

}

