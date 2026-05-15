/// PGN Viewer mode — browse master game collections for study.
///
/// Features: file picker, position/header-based dataset slicing, game-by-game
/// navigation with counter, auto-play with configurable delay, 1-5 star game
/// rating (persisted as [StudyRating] PGN header, auto-saved), full-game
/// Stockfish analysis with eval graph, inline engine bar, and comment editing.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../services/game_analysis_controller.dart';
import '../utils/fen_utils.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/game_analysis_chart.dart';
import '../services/default_pgn_service.dart';
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
    final wStr = wElo != null && wElo.isNotEmpty && wElo != '?' ? '$w ($wElo)' : w;
    final bStr = bElo != null && bElo.isNotEmpty && bElo != '?' ? '$b ($bElo)' : b;
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

  const _Perspective({this.mode = _PerspectiveMode.white, this.playerName = ''});

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

class _PgnViewerScreenState extends State<PgnViewerScreen>
    with TickerProviderStateMixin {
  // File state
  String? _filePath;
  List<_PgnGameEntry> _allGames = [];
  List<_PgnGameEntry> _filteredGames = []; // after slicing
  bool _hasActiveFilters = false;

  // Current game
  int _currentGameIndex = 0;
  final PgnViewerController _pgnController = PgnViewerController();
  Position _currentPosition = Chess.initial;
  bool _boardFlipped = false;

  // Board perspective (persisted as [StudyPerspective] on first game)
  _Perspective _perspective = const _Perspective();

  // Tabs
  late final TabController _tabController;

  // Game analysis
  final GameAnalysisController _analysisController = GameAnalysisController();

  // Focus node for keyboard shortcuts
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnViewerScreen');

  // Auto-play
  Timer? _autoPlayTimer;
  bool _isAutoPlaying = false;
  bool _autoNextGame = false;
  double _autoPlayDelaySec = 2.0;

  // Sorting
  _SortMode _sortMode = _SortMode.fileOrder;

  // Recent files
  List<String> _recentFiles = [];
  static const _recentFilesKey = 'pgn_viewer_recent_files';
  static const _maxRecentFiles = 10;

  // Bundled collections discovered on disk
  List<io.File> _collectionFiles = [];
  String? _collectionsDir;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _analysisController.addListener(_onAnalysisUpdate);
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
    final files = await DefaultPgnService.listCollections();
    if (mounted) {
      setState(() {
        _collectionsDir = dir;
        _collectionFiles = files;
      });
    }
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
    _analysisController.removeListener(_onAnalysisUpdate);
    _analysisController.dispose();
    _autoPlayTimer?.cancel();
    _tabController.dispose();
    _focusNode.dispose();
    // Remove listener safely — context may not be usable here, but
    // Provider keeps the reference alive within the widget tree's scope.
    try {
      context.read<AppState>().removeListener(_onAppStateChanged);
    } catch (_) {}
    super.dispose();
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
    final content = await file.readAsString();
    final entries = _parseMultiGamePgn(content);
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
      _filePath = path;
      _allGames = entries;
      _filteredGames = List.of(entries);
      _hasActiveFilters = false;
      _sortMode = _SortMode.fileOrder;
      _currentGameIndex = 0;
      _perspective = perspective;
    });
    _addToRecentFiles(path);
    _loadCurrentGame(); // also reclaims focus
  }

  List<_PgnGameEntry> _parseMultiGamePgn(String content) {
    final entries = <_PgnGameEntry>[];
    // Split on [Event which marks the start of each game
    final chunks = content.split(RegExp(r'(?<=\n)\n*(?=\[Event )'));
    for (final chunk in chunks) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) continue;
      final headers = <String, String>{};
      for (final m in RegExp(r'\[(\w+)\s+"([^"]*)"\]').allMatches(trimmed)) {
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

  static String? _detectProtagonistFrom(List<_PgnGameEntry> games) {
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

  // -----------------------------------------------------------------------
  // Game navigation
  // -----------------------------------------------------------------------

  void _loadCurrentGame() {
    if (_filteredGames.isEmpty) return;
    _stopAutoPlay();
    _analysisController.cancel();
    _orientBoardForCurrentGame();
    // Try loading cached analysis from [%eval] comments in the PGN
    final game = _filteredGames[_currentGameIndex];
    _analysisController.tryLoadFromPgn(game.pgnText);
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
    _autoPlayTimer = Timer(
      Duration(milliseconds: (_autoPlayDelaySec * 1000).round()),
      _autoPlayStep,
    );
  }

  void _autoPlayStep() {
    if (!mounted || !_isAutoPlaying) return;
    // Try to advance one move
    if (_pgnController.currentFen != null) {
      _pgnController.goForward();
      // Check if position actually changed (i.e. there was a move to make)
      // We do this by scheduling a post-frame check
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isAutoPlaying) return;
        // If we're at end of game
        if (_pgnController.currentFen == _currentPosition.fen) {
          // Position didn't change — we're at the end
          if (_autoNextGame &&
              _currentGameIndex < _filteredGames.length - 1) {
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

  Future<void> _persistMetadata() async {
    if (_filePath == null) return;
    final buffer = StringBuffer();
    for (int i = 0; i < _allGames.length; i++) {
      if (i > 0) buffer.write('\n\n');
      final game = _allGames[i];
      var pgn = game.pgnText;

      // --- StudyRating ---
      if (game.studyRating > 0) {
        if (pgn.contains(RegExp(r'\[StudyRating\s+"[^"]*"\]'))) {
          pgn = pgn.replaceFirst(
            RegExp(r'\[StudyRating\s+"[^"]*"\]'),
            '[StudyRating "${game.studyRating}"]',
          );
        } else {
          final firstNewline = pgn.indexOf('\n');
          if (firstNewline != -1) {
            pgn =
                '${pgn.substring(0, firstNewline)}\n[StudyRating "${game.studyRating}"]${pgn.substring(firstNewline)}';
          }
        }
      } else {
        pgn = pgn.replaceFirst(RegExp(r'\[StudyRating\s+"[^"]*"\]\n?'), '');
      }

      // --- StudySummary ---
      if (game.studySummary.isNotEmpty) {
        final escaped = game.studySummary.replaceAll('"', "'");
        if (pgn.contains(RegExp(r'\[StudySummary\s+"[^"]*"\]'))) {
          pgn = pgn.replaceFirst(
            RegExp(r'\[StudySummary\s+"[^"]*"\]'),
            '[StudySummary "$escaped"]',
          );
        } else {
          final firstNewline = pgn.indexOf('\n');
          if (firstNewline != -1) {
            pgn =
                '${pgn.substring(0, firstNewline)}\n[StudySummary "$escaped"]${pgn.substring(firstNewline)}';
          }
        }
      } else {
        pgn = pgn.replaceFirst(RegExp(r'\[StudySummary\s+"[^"]*"\]\n?'), '');
      }

      game.pgnText = pgn;
      buffer.write(pgn);
    }
    buffer.write('\n');
    try {
      await io.File(_filePath!).writeAsString(buffer.toString());
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
        onApply: (indices) {
          setState(() {
            _filteredGames =
                indices.map((i) => _allGames[i]).toList();
            _hasActiveFilters = _filteredGames.length != _allGames.length;
            _currentGameIndex = 0;
          });
          _loadCurrentGame(); // also reclaims focus
        },
      ),
    ).then((_) => _reclaimFocus());
  }

  void _resetFilters() {
    setState(() {
      _filteredGames = List.of(_allGames);
      _hasActiveFilters = false;
      _currentGameIndex = 0;
    });
    _applySortMode();
    _loadCurrentGame(); // also reclaims focus
  }

  void _setSortMode(_SortMode mode) {
    setState(() => _sortMode = mode);
    _applySortMode();
    setState(() => _currentGameIndex = 0);
    _loadCurrentGame(); // also reclaims focus
  }

  void _applySortMode() {
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
      _setRating(_filteredGames.isNotEmpty && _filteredGames[_currentGameIndex].studyRating == 1 ? 0 : 1);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit2) {
      _setRating(_filteredGames.isNotEmpty && _filteredGames[_currentGameIndex].studyRating == 2 ? 0 : 2);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit3) {
      _setRating(_filteredGames.isNotEmpty && _filteredGames[_currentGameIndex].studyRating == 3 ? 0 : 3);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit4) {
      _setRating(_filteredGames.isNotEmpty && _filteredGames[_currentGameIndex].studyRating == 4 ? 0 : 4);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit5) {
      _setRating(_filteredGames.isNotEmpty && _filteredGames[_currentGameIndex].studyRating == 5 ? 0 : 5);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit0) {
      _setRating(0);
      return KeyEventResult.handled;

    // Analysis
    } else if (key == LogicalKeyboardKey.escape) {
      _pgnController.clearEphemeralMoves();
      return KeyEventResult.handled;

    // Tabs
    } else if (key == LogicalKeyboardKey.tab) {
      _tabController.animateTo((_tabController.index + 1) % _tabController.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -----------------------------------------------------------------------
  // Analysis node context menu (right-click / long-press on variation moves)
  // -----------------------------------------------------------------------

  void _showAnalysisNodeMenu(int nodeId, Offset globalPosition) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
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
        child: SafeArea(
          bottom: false,
          child: Column(
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
        ),
      ),
    );
  }

  // ── Top bar ──

  Widget _buildTopBar(ThemeData theme) {
    final fileName =
        _filePath != null ? _filePath!.split(io.Platform.pathSeparator).last : '';
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
            OutlinedButton.icon(
              onPressed: _openSliceDialog,
              icon: Icon(
                Icons.filter_alt,
                size: 18,
                color: _hasActiveFilters ? Colors.amber : null,
              ),
              label: Text(_hasActiveFilters
                  ? 'Slice (${_filteredGames.length}/${_allGames.length})'
                  : 'Slice'),
            ),
            if (_hasActiveFilters)
              IconButton(
                onPressed: _resetFilters,
                icon: const Icon(Icons.clear, size: 18),
                tooltip: 'Reset filters',
              ),
          ],
          const Spacer(),
          if (_filteredGames.isNotEmpty) ...[
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
            value: _Perspective(mode: _PerspectiveMode.player, playerName: protagonist),
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
    return Column(
      children: [
        // Tabs
        TabBar(
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
              if (_collectionFiles.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Collections',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                for (final file in _collectionFiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: InkWell(
                      onTap: () => _loadFile(file.path),
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
                            const Text('♔', style: TextStyle(fontSize: 14)),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                file.path
                                    .split(io.Platform.pathSeparator)
                                    .last
                                    .replaceAll('.pgn', ''),
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
        InlineEngineBar(fen: _currentPosition.fen),
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
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                    child: Text(
                      'Line: ${e.bestLine.join(' ')}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
          Row(
            children: [
              ..._buildStarRating(game.studyRating),
              const SizedBox(width: 8),
              _buildSortDropdown(),
              const Spacer(),
              _buildGameCounterDropdown(),
              const Spacer(),
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
                  onPressed:
                      _currentGameIndex < _filteredGames.length - 1
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
        final end =
            (_currentGameIndex + 25).clamp(0, _filteredGames.length);
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
        // Speed control
        PopupMenuButton<double>(
          tooltip: 'Auto-play speed',
          icon: Icon(Icons.speed, size: 20, color: Colors.grey[400]),
          onSelected: (val) {
            setState(() => _autoPlayDelaySec = val);
          },
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

