import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'pgn/auto_play_engine.dart';
import 'pgn/pgn_collection_helpers.dart';
export 'pgn/pgn_collection_helpers.dart';
import 'pgn/pgn_fen_index.dart';
import 'pgn/slice_persistence.dart';
import 'pgn/solitaire_controller.dart';
import 'pgn/viewer_opening_tree.dart';
import '../models/opening_tree.dart';
import '../models/pgn_filter_models.dart';
import '../models/pgn_game_entry.dart';
export '../models/pgn_game_entry.dart';
import '../services/default_pgn_service.dart';
import '../services/game_analysis_controller.dart';
import '../services/opening_book_service.dart';
import '../services/solitaire_trophy_service.dart';
import '../services/storage/storage_factory.dart';
import 'pgn/pgn_viewer_handle.dart';
import '../utils/safe_change_notifier.dart';

part 'pgn/pgn_viewer_controller_metadata.dart';
part 'pgn/pgn_viewer_controller_slices.dart';
part 'pgn/pgn_viewer_controller_solitaire.dart';
part 'pgn/pgn_viewer_controller_window.dart';

/// Board perspective mode persisted as [StudyPerspective] header on first game.
enum PerspectiveMode { white, black, player }

class Perspective {
  final PerspectiveMode mode;
  final String playerName; // only meaningful when mode == player

  const Perspective({this.mode = PerspectiveMode.white, this.playerName = ''});

  String toHeaderValue() => switch (mode) {
    PerspectiveMode.white => 'white',
    PerspectiveMode.black => 'black',
    PerspectiveMode.player => playerName,
  };

  static Perspective fromHeaderValue(String value) {
    final v = value.trim();
    if (v.isEmpty || v == 'white' || v == 'auto') {
      return const Perspective();
    }
    if (v == 'black') return const Perspective(mode: PerspectiveMode.black);
    return Perspective(mode: PerspectiveMode.player, playerName: v);
  }
}

/// Business logic and state for the PGN Viewer screen.
///
/// Cohesive member groups live in same-library part files as private mixins:
/// slice operations ([_SliceOps]), metadata/comment persistence
/// ([_MetadataOps]), solitaire mode ([_SolitaireOps]), and window/perspective
/// handling ([_WindowOps]).
class PgnViewerController extends ChangeNotifier
    with
        SafeChangeNotifier,
        _SliceOps,
        _MetadataOps,
        _SolitaireOps,
        _WindowOps {
  PgnViewerController({
    required this.pgnWidgetController,
    required this.analysisController,
    this.isActive = _alwaysActive,
    this.schedulePostFrame,
    this.onReclaimFocus,
  });

  @override
  final PgnViewerHandle pgnWidgetController;
  final GameAnalysisController analysisController;
  @override
  final bool Function() isActive;
  final void Function(void Function() callback)? schedulePostFrame;
  @override
  final VoidCallback? onReclaimFocus;

  static bool _alwaysActive() => true;

  // File state
  @override
  String? filePath;
  @override
  List<PgnGameEntry> allGames = [];
  @override
  List<PgnGameEntry> filteredGames = [];
  @override
  bool hasActiveFilters = false;

  @override
  SliceConfig activeSliceConfig = const SliceConfig.empty();

  /// Surname of the player the loaded collection is about (null when mixed).
  /// Drives the one-click "«Player» as White/Black" slice presets.
  String? sliceProtagonist;

  /// When the whole file has the protagonist on one side only ("all Kasparov
  /// black games"), that side; null when they play both colors.
  Side? protagonistFixedSide;

  /// Coloring for tree win/draw/loss stats: player-POV green/red when we know
  /// whose games the current slice shows, neutral white/black otherwise.
  WdlPerspective get wdlPerspective {
    final p = sliceProtagonist;
    if (p != null) {
      for (final h in activeSliceConfig.headerFilters) {
        if (h.value != p || h.mode == MatchMode.notContains) continue;
        if (h.field == 'White') return WdlPerspective.playerIsWhite;
        if (h.field == 'Black') return WdlPerspective.playerIsBlack;
      }
      if (protagonistFixedSide == Side.white) {
        return WdlPerspective.playerIsWhite;
      }
      if (protagonistFixedSide == Side.black) {
        return WdlPerspective.playerIsBlack;
      }
    }
    return WdlPerspective.whiteBlack;
  }

  void _detectProtagonist(List<PgnGameEntry> entries) {
    sliceProtagonist = detectFileProtagonist(entries);
    protagonistFixedSide = null;
    final p = sliceProtagonist;
    if (p == null) return;
    var asWhite = 0, asBlack = 0;
    for (final g in entries) {
      if ((g.headers['White'] ?? '').split(',').first.trim() == p) asWhite++;
      if ((g.headers['Black'] ?? '').split(',').first.trim() == p) asBlack++;
    }
    if (asWhite > 0 && asBlack == 0) protagonistFixedSide = Side.white;
    if (asBlack > 0 && asWhite == 0) protagonistFixedSide = Side.black;
  }

  @override
  int currentGameIndex = 0;
  @override
  Position currentPosition = Chess.initial;
  @override
  bool boardFlipped = false;

  @override
  Perspective perspective = const Perspective();

  @override
  late final ViewerOpeningTree _viewerTree = ViewerOpeningTree(
    isActive: isActive,
    onChanged: notifyListeners,
    filteredGames: () => filteredGames,
    allGames: () => allGames,
    fenIndex: () => _fenIndex.value,
    mainLineIndex: () => pgnWidgetController.mainLineIndex,
    mainLineLength: () => pgnWidgetController.mainLineLength,
    currentFen: () => currentPosition.fen,
    applyPosition: (pos) => currentPosition = pos,
    onReclaimFocus: () => onReclaimFocus?.call(),
  );

  @override
  bool get showOpeningTree => _viewerTree.showOpeningTree;
  OpeningTree? get openingTree => _viewerTree.openingTree;
  bool get buildingTree => _viewerTree.buildingTree;
  int get treeBuildProcessed => _viewerTree.treeBuildProcessed;
  int get treeBuildTotal => _viewerTree.treeBuildTotal;
  List<String> get treeCurrentMoveSequence =>
      _viewerTree.treeCurrentMoveSequence;

  @override
  late final PgnFenIndex _fenIndex = PgnFenIndex(
    isActive: isActive,
    onChanged: _onFenIndexReady,
  );

  void _onFenIndexReady() {
    notifyListeners();
    _classifyOpenings();
  }

  /// Read-only access to the precomputed FEN → game-indices map.
  /// Returns null while the index is being built.
  @override
  Map<String, List<int>>? get fenIndex => _fenIndex.value;

  @override
  bool isLoading = false;

  /// Auto-play timer logic (extracted). The getters/methods below delegate
  /// here so existing call-sites keep their API.
  late final AutoPlayEngine _autoPlay = AutoPlayEngine(
    isActive: isActive,
    currentFen: () => pgnWidgetController.currentFen,
    goForward: pgnWidgetController.goForward,
    hasNextGame: () => currentGameIndex < filteredGames.length - 1,
    nextGame: nextGame,
    onChanged: notifyListeners,
    schedulePostFrame: schedulePostFrame,
  );

  bool get isAutoPlaying => _autoPlay.isPlaying;
  bool get autoNextGame => _autoPlay.autoNextGame;
  double get autoPlayDelaySec => _autoPlay.delaySec;

  GameSortMode sortMode = GameSortMode.fileOrder;

  List<String> recentFiles = [];
  static const recentFilesKey = 'pgn_viewer_recent_files';
  static const maxRecentFiles = 10;

  String? collectionsDir;

  String? errorMessage;

  int get currentPly => pgnWidgetController.mainLineIndex;

  @override
  void dispose() {
    _autoPlay.dispose();
    solitaire.removeListener(_onSolitaireChanged);
    solitaire.dispose();
    persistDebounce?.cancel();
    super.dispose();
  }

  Future<void> loadRecentFiles() async {
    final prefs = await SharedPreferences.getInstance();
    final files = prefs.getStringList(recentFilesKey) ?? [];
    final existing = <String>[];
    final storage = StorageFactory.instance;
    for (final f in files) {
      if (await storage.fileExists(f)) existing.add(f);
    }
    if (!isActive()) return;
    recentFiles = existing;
    notifyListeners();
  }

  Future<void> loadCollections() async {
    final dir = await DefaultPgnService.collectionsPath;
    if (!isActive()) return;
    collectionsDir = dir;
    notifyListeners();
  }

  Future<void> addToRecentFiles(String path) async {
    recentFiles.remove(path);
    recentFiles.insert(0, path);
    if (recentFiles.length > maxRecentFiles) {
      recentFiles = recentFiles.sublist(0, maxRecentFiles);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(recentFilesKey, recentFiles);
  }

  String? pickFileInitialDirectory() {
    final storage = StorageFactory.instance;
    if (filePath != null) {
      return storage.parentPath(filePath!);
    }
    if (recentFiles.isNotEmpty) {
      return storage.parentPath(recentFiles.first);
    }
    return collectionsDir;
  }

  Future<void> loadFile(String path) async {
    errorMessage = null;
    pendingSliceRestore = null;
    _sliceEpoch++;
    final storage = StorageFactory.instance;
    final fileName = p.basename(path);

    if (!await storage.fileExists(path)) {
      errorMessage = 'File not found: $fileName';
      // The epoch bump above told any in-flight slice op that this load owns
      // isLoading now, so release it even though this path never set it.
      isLoading = false;
      debugPrint('PgnViewerController.loadFile: file does not exist: $path');
      notifyListeners();
      return;
    }

    isLoading = true;
    notifyListeners();

    final content = await storage.readFile(path);
    if (!isActive()) return;

    if (content == null) {
      isLoading = false;
      errorMessage = 'Could not read $fileName';
      debugPrint('PgnViewerController.loadFile: read failed: $path');
      notifyListeners();
      return;
    }

    if (content.trim().isEmpty) {
      isLoading = false;
      errorMessage = 'File is empty: $fileName';
      debugPrint('PgnViewerController.loadFile: empty file: $path');
      notifyListeners();
      return;
    }

    final entries = await compute(parseMultiGamePgn, content);
    if (!isActive()) return;

    if (entries.isEmpty) {
      isLoading = false;
      errorMessage = 'No valid PGN games in $fileName';
      debugPrint('PgnViewerController.loadFile: no games parsed: $path');
      notifyListeners();
      return;
    }

    final perspectiveRaw = entries.isNotEmpty
        ? (entries.first.headers['StudyPerspective'] ?? '')
        : '';
    var newPerspective = Perspective.fromHeaderValue(perspectiveRaw);

    if (perspectiveRaw.trim().isEmpty && entries.length >= 2) {
      final protagonist = detectProtagonistFrom(entries);
      if (protagonist != null) {
        newPerspective = Perspective(
          mode: PerspectiveMode.player,
          playerName: protagonist,
        );
      }
    }

    isLoading = false;
    filePath = path;
    allGames = entries;
    _sliceEpoch++;
    _detectProtagonist(entries);
    filteredGames = List.of(entries);
    hasActiveFilters = false;
    activeSliceConfig = const SliceConfig.empty();
    _activeSliceIndices = null;
    sortMode = GameSortMode.fileOrder;
    currentGameIndex = 0;
    perspective = newPerspective;
    _viewerTree.resetForNewFile();
    notifyListeners();

    await addToRecentFiles(path);
    _fenIndex.reset();
    await _fenIndex.tryLoadPersisted(path, entries.length);
    await tryRestoreSavedSlice(path, entries);
    await loadCurrentGame();
    if (_fenIndex.value == null) {
      _buildFenIndex(); // classification runs via _onFenIndexReady
    } else {
      _classifyOpenings();
    }
  }

  /// Load PGN games directly from raw text (e.g. pasted from the clipboard).
  /// Held in memory only — there is no backing file, so rating/comment edits
  /// are not persisted to disk.
  Future<void> loadPgnContent(String content) async {
    errorMessage = null;
    pendingSliceRestore = null;
    _sliceEpoch++;
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      errorMessage = 'Clipboard is empty — copy some PGN first';
      // The epoch bump above told any in-flight slice op that this load owns
      // isLoading now, so release it even though this path never set it.
      isLoading = false;
      notifyListeners();
      return;
    }

    isLoading = true;
    notifyListeners();

    final entries = await compute(parseMultiGamePgn, trimmed);
    if (!isActive()) return;

    if (entries.isEmpty) {
      isLoading = false;
      errorMessage = 'No valid PGN games found in the pasted text';
      notifyListeners();
      return;
    }

    final perspectiveRaw = entries.first.headers['StudyPerspective'] ?? '';
    var newPerspective = Perspective.fromHeaderValue(perspectiveRaw);
    if (perspectiveRaw.trim().isEmpty && entries.length >= 2) {
      final protagonist = detectProtagonistFrom(entries);
      if (protagonist != null) {
        newPerspective = Perspective(
          mode: PerspectiveMode.player,
          playerName: protagonist,
        );
      }
    }

    isLoading = false;
    filePath = null;
    allGames = entries;
    _sliceEpoch++;
    _fenIndex.reset();
    _detectProtagonist(entries);
    filteredGames = List.of(entries);
    hasActiveFilters = false;
    activeSliceConfig = const SliceConfig.empty();
    _activeSliceIndices = null;
    sortMode = GameSortMode.fileOrder;
    currentGameIndex = 0;
    perspective = newPerspective;
    _viewerTree.resetForNewFile();
    notifyListeners();

    await loadCurrentGame();
    _buildFenIndex();
  }

  void _buildFenIndex() {
    final gameData = allGames
        .map(
          (g) => (
            headers: Map<String, String>.from(g.headers),
            pgnText: g.pgnText,
          ),
        )
        .toList();
    _fenIndex.build(gameData, filePath: filePath, gameTotal: allGames.length);
  }

  /// Attach ECO / Opening headers (in-memory only) from the bundled lichess
  /// opening book, so the slice header filters can match opening names.
  /// Position-based via the FEN index, so transpositions are classified too.
  Future<void> _classifyOpenings() async {
    final index = _fenIndex.value;
    if (index == null || allGames.isEmpty) return;
    final games = allGames;

    final book = await OpeningBookService.instance.load();
    // A new file may have loaded while the book was loading.
    if (!isActive() || !identical(_fenIndex.value, index)) return;

    final openings = classifyGamesFromIndex(book, index, games.length);
    var changed = false;
    for (var i = 0; i < games.length; i++) {
      final entry = openings[i];
      if (entry == null) continue;
      final headers = games[i].headers;
      if (headers['Opening'] != entry.name) {
        headers['Opening'] = entry.name;
        changed = true;
      }
      // Keep an existing ECO header: the source file's code is authoritative.
      if ((headers['ECO'] ?? '').isEmpty) {
        headers['ECO'] = entry.eco;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  String? detectProtagonist() => detectProtagonistFrom(allGames);

  /// Returns both player names when all games are between the same two players.
  ({String player1, String player2})? detectBothPlayers() =>
      detectBothPlayersFrom(allGames);

  @override
  Future<void> loadCurrentGame() async {
    if (filteredGames.isEmpty) return;
    stopAutoPlay();
    analysisController.cancel();
    currentPosition = Chess.initial;
    orientBoardForCurrentGame();
    final game = filteredGames[currentGameIndex];
    await analysisController.tryLoadFromPgn(game.pgnText);
    if (!isActive()) return;
    if (isSolitaireMode) {
      schedulePostFrame?.call(() {
        pgnWidgetController.goToMainLineIndex(0);
        solitaire.onGameChanged(
          mainLineLength: pgnWidgetController.mainLineLength,
          userPlaysWhite: !boardFlipped,
          whiteToMoveAtStart: currentPosition.turn == Side.white,
        );
      });
    }
    notifyListeners();
    onReclaimFocus?.call();
  }

  void nextGame() {
    if (filteredGames.isEmpty) return;
    currentGameIndex = (currentGameIndex + 1).clamp(
      0,
      filteredGames.length - 1,
    );
    notifyListeners();
    loadCurrentGame();
  }

  void prevGame() {
    if (filteredGames.isEmpty) return;
    currentGameIndex = (currentGameIndex - 1).clamp(
      0,
      filteredGames.length - 1,
    );
    notifyListeners();
    loadCurrentGame();
  }

  void goToGame(int index) {
    if (index < 0 || index >= filteredGames.length) return;
    currentGameIndex = index;
    notifyListeners();
    loadCurrentGame();
  }

  void toggleAutoPlay() {
    if (isSolitaireMode) return;
    _autoPlay.toggle();
    onReclaimFocus?.call();
  }

  void startAutoPlay() => _autoPlay.start();

  @override
  void stopAutoPlay() => _autoPlay.stop();

  void setAutoPlaySpeed(double val) => _autoPlay.setSpeed(val);

  void setAutoNextGame(bool value) => _autoPlay.setAutoNextGame(value);

  /// One-click slice presets derived from [sliceProtagonist].
  List<({String label, HeaderFilterConfig filter})> get slicePresets {
    final p = sliceProtagonist;
    if (p == null) return const [];
    return [
      (
        label: '$p as White',
        filter: HeaderFilterConfig(
          field: 'White',
          mode: MatchMode.contains,
          value: p,
        ),
      ),
      (
        label: '$p as Black',
        filter: HeaderFilterConfig(
          field: 'Black',
          mode: MatchMode.contains,
          value: p,
        ),
      ),
    ];
  }

  void setSortMode(GameSortMode mode) {
    sortMode = mode;
    notifyListeners();
    applySortMode();
    currentGameIndex = 0;
    notifyListeners();
    loadCurrentGame();
  }

  @override
  void applySortMode() {
    _viewerTree.clearCache();
    switch (sortMode) {
      case GameSortMode.fileOrder:
        if (hasActiveFilters) {
          final filteredSet = filteredGames.toSet();
          filteredGames = allGames
              .where((g) => filteredSet.contains(g))
              .toList();
        } else {
          filteredGames = List.of(allGames);
        }
      case GameSortMode.ratingDesc:
        filteredGames.sort((a, b) {
          final aSort = a.studyRating == 0 ? 3 : a.studyRating;
          final bSort = b.studyRating == 0 ? 3 : b.studyRating;
          return bSort.compareTo(aSort);
        });
      case GameSortMode.ratingAsc:
        filteredGames.sort((a, b) {
          final aSort = a.studyRating == 0 ? 3 : a.studyRating;
          final bSort = b.studyRating == 0 ? 3 : b.studyRating;
          return aSort.compareTo(bSort);
        });
    }
  }

  void onPositionChanged(Position pos) {
    currentPosition = pos;
    notifyListeners();
  }

  void toggleOpeningTree() {
    if (isSolitaireMode) solitaire.stop();
    _viewerTree.toggle();
  }

  Future<void> rebuildOpeningTree() => _viewerTree.rebuild();

  void onTreeMoveSelected(String move) => _viewerTree.onMoveSelected(move);

  void onTreeGoBack() => _viewerTree.goBack();

  void onTreeGoForward() => _viewerTree.goForward();

  // ── Unified navigation (mode-aware) ──

  // Solitaire allows browsing the revealed region: the PGN widget caps all
  // mainline navigation at the revealed frontier, so back/forward/home/end
  // can delegate to it directly. clearEphemeralMoves is skipped there — it
  // would wipe the wrong-attempt variations recorded during play.

  void navigateBack() {
    stopAutoPlay();
    if (isSolitaireMode) {
      pgnWidgetController.goBack();
    } else if (showOpeningTree) {
      _viewerTree.goBack();
    } else {
      pgnWidgetController.goBack();
    }
  }

  void navigateForward() {
    stopAutoPlay();
    if (isSolitaireMode) {
      pgnWidgetController.goForward();
    } else if (showOpeningTree) {
      _viewerTree.goForward();
    } else {
      pgnWidgetController.goForward();
    }
  }

  void navigateToStart() {
    stopAutoPlay();
    if (isSolitaireMode) {
      pgnWidgetController.goToMainLineIndex(0);
    } else if (showOpeningTree) {
      _viewerTree.resetToStart();
    } else {
      pgnWidgetController.clearEphemeralMoves();
      pgnWidgetController.jumpToMove(1, true);
    }
  }

  void navigateToEnd() {
    stopAutoPlay();
    if (isSolitaireMode) {
      // Back to the guessing frontier (the widget caps at revealedPly).
      pgnWidgetController.goToMainLineIndex(solitaire.revealedPly);
    } else if (showOpeningTree) {
      _viewerTree.goToEnd();
    } else {
      final len = pgnWidgetController.mainLineLength;
      if (len > 0) {
        final moveNum = (len + 1) ~/ 2;
        final isWhite = len % 2 == 1;
        pgnWidgetController.jumpToMove(moveNum, isWhite);
      }
    }
  }

  /// Handle a board move in the current mode context.
  void onBoardMove(String san) {
    if (showOpeningTree) {
      _viewerTree.onMoveSelected(san);
    } else if (isSolitaireMode) {
      _handleSolitaireMove(san);
    } else {
      stopAutoPlay();
      pgnWidgetController.addEphemeralMove(san);
    }
  }

  List<int> gamesAtTreePosition() => _viewerTree.gamesAtTreePosition();

  void loadGameFromTree(int filteredIndex) {
    _viewerTree.snapshotCursor();
    _viewerTree.hide();
    currentGameIndex = filteredIndex;
    notifyListeners();
    loadCurrentGame();
  }

  /// True when a tree position saved by [loadGameFromTree] can be returned to.
  bool get hasTreeReturnPosition => _viewerTree.hasSavedPosition;

  /// Re-open the opening tree at the position explored before the last
  /// [loadGameFromTree], restoring the tree cursor and the board.
  Future<void> returnToTreePosition() => _viewerTree.restoreSavedPosition();

  String? defaultExportFileName() {
    if (filePath == null) return null;
    return '${p.basenameWithoutExtension(filePath!)}_slice.pgn';
  }

  @override
  String buildExportContent() {
    return '${filteredGames.map((g) => g.pgnText).join('\n\n')}\n';
  }

  void onEngineLineMoveTapped(List<String> sanMoves, int clickedIndex) {
    if (sanMoves.isEmpty || clickedIndex < 0) return;
    stopAutoPlay();

    for (final san in sanMoves) {
      pgnWidgetController.addEphemeralMove(san);
    }

    final stepsBack = sanMoves.length - 1 - clickedIndex;
    for (int i = 0; i < stepsBack; i++) {
      pgnWidgetController.goBack();
    }

    notifyListeners();
    onReclaimFocus?.call();
  }
}
