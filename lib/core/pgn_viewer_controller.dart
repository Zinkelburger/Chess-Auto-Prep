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
import 'pgn/viewer_opening_tree.dart';
import 'pgn/viewer_solitaire_session.dart';
import '../models/opening_tree.dart';
import '../models/pgn_filter_models.dart';
import '../models/pgn_game_entry.dart';
export '../models/pgn_game_entry.dart';
import '../services/default_pgn_service.dart';
import '../services/pgn_document_patch.dart';
import '../services/game_analysis_controller.dart';
import '../services/opening_book_service.dart';
import '../services/storage/storage_factory.dart';
import 'pgn/pgn_viewer_handle.dart';
import 'pgn/solitaire_controller.dart';
export 'pgn/solitaire_controller.dart'
    show SolitaireController, SolitaireGuess, SolitaireStep;
export 'pgn/viewer_solitaire_session.dart' show SolitaireSetup;
import '../utils/pgn_date_utils.dart';
import '../utils/safe_change_notifier.dart';
import '../utils/chess_utils.dart';

part 'pgn/pgn_viewer_controller_metadata.dart';
part 'pgn/pgn_viewer_controller_slices.dart';
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
/// ([_MetadataOps]) and window/perspective
/// handling ([_WindowOps]).
class PgnViewerController extends ChangeNotifier
    with SafeChangeNotifier, _SliceOps, _MetadataOps, _WindowOps {
  PgnViewerController({
    required this.pgnWidgetController,
    required this.analysisController,
    this.isActive = _alwaysActive,
    this.schedulePostFrame,
    this.onReclaimFocus,
  });

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

  /// Modification time of [filePath] as it was when this collection was read,
  /// or null for a collection with no backing file.
  ///
  /// Held so a caller can ask whether the loaded copy is still the file: the
  /// games cache is written behind this controller's back — the review of your
  /// recent games patches every game it analyses with the scores it found —
  /// and a screen that reuses an already-loaded collection would otherwise
  /// show the pre-patch text, graph and all missing.
  @override
  DateTime? loadedFileModified;
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
  Position currentPosition = Chess.initial;

  /// Last mainline ply visited in each game of the open collection. Entries
  /// are the game objects themselves, so sorting and filtering preserve the
  /// bookmark without inventing an unstable header-based identifier.
  final Map<PgnGameEntry, int> _resumePlyByGame = {};

  @override
  void _rememberCurrentPlace() {
    if (currentGameIndex < 0 || currentGameIndex >= filteredGames.length) {
      return;
    }
    _resumePlyByGame[filteredGames[currentGameIndex]] =
        pgnWidgetController.mainLineIndex;
  }

  int resumePlyFor(PgnGameEntry game) => _resumePlyByGame[game] ?? 0;

  /// Separate generations for whole-collection IO and the selected game's
  /// cached analysis. A slice epoch cannot protect these: file reads and game
  /// parses may overlap without any slice operation at all.
  int _loadEpoch = 0;
  int _gameLoadEpoch = 0;

  bool _isCurrentLoad(int epoch) => isActive() && epoch == _loadEpoch;

  /// FEN the next [PgnViewerWidget] mount should park on (tree position after
  /// a games-at-position click, or the game cursor after leaving the tree).
  @override
  String? pgnInitialFen;

  /// Game FEN snapshotted when entering the opening tree, restored when
  /// leaving via T so the remounted game widget is not at move 1.
  String? _gameCursorFen;

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

  /// Solitaire ("guess the move") mode. The session owns the guessing rules
  /// and the board glue; the delegating members below keep the controller's
  /// public API unchanged for the screens.
  late final ViewerSolitaireSession _solitaireSession = ViewerSolitaireSession(
    handle: pgnWidgetController,
    hasGames: () => filteredGames.isNotEmpty,
    userPlaysWhite: () => !boardFlipped,
    stopAutoPlay: stopAutoPlay,
    onChanged: notifyListeners,
  );

  SolitaireController get solitaire => _solitaireSession.controller;
  bool get isSolitaireMode => _solitaireSession.isActive;

  /// The setup strip is open: side, start point and sidelines are being
  /// chosen, but no session is running yet.
  bool get isSolitaireSetup => _solitaireSession.isConfiguring;
  SolitaireSetup? get solitaireSetup => _solitaireSession.setup;
  int get totalTrophyCount => _solitaireSession.totalTrophyCount;
  void noteTrophiesEarned(int count) =>
      _solitaireSession.noteTrophiesEarned(count);

  /// Toolbar button: open setup, or leave the setup / running session.
  void toggleSolitaire() => _solitaireSession.toggle();
  void updateSolitaireSetup({
    bool? userIsWhite,
    bool? fromCurrentMove,
    bool? includeVariations,
  }) => _solitaireSession.updateSetup(
    userIsWhite: userIsWhite,
    fromCurrentMove: fromCurrentMove,
    includeVariations: includeVariations,
  );
  void beginSolitaire() => _solitaireSession.begin();
  void cancelSolitaireSetup() => _solitaireSession.cancelSetup();
  void stopSolitaire() => _solitaireSession.stop();
  Future<void> loadSolitaireSettings() async {
    try {
      await _solitaireSession.loadSettings();
    } catch (e) {
      errorMessage = 'Could not load solitaire progress: $e';
      notifyListeners();
    }
  }

  Future<void> setSolitaireRevealDelay(int seconds) =>
      _solitaireSession.setRevealDelay(seconds);
  void revealCurrentMove() => _solitaireSession.revealCurrentMove();
  void hintCurrentMove() => _solitaireSession.hintCurrentMove();

  /// The PGN widget finished loading the game on screen. A running solitaire
  /// session starts over on it — this, not a post-frame guess, is when the
  /// new game's moves are actually there to build a script from.
  void onViewerGameLoaded() {
    if (isSolitaireMode) _solitaireSession.restartForNewGame();
  }

  @override
  late final PgnFenIndex _fenIndex = PgnFenIndex(
    isActive: isActive,
    onChanged: _onFenIndexReady,
  );

  void _onFenIndexReady() {
    unawaited(_classifyOpenings());
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
    _solitaireSession.dispose();
    // A comment typed in the last 300 ms and a stale FEN-index stamp both
    // still owe the file a write; the collection is going away, so now.
    unawaited(flushPendingMetadata());
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

  /// Adopt [entries] as the loaded collection.
  ///
  /// The one place collection-scoped state is set, so the two load paths and
  /// [closeFile] cannot drift apart. They used to keep three hand-written
  /// blocks of 15, 15 and 20 assignments that had to agree: adding a field
  /// meant remembering all three, and forgetting one left stale state behind
  /// a load. Now it is a single edit here.
  ///
  /// [newPerspective] is passed in because each caller derives it
  /// differently — from headers, from protagonist detection, or reset.
  void _adoptCollection({
    required String? path,
    required List<PgnGameEntry> entries,
    required Perspective newPerspective,
  }) {
    // Settle the outgoing collection's debts (a pending metadata write, a
    // stale FEN-index stamp) before its path and games are replaced; the
    // flush captures both synchronously.
    unawaited(flushPendingMetadata());
    filePath = path;
    // Whoever adopted a collection knows the mtime if there is one; a
    // from-memory collection has none. Cleared here so it can never outlive
    // the file it described.
    loadedFileModified = null;
    allGames = entries;
    adoptPersistedGames(entries);
    _detectProtagonist(entries);
    filteredGames = List.of(entries);
    hasActiveFilters = false;
    activeSliceConfig = const SliceConfig.empty();
    _activeSliceIndices = null;
    sortMode = GameSortMode.fileOrder;
    currentGameIndex = 0;
    _resumePlyByGame.clear();
    pgnInitialFen = null;
    _gameCursorFen = null;
    perspective = newPerspective;
    _viewerTree.resetForNewFile();
    clearScreenOnlyMovetext();
  }

  /// The perspective a freshly loaded collection should open in.
  ///
  /// An explicit `StudyPerspective` header wins. Failing that, a collection of
  /// two or more games that share one protagonist opens from that player's
  /// side — a single game is left alone, since "the protagonist" of one game
  /// is just whoever the reader is looking at.
  Perspective _perspectiveFor(List<PgnGameEntry> entries) {
    final raw = entries.isNotEmpty
        ? (entries.first.headers['StudyPerspective'] ?? '')
        : '';
    final fromHeader = Perspective.fromHeaderValue(raw);
    if (raw.trim().isNotEmpty || entries.length < 2) return fromHeader;
    final protagonist = detectProtagonistFrom(entries);
    if (protagonist == null) return fromHeader;
    return Perspective(mode: PerspectiveMode.player, playerName: protagonist);
  }

  /// [restoreSavedSlice] — reapply the slice persisted for this file. Off for
  /// single-game handoffs (Games page "Review"): a leftover slice there only
  /// hides the target game and confuses the count display.
  Future<void> loadFile(String path, {bool restoreSavedSlice = true}) async {
    final loadEpoch = ++_loadEpoch;
    // A collection request also makes any cached-analysis parse for the old
    // selected game stale immediately, before the new file finishes reading.
    _gameLoadEpoch++;
    errorMessage = null;
    pendingSliceRestore = null;
    _sliceEpoch++;
    final storage = StorageFactory.instance;
    final fileName = p.basename(path);

    try {
      final exists = await storage.fileExists(path);
      if (!_isCurrentLoad(loadEpoch)) return;
      if (!exists) {
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
      if (!_isCurrentLoad(loadEpoch)) return;

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
      if (!_isCurrentLoad(loadEpoch)) return;

      if (entries.isEmpty) {
        isLoading = false;
        errorMessage = 'No valid PGN games in $fileName';
        debugPrint('PgnViewerController.loadFile: no games parsed: $path');
        notifyListeners();
        return;
      }

      final modified = await storage.fileStat(path);
      if (!_isCurrentLoad(loadEpoch)) return;

      isLoading = false;
      _sliceEpoch++;
      _adoptCollection(
        path: path,
        entries: entries,
        newPerspective: _perspectiveFor(entries),
      );
      loadedFileModified = modified?.modified;
      notifyListeners();

      await addToRecentFiles(path);
      if (!_isCurrentLoad(loadEpoch)) return;
      _fenIndex.reset();
      await _fenIndex.tryLoadPersisted(path, entries.length);
      if (!_isCurrentLoad(loadEpoch)) return;
      if (restoreSavedSlice) await tryRestoreSavedSlice(path, entries);
      if (!_isCurrentLoad(loadEpoch)) return;
      await loadCurrentGame();
      if (!_isCurrentLoad(loadEpoch)) return;
      if (_fenIndex.value == null) {
        _buildFenIndex(); // classification runs via _onFenIndexReady
      } else {
        unawaited(_classifyOpenings());
      }
    } catch (e) {
      if (!_isCurrentLoad(loadEpoch)) return;
      isLoading = false;
      errorMessage = 'Could not open $fileName: $e';
      notifyListeners();
    }
  }

  /// Load PGN games directly from raw text (e.g. pasted from the clipboard).
  /// Held in memory only — there is no backing file, so rating/comment edits
  /// are not persisted to disk.
  ///
  /// [initialFen] parks the first game on that position instead of its start.
  /// It has to be handed in here rather than set afterwards: the viewer widget
  /// reads it during the build this load triggers, which is the only moment
  /// the freshly parsed game and the cursor request meet.
  Future<void> loadPgnContent(String content, {String? initialFen}) async {
    final loadEpoch = ++_loadEpoch;
    _gameLoadEpoch++;
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
    if (!_isCurrentLoad(loadEpoch)) return;

    if (entries.isEmpty) {
      isLoading = false;
      errorMessage = 'No valid PGN games found in the pasted text';
      notifyListeners();
      return;
    }

    isLoading = false;
    _sliceEpoch++;
    _fenIndex.reset();
    _adoptCollection(
      path: null,
      entries: entries,
      newPerspective: _perspectiveFor(entries),
    );
    pgnInitialFen = initialFen;
    notifyListeners();

    await loadCurrentGame();
    if (!_isCurrentLoad(loadEpoch)) return;
    _buildFenIndex();
  }

  /// Close the loaded collection and put the viewer back on its start screen
  /// ("No PGN loaded" — browse button plus the recent list).
  ///
  /// Two things are deliberately *not* cleared: the recent-files list (it is
  /// the way back in) and the slice persisted on disk for this file, so
  /// reopening it still restores what you were looking at.
  void closeFile() {
    // Bumped first: an in-flight load or slice recompute would otherwise land
    // its results — and its isLoading release — on the cleared state.
    _loadEpoch++;
    _gameLoadEpoch++;
    _sliceEpoch++;
    stopAutoPlay();
    if (isSolitaireMode) _solitaireSession.stop();
    _solitaireSession.cancelSetup();
    analysisController.cancel();
    analysisController.clearEvals();
    isLoading = false;
    errorMessage = null;
    pendingSliceRestore = null;
    // An empty collection: _adoptCollection nulls the protagonist fields the
    // same way this used to by hand.
    _adoptCollection(
      // Mutable, not `const []`: [allGames] is assigned as given, and sorting
      // reorders these lists in place.
      path: null,
      entries: <PgnGameEntry>[],
      newPerspective: const Perspective(),
    );
    currentPosition = Chess.initial;
    boardFlipped = false;
    _fenIndex.reset();
    notifyListeners();
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
    unawaited(
      _fenIndex.build(gameData, filePath: filePath, gameTotal: allGames.length),
    );
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
    final gameLoadEpoch = ++_gameLoadEpoch;
    stopAutoPlay();
    analysisController.cancel();
    currentPosition = _tryParseFen(pgnInitialFen) ?? Chess.initial;
    orientBoardForCurrentGame();
    final game = filteredGames[currentGameIndex];
    final restored = await analysisController.tryLoadFromPgn(game.pgnText);
    if (!isActive() || gameLoadEpoch != _gameLoadEpoch) return;
    notifyListeners();
    onReclaimFocus?.call();
    if (restored) unawaited(_fillMissingBestLines(game));
  }

  /// A stored graph whose mistakes carry no line gets them now: a few short
  /// searches, written back onto [game] so it happens once. The widget
  /// adopts the new comments in place, so the reader is not moved.
  Future<void> _fillMissingBestLines(PgnGameEntry game) async {
    await analysisController.fillMissingBestLines(
      game.pgnText,
      onAnnotatedMovetext: (movetext) {
        if (!isActive()) return;
        persistMoveCommentsFor(game, movetext);
        notifyListeners();
      },
    );
  }

  void nextGame() {
    if (filteredGames.isEmpty) return;
    _rememberCurrentPlace();
    pgnInitialFen = null;
    currentGameIndex = (currentGameIndex + 1).clamp(
      0,
      filteredGames.length - 1,
    );
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  void prevGame() {
    if (filteredGames.isEmpty) return;
    _rememberCurrentPlace();
    pgnInitialFen = null;
    currentGameIndex = (currentGameIndex - 1).clamp(
      0,
      filteredGames.length - 1,
    );
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  void goToGame(int index) {
    if (index < 0 || index >= filteredGames.length) return;
    _rememberCurrentPlace();
    pgnInitialFen = null;
    currentGameIndex = index;
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  void toggleAutoPlay() {
    if (isSolitaireMode) return;
    _autoPlay.toggle();
    onReclaimFocus?.call();
  }

  void startAutoPlay() => _autoPlay.start();

  void stopAutoPlay() => _autoPlay.stop();

  void setAutoPlaySpeed(double val) => _autoPlay.setSpeed(val);

  void setAutoNextGame(bool value) => _autoPlay.setAutoNextGame(value);

  /// One-click slice presets derived from [sliceProtagonist].
  ///
  /// [shortLabel] is for the app bar, where two chips repeating a long
  /// username push each other off the edge of a bar that only scrolls if you
  /// know it does; the full [label] stays in the slice dialog and in the
  /// chip's tooltip.
  List<({String label, String shortLabel, HeaderFilterConfig filter})>
  get slicePresets {
    final p = sliceProtagonist;
    if (p == null) return const [];
    return [
      (
        label: '$p as White',
        shortLabel: 'as White',
        filter: HeaderFilterConfig(
          field: 'White',
          mode: MatchMode.contains,
          value: p,
        ),
      ),
      (
        label: '$p as Black',
        shortLabel: 'as Black',
        filter: HeaderFilterConfig(
          field: 'Black',
          mode: MatchMode.contains,
          value: p,
        ),
      ),
    ];
  }

  void setSortMode(GameSortMode mode) {
    _rememberCurrentPlace();
    sortMode = mode;
    notifyListeners();
    applySortMode();
    currentGameIndex = 0;
    pgnInitialFen = null;
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  /// Reorder newest-first *without* moving the cursor — for arrivals that are
  /// about to select a game by identity ([GameSortMode.dateDesc]). Unlike
  /// [setSortMode] this keeps no game loaded, because the caller is about to
  /// pick one and loading the wrong one first is a wasted parse and a visible
  /// flash of someone else's game.
  void sortNewestFirst() {
    if (sortMode == GameSortMode.dateDesc) return;
    sortMode = GameSortMode.dateDesc;
    applySortMode();
    notifyListeners();
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
      case GameSortMode.dateDesc:
        // Undated games sort last rather than clumping at the top: an empty
        // key would otherwise beat every real date under a plain compare.
        filteredGames.sort((a, b) {
          final ka = pgnHeaderSortKey(a.headers);
          final kb = pgnHeaderSortKey(b.headers);
          if (ka.isEmpty || kb.isEmpty) {
            if (ka.isEmpty && kb.isEmpty) return 0;
            return ka.isEmpty ? 1 : -1;
          }
          return kb.compareTo(ka);
        });
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
    if (isSolitaireMode) _solitaireSession.stop();
    _solitaireSession.cancelSetup();
    if (showOpeningTree) {
      _viewerTree.toggle();
      pgnInitialFen = _gameCursorFen;
      final restored = _tryParseFen(_gameCursorFen);
      if (restored != null) currentPosition = restored;
      notifyListeners();
      return;
    }
    _gameCursorFen = currentPosition.fen;
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

  /// Park the cursor on a mainline position by half-move index. Out-of-range
  /// values clamp to the game, so a moment computed from a longer copy of the
  /// game still lands somewhere in it.
  void goToPly(int ply) {
    stopAutoPlay();
    if (isSolitaireMode || showOpeningTree) return;
    final len = pgnWidgetController.mainLineLength;
    pgnWidgetController.clearEphemeralMoves();
    pgnWidgetController.goToMainLineIndex(ply.clamp(0, len < 0 ? 0 : len));
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
      _solitaireSession.handleBoardMove(san);
    } else {
      stopAutoPlay();
      pgnWidgetController.addEphemeralMove(san);
    }
  }

  List<int> gamesAtTreePosition() => _viewerTree.gamesAtTreePosition();

  void loadGameFromTree(int filteredIndex) {
    _rememberCurrentPlace();
    _viewerTree.snapshotCursor(leavingForGame: true);
    final landingFen = openingTree?.currentNode.fen;
    pgnInitialFen = landingFen;
    _gameCursorFen = landingFen;
    _viewerTree.hide();
    currentGameIndex = filteredIndex;
    currentPosition = _tryParseFen(landingFen) ?? Chess.initial;
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  /// True when a tree position saved by [loadGameFromTree] can be returned to.
  bool get hasTreeReturnPosition => _viewerTree.hasSavedPosition;

  /// Re-open the opening tree at the position explored before the last
  /// [loadGameFromTree], restoring the tree cursor and the board.
  Future<void> returnToTreePosition() {
    _gameCursorFen = currentPosition.fen;
    return _viewerTree.restoreSavedPosition();
  }

  Position? _tryParseFen(String? fen) {
    if (fen == null || fen.isEmpty) return null;
    return tryParseFen(fen);
  }

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
