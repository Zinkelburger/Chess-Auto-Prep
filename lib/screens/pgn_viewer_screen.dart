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
import '../widgets/game_analysis_chart.dart';
import '../services/default_pgn_service.dart';
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

enum _SortMode { fileOrder, ratingDesc, ratingAsc }

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
  } catch (_) {}
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
        } catch (_) {}
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
  _SortMode _sortMode = _SortMode.fileOrder;

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
    } catch (_) {}
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
      _sortMode = _SortMode.fileOrder;
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

  void _setSortMode(_SortMode mode) {
    setState(() => _sortMode = mode);
    _applySortMode();
    setState(() => _currentGameIndex = 0);
    _loadCurrentGame(); // also reclaims focus
  }

  void _applySortMode() {
    _treePositionGameCache.clear();
    switch (_sortMode) {
      case _SortMode.fileOrder:
        // Re-derive from _allGames in original order, preserving filters
        if (_hasActiveFilters) {
          final filteredSet = _filteredGames.toSet();
          _filteredGames =
              _allGames.where((g) => filteredSet.contains(g)).toList();
        } else {
          _filteredGames = List.of(_allGames);
        }
      case _SortMode.ratingDesc:
        _filteredGames.sort((a, b) {
          final aSort = a.studyRating == 0 ? 3 : a.studyRating;
          final bSort = b.studyRating == 0 ? 3 : b.studyRating;
          return bSort.compareTo(aSort);
        });
      case _SortMode.ratingAsc:
        _filteredGames.sort((a, b) {
          final aSort = a.studyRating == 0 ? 3 : a.studyRating;
          final bSort = b.studyRating == 0 ? 3 : b.studyRating;
          return aSort.compareTo(bSort);
        });
    }
  }

  void _onPositionChanged(Position pos) {
    setState(() => _currentPosition = pos);
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

      // Rating (1-5, 0 to clear)
    } else if (key == LogicalKeyboardKey.digit1) {
      _setRating(_filteredGames.isNotEmpty &&
              _filteredGames[_currentGameIndex].studyRating == 1
          ? 0
          : 1);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit2) {
      _setRating(_filteredGames.isNotEmpty &&
              _filteredGames[_currentGameIndex].studyRating == 2
          ? 0
          : 2);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit3) {
      _setRating(_filteredGames.isNotEmpty &&
              _filteredGames[_currentGameIndex].studyRating == 3
          ? 0
          : 3);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit4) {
      _setRating(_filteredGames.isNotEmpty &&
              _filteredGames[_currentGameIndex].studyRating == 4
          ? 0
          : 4);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit5) {
      _setRating(_filteredGames.isNotEmpty &&
              _filteredGames[_currentGameIndex].studyRating == 5
          ? 0
          : 5);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit0) {
      _setRating(0);
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
    final gameLabel = _filteredGames.isNotEmpty
        ? _filteredGames[_currentGameIndex].label
        : '';

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        children: [
          // Board fills entire screen
          Center(
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
          // Game info overlay at top (fades out after inactivity via mouse)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _FullScreenOverlayBar(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withAlpha(180),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        gameLabel,
                        style: TextStyle(
                          color: Colors.white.withAlpha(200),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_filteredGames.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          '${_currentGameIndex + 1} / ${_filteredGames.length}',
                          style: TextStyle(
                            color: Colors.white.withAlpha(140),
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Controls overlay at bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _FullScreenOverlayBar(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withAlpha(180),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed:
                          _currentGameIndex > 0 ? _prevGame : null,
                      icon: Icon(Icons.skip_previous,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Previous game (P)',
                    ),
                    IconButton(
                      onPressed: () {
                        _stopAutoPlay();
                        _pgnController.goBack();
                      },
                      icon: Icon(Icons.chevron_left,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Back (←)',
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _toggleAutoPlay,
                      icon: Icon(
                        _isAutoPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 40,
                        color: _isAutoPlaying
                            ? Colors.amber
                            : Colors.white.withAlpha(220),
                      ),
                      tooltip: _isAutoPlaying ? 'Pause (Space)' : 'Watch game (Space)',
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () {
                        _stopAutoPlay();
                        _pgnController.goForward();
                      },
                      icon: Icon(Icons.chevron_right,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Forward (→)',
                    ),
                    IconButton(
                      onPressed:
                          _currentGameIndex < _filteredGames.length - 1
                              ? _nextGame
                              : null,
                      icon: Icon(Icons.skip_next,
                          color: Colors.white.withAlpha(180)),
                      tooltip: 'Next game (N)',
                    ),
                    const SizedBox(width: 12),
                    // Speed control
                    PopupMenuButton<double>(
                      tooltip: 'Auto-play speed',
                      icon: Icon(Icons.speed,
                          size: 20, color: Colors.white.withAlpha(160)),
                      color: Colors.grey[900],
                      onSelected: _setAutoPlaySpeed,
                      itemBuilder: (ctx) => [
                        for (final s in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0])
                          PopupMenuItem(
                            value: s,
                            child: Row(
                              children: [
                                if (s == _autoPlayDelaySec)
                                  const Icon(Icons.check,
                                      size: 16, color: Colors.amber)
                                else
                                  const SizedBox(width: 16),
                                const SizedBox(width: 8),
                                Text('${s}s / move',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    // Auto next game toggle
                    Tooltip(
                      message: 'Auto next game (A)',
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _autoNextGame = !_autoNextGame),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: _autoNextGame
                                ? Colors.amber.withAlpha(40)
                                : Colors.white.withAlpha(15),
                            border: Border.all(
                              color: _autoNextGame
                                  ? Colors.amber.withAlpha(120)
                                  : Colors.white.withAlpha(40),
                            ),
                          ),
                          child: Text(
                            'Auto',
                            style: TextStyle(
                              fontSize: 11,
                              color: _autoNextGame
                                  ? Colors.amber
                                  : Colors.white.withAlpha(160),
                              fontWeight: _autoNextGame
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Exit fullscreen button (always visible, top-right corner)
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              onPressed: _exitFullScreen,
              icon: Icon(Icons.fullscreen_exit,
                  color: Colors.white.withAlpha(120), size: 28),
              tooltip: 'Exit fullscreen (Esc)',
            ),
          ),
        ],
      ),
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
              _buildAnalysisTab(),
            ],
          ),
        ),
        // Game navigation bar
        if (_filteredGames.isNotEmpty) _buildGameNavBar(),
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

  // ── Analysis tab ──

  void _startAnalysis() {
    if (_filteredGames.isEmpty) return;
    final game = _filteredGames[_currentGameIndex];
    _analysisController.analyzeGame(
      game.pgnText,
      onAnnotatedMovetext: (annotated) {
        _persistMoveComments(annotated);
      },
    );
  }

  void _onAnalysisPlySelected(int ply) {
    if (ply <= 0) return;
    _stopAutoPlay();
    final moveNum = (ply + 1) ~/ 2;
    final isWhite = ply % 2 == 1;
    _pgnController.clearEphemeralMoves();
    _pgnController.jumpToMove(moveNum, isWhite);
    _reclaimFocus();
  }

  /// Handle a click on a move in an engine line (inline engine bar).
  /// Adds moves 0..clickedIndex as ephemeral variations from the current position.
  void _onEngineLineMoveTapped(List<String> sanMoves, int clickedIndex) {
    if (sanMoves.isEmpty || clickedIndex < 0) return;
    _stopAutoPlay();
    final end = (clickedIndex + 1).clamp(0, sanMoves.length);
    for (int i = 0; i < end; i++) {
      _pgnController.addEphemeralMove(sanMoves[i]);
    }
    _reclaimFocus();
  }

  /// Navigate into the best line for a classified move, adding moves 1..N
  /// as ephemeral variations and landing on the Nth move.
  void _onBestLineMoveClicked(MoveEval eval, int moveIndex) {
    if (eval.bestLine.isEmpty || moveIndex < 0) return;
    _stopAutoPlay();

    // The best line starts from the position *before* the blunder, so jump
    // to ply-1 (the parent position).
    final branchPly = eval.ply - 1;
    if (branchPly < 0) return;
    final moveNum = (branchPly + 1 + 1) ~/ 2; // 1-based move number
    final isWhite = (branchPly + 1) % 2 == 1;
    _pgnController.clearEphemeralMoves();
    _pgnController.jumpToMove(moveNum, isWhite);

    // Feed moves 0..moveIndex into the PGN viewer as ephemeral analysis
    final end = (moveIndex + 1).clamp(0, eval.bestLine.length);
    for (int i = 0; i < end; i++) {
      _pgnController.addEphemeralMove(eval.bestLine[i]);
    }
    _reclaimFocus();
  }

  Widget _buildClickableBestLine(MoveEval eval) {
    final line = eval.bestLine;
    // Starting context: best line branches from position before the move,
    // so the first move in the best line is played by the same side.
    final startPly = eval.ply - 1;
    var moveNum = (startPly ~/ 2) + 1;
    var isWhite = startPly % 2 == 0;

    final children = <InlineSpan>[];
    children.add(TextSpan(
      text: 'Best: ',
      style: TextStyle(
        fontSize: 11,
        color: Colors.grey[600],
        fontFamily: 'monospace',
        fontWeight: FontWeight.bold,
      ),
    ));

    for (int i = 0; i < line.length; i++) {
      if (isWhite) {
        children.add(TextSpan(
          text: '$moveNum.',
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
            fontFamily: 'monospace',
          ),
        ));
      } else if (i == 0) {
        children.add(TextSpan(
          text: '$moveNum...',
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
            fontFamily: 'monospace',
          ),
        ));
      }

      final idx = i;
      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _onBestLineMoveClicked(eval, idx),
            child: Text(
              '${line[i]} ',
              style: TextStyle(
                fontSize: 11,
                color: Colors.teal[300],
                fontFamily: 'monospace',
                decoration: TextDecoration.underline,
                decorationColor: Colors.teal[300]!.withAlpha(80),
                decorationStyle: TextDecorationStyle.dotted,
              ),
            ),
          ),
        ),
      ));

      if (!isWhite) moveNum++;
      isWhite = !isWhite;
    }

    return RichText(
      text: TextSpan(children: children),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  int get _currentPly {
    return _pgnController.mainLineIndex;
  }

  Widget _buildAnalysisTab() {
    if (_filteredGames.isEmpty) {
      return Center(
        child: Text(
          'Load a PGN to analyze',
          style: TextStyle(color: Colors.grey[500]),
        ),
      );
    }

    final evals = _analysisController.evals;
    final isAnalyzing = _analysisController.isAnalyzing;
    final total = _analysisController.totalMoves;
    final done = _analysisController.analyzedMoves;

    return Column(
      children: [
        // Analyze button / progress
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (!isAnalyzing)
                FilledButton.icon(
                  onPressed: _startAnalysis,
                  icon: const Icon(Icons.analytics, size: 18),
                  label: Text(evals.isEmpty ? 'Analyze Game' : 'Re-analyze'),
                )
              else ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Analyzing move $done / $total  (depth ${_analysisController.depth})',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: total > 0 ? done / total : 0,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _analysisController.cancel,
                  icon: const Icon(Icons.stop, size: 20),
                  tooltip: 'Stop analysis',
                  visualDensity: VisualDensity.compact,
                ),
              ],
              if (!isAnalyzing && evals.isNotEmpty) ...[
                const Spacer(),
                _buildDepthSelector(),
              ],
            ],
          ),
        ),
        // Chart
        if (evals.isNotEmpty) ...[
          GameAnalysisChart(
            evals: evals,
            startWinChance: _analysisController.startWinChance,
            currentPly: _currentPly,
            onPlySelected: _onAnalysisPlySelected,
          ),
          const Divider(height: 1),
          // Summary stats
          GameAnalysisSummary(evals: evals),
          const Divider(height: 1),
          // Move list with classifications
          Expanded(child: _buildAnalysisMoveList(evals)),
        ] else if (!isAnalyzing) ...[
          const Spacer(),
          Icon(Icons.show_chart, size: 48, color: Colors.grey[700]),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _startAnalysis,
            icon: const Icon(Icons.analytics, size: 20),
            label: const Text('Analyze Game'),
          ),
          const Spacer(),
        ] else
          const Spacer(),
      ],
    );
  }

  Widget _buildDepthSelector() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Depth:', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        const SizedBox(width: 4),
        PopupMenuButton<int>(
          tooltip: 'Analysis depth',
          onSelected: (d) => setState(() => _analysisController.depth = d),
          itemBuilder: (ctx) => [
            for (final d in [10, 12, 14, 16, 18, 20, 22, 24])
              PopupMenuItem(
                value: d,
                child: Row(
                  children: [
                    if (d == _analysisController.depth)
                      const Icon(Icons.check, size: 16)
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Text('$d'),
                  ],
                ),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.grey[700]!),
            ),
            child: Text(
              '${_analysisController.depth}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAnalysisMoveList(List<MoveEval> evals) {
    // Only show moves with classifications (and some context)
    final interesting = <MoveEval>[];
    for (final e in evals) {
      if (e.classification != MoveClassification.normal) {
        interesting.add(e);
      }
    }

    if (interesting.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No inaccuracies, mistakes, blunders, or interesting moves found.',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: interesting.length,
      itemBuilder: (context, index) {
        final e = interesting[index];
        final moveNum = (e.ply + 1) ~/ 2;
        final dots = e.isWhiteMove ? '.' : '...';

        final Color classColor;
        final String classLabel;
        switch (e.classification) {
          case MoveClassification.blunder:
            classColor = const Color(0xFFDB3B21);
            classLabel = 'Blunder';
          case MoveClassification.mistake:
            classColor = const Color(0xFFE69F00);
            classLabel = 'Mistake';
          case MoveClassification.inaccuracy:
            classColor = const Color(0xFF56B4E9);
            classLabel = 'Inaccuracy';
          case MoveClassification.interesting:
            classColor = const Color(0xFF9C27B0);
            classLabel = 'Interesting';
          case MoveClassification.normal:
            classColor = Colors.grey;
            classLabel = '';
        }

        final evalStr = _formatEvalCp(e);

        return InkWell(
          onTap: () => _onAnalysisPlySelected(e.ply),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(
                        '$moveNum$dots',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ),
                    Text(
                      e.san,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: classColor.withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: classColor.withAlpha(80)),
                      ),
                      child: Text(
                        classLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: classColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      evalStr,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.grey[400],
                      ),
                    ),
                  ],
                ),
                if (e.bestLine.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, top: 3),
                    child: _buildClickableBestLine(e),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatEvalCp(MoveEval e) {
    if (e.scoreMate != null) return '#${e.scoreMate}';
    if (e.scoreCp != null) {
      final v = e.scoreCp! / 100.0;
      return v >= 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1);
    }
    return '--';
  }

  // ── Game navigation bar ──

  Widget _buildGameNavBar() {
    final game = _filteredGames[_currentGameIndex];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Colors.grey[700]!),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rating + sort + counter row
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ..._buildStarRating(game.studyRating),
                  const SizedBox(width: 8),
                  _buildSortDropdown(),
                ],
              ),
              _buildGameCounterDropdown(),
              _buildAutoPlayControls(),
            ],
          ),
          const SizedBox(height: 4),
          // Prev / Next row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Tooltip(
                message: 'Previous game (P)',
                child: TextButton.icon(
                  onPressed: _currentGameIndex > 0 ? _prevGame : null,
                  icon: const Icon(Icons.skip_previous, size: 20),
                  label: const Text('Prev'),
                ),
              ),
              const SizedBox(width: 24),
              Tooltip(
                message: 'Next game (N)',
                child: TextButton.icon(
                  onPressed: _currentGameIndex < _filteredGames.length - 1
                      ? _nextGame
                      : null,
                  icon: const Icon(Icons.skip_next, size: 20),
                  label: const Text('Next'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSortDropdown() {
    return PopupMenuButton<_SortMode>(
      tooltip: 'Sort games',
      onSelected: _setSortMode,
      itemBuilder: (ctx) => [
        for (final mode in _SortMode.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                if (mode == _sortMode)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(switch (mode) {
                  _SortMode.fileOrder => 'File order',
                  _SortMode.ratingDesc => 'Stars (high first)',
                  _SortMode.ratingAsc => 'Stars (low first)',
                }),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[700]!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort, size: 16, color: Colors.grey[400]),
            const SizedBox(width: 4),
            Text(
              switch (_sortMode) {
                _SortMode.fileOrder => 'File order',
                _SortMode.ratingDesc => 'Stars ↓',
                _SortMode.ratingAsc => 'Stars ↑',
              },
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildStarRating(int current) {
    return List.generate(5, (i) {
      final star = i + 1;
      return Tooltip(
        message: 'Rate $star star${star > 1 ? 's' : ''} ($star)',
        child: GestureDetector(
          onTap: () => _setRating(current == star ? 0 : star),
          child: Icon(
            star <= current ? Icons.star : Icons.star_border,
            size: 22,
            color: star <= current ? Colors.amber : Colors.grey[600],
          ),
        ),
      );
    });
  }

  Widget _buildGameCounterDropdown() {
    return PopupMenuButton<int>(
      tooltip: 'Jump to game',
      itemBuilder: (ctx) {
        // Show up to 50 items around current index
        final start = (_currentGameIndex - 25).clamp(0, _filteredGames.length);
        final end = (_currentGameIndex + 25).clamp(0, _filteredGames.length);
        return [
          for (int i = start; i < end; i++)
            PopupMenuItem(
              value: i,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${i + 1}.',
                          style: TextStyle(
                            fontWeight: i == _currentGameIndex
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _filteredGames[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: i == _currentGameIndex
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (_filteredGames[i].studyRating > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 4),
                            const Icon(Icons.star,
                                size: 14, color: Colors.amber),
                            Text(
                              '${_filteredGames[i].studyRating}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                    ],
                  ),
                  if (_filteredGames[i].studySummary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 36, top: 2),
                      child: Text(
                        _filteredGames[i].studySummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ];
      },
      onSelected: _goToGame,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[700]!),
        ),
        child: Text(
          'Game ${_currentGameIndex + 1} / ${_filteredGames.length}',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildAutoPlayControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Auto-play toggle
        IconButton(
          onPressed: _filteredGames.isNotEmpty ? _toggleAutoPlay : null,
          icon: Icon(
            _isAutoPlaying ? Icons.pause_circle : Icons.play_circle,
            size: 28,
            color: _isAutoPlaying ? Colors.amber : null,
          ),
          tooltip: _isAutoPlaying ? 'Pause (Space)' : 'Watch game (Space)',
        ),
        // Fullscreen watch mode
        IconButton(
          onPressed: _filteredGames.isNotEmpty ? _toggleFullScreen : null,
          icon: Icon(Icons.fullscreen, size: 24, color: Colors.grey[400]),
          tooltip: 'Fullscreen (Ctrl+F)',
          visualDensity: VisualDensity.compact,
        ),
        // Speed control
        PopupMenuButton<double>(
          tooltip: 'Auto-play speed',
          icon: Icon(Icons.speed, size: 20, color: Colors.grey[400]),
          onSelected: _setAutoPlaySpeed,
          itemBuilder: (ctx) => [
            for (final s in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0])
              PopupMenuItem(
                value: s,
                child: Row(
                  children: [
                    if (s == _autoPlayDelaySec)
                      const Icon(Icons.check, size: 16)
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Text('${s}s / move'),
                  ],
                ),
              ),
          ],
        ),
        // Auto next game toggle
        Tooltip(
          message: 'Auto next game (A)',
          child: FilterChip(
            label: const Text('Auto', style: TextStyle(fontSize: 11)),
            selected: _autoNextGame,
            onSelected: (v) => setState(() => _autoNextGame = v),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }
}

/// Overlay bar for fullscreen mode that fades in on mouse movement
/// and fades out after a period of inactivity.
class _FullScreenOverlayBar extends StatefulWidget {
  final Widget child;

  const _FullScreenOverlayBar({required this.child});

  @override
  State<_FullScreenOverlayBar> createState() => _FullScreenOverlayBarState();
}

class _FullScreenOverlayBarState extends State<_FullScreenOverlayBar> {
  bool _visible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _onHover() {
    if (!_visible) {
      setState(() => _visible = true);
    }
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => _onHover(),
      onEnter: (_) => _onHover(),
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 400),
        child: IgnorePointer(
          ignoring: !_visible,
          child: widget.child,
        ),
      ),
    );
  }
}
