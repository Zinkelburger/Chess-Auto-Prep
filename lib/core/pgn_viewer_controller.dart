import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'pgn/auto_play_engine.dart';
import 'pgn/pgn_fen_index.dart';
import 'pgn/slice_persistence.dart';
import 'pgn/solitaire_controller.dart';
import 'pgn/viewer_opening_tree.dart';
import '../models/opening_tree.dart';
import '../models/pgn_filter_models.dart';
import '../models/pgn_game_entry.dart';
export '../models/pgn_game_entry.dart';
import '../models/solitaire_trophy.dart';
import '../services/default_pgn_service.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/game_analysis_controller.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/solitaire_trophy_service.dart';
import '../services/storage/storage_factory.dart';
import '../widgets/pgn_viewer_widget.dart';

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

/// Set when a saved slice is restored so the UI can show a snackbar.
class SliceRestoreInfo {
  final int filteredCount;
  final int totalCount;

  const SliceRestoreInfo({
    required this.filteredCount,
    required this.totalCount,
  });
}

// ---------------------------------------------------------------------------
// Top-level helpers used inside Isolate.run closures.
// Must NOT be class statics — Dart captures the enclosing class context
// when referencing static members from a closure, which pulls unsendable
// State/Widget objects into the isolate message.
// ---------------------------------------------------------------------------

List<PgnGameEntry> parseMultiGamePgn(String content) {
  final entries = <PgnGameEntry>[];
  final chunks = content.split(pgn.pgnChunkSplitRe);
  for (final chunk in chunks) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
    final headers = pgn.extractHeaders(trimmed);
    final rating = int.tryParse(headers['StudyRating'] ?? '') ?? 0;
    entries.add(PgnGameEntry(
      headers: headers,
      pgnText: trimmed,
      studyRating: rating.clamp(0, 5),
      studySummary: headers['StudySummary'] ?? '',
    ));
  }
  return entries;
}

Future<List<int>> applySliceConfig(
  SliceConfig config,
  List<GameRecord> games, {
  Map<String, List<int>>? fenIndex,
}) {
  final seqPattern = config.sequencePattern;
  return pgn.computeSliceMatches(
    games: games,
    targetFen: pgn.parseTargetFen(config.positionInput),
    filters: config.headerFilters
        .map((f) => (field: f.field, mode: f.mode, value: f.value))
        .toList(),
    seqGroups: (seqPattern != null && seqPattern.isNotEmpty)
        ? pgn.parseSequenceGroups(seqPattern)
        : const [],
    seqGap: config.sequenceGap,
    fenIndex: fenIndex,
  );
}

final studyRatingRe = RegExp(r'\[StudyRating\s+"[^"]*"\]');
final studyRatingLineRe = RegExp(r'\[StudyRating\s+"[^"]*"\]\n?');
final studySummaryRe = RegExp(r'\[StudySummary\s+"[^"]*"\]');
final studySummaryLineRe = RegExp(r'\[StudySummary\s+"[^"]*"\]\n?');

List<String> buildMetadataOutput(
    List<({String pgn, int rating, String summary})> gameData) {
  final results = <String>[];
  for (final game in gameData) {
    var pgn = game.pgn;

    if (game.rating > 0) {
      if (studyRatingRe.hasMatch(pgn)) {
        pgn = pgn.replaceFirst(studyRatingRe, '[StudyRating "${game.rating}"]');
      } else {
        final firstNewline = pgn.indexOf('\n');
        if (firstNewline != -1) {
          pgn =
              '${pgn.substring(0, firstNewline)}\n[StudyRating "${game.rating}"]${pgn.substring(firstNewline)}';
        }
      }
    } else {
      pgn = pgn.replaceFirst(studyRatingLineRe, '');
    }

    if (game.summary.isNotEmpty) {
      final escaped = game.summary.replaceAll('"', "'");
      if (studySummaryRe.hasMatch(pgn)) {
        pgn = pgn.replaceFirst(studySummaryRe, '[StudySummary "$escaped"]');
      } else {
        final firstNewline = pgn.indexOf('\n');
        if (firstNewline != -1) {
          pgn =
              '${pgn.substring(0, firstNewline)}\n[StudySummary "$escaped"]${pgn.substring(firstNewline)}';
        }
      }
    } else {
      pgn = pgn.replaceFirst(studySummaryLineRe, '');
    }

    results.add(pgn);
  }
  return results;
}

String? detectProtagonistFrom(List<PgnGameEntry> games) {
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

/// Returns both player names when every game in the sample is between the
/// same two players (order: most-frequent-as-White first). Returns null if
/// only one (or no) recurring player is found.
({String player1, String player2})? detectBothPlayersFrom(
    List<PgnGameEntry> games) {
  if (games.length < 2) return null;
  final sample = games.take(math.min(6, games.length)).toList();
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
  final recurring = counts.entries
      .where((e) => e.value >= sampleSize)
      .map((e) => e.key)
      .toList();
  if (recurring.length < 2) return null;
  // Return with the player who appears as White more often listed first.
  int whiteCount(String name) =>
      sample.where((g) => g.headers['White'] == name).length;
  recurring.sort((a, b) => whiteCount(b).compareTo(whiteCount(a)));
  return (player1: recurring[0], player2: recurring[1]);
}

/// Business logic and state for the PGN Viewer screen.
class PgnViewerController extends ChangeNotifier {
  PgnViewerController({
    required this.pgnWidgetController,
    required this.analysisController,
    this.isActive = _alwaysActive,
    this.schedulePostFrame,
    this.onReclaimFocus,
  });

  final PgnViewerWidgetController pgnWidgetController;
  final GameAnalysisController analysisController;
  final bool Function() isActive;
  final void Function(void Function() callback)? schedulePostFrame;
  final VoidCallback? onReclaimFocus;

  static bool _alwaysActive() => true;

  // File state
  String? filePath;
  List<PgnGameEntry> allGames = [];
  List<PgnGameEntry> filteredGames = [];
  bool hasActiveFilters = false;

  SliceConfig activeSliceConfig = const SliceConfig.empty();
  List<int>? _activeSliceIndices;

  int currentGameIndex = 0;
  Position currentPosition = Chess.initial;
  bool boardFlipped = false;

  Perspective perspective = const Perspective();

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

  bool get showOpeningTree => _viewerTree.showOpeningTree;
  OpeningTree? get openingTree => _viewerTree.openingTree;
  bool get buildingTree => _viewerTree.buildingTree;
  int get treeBuildProcessed => _viewerTree.treeBuildProcessed;
  int get treeBuildTotal => _viewerTree.treeBuildTotal;
  List<String> get treeCurrentMoveSequence => _viewerTree.treeCurrentMoveSequence;

  late final PgnFenIndex _fenIndex = PgnFenIndex(
    isActive: isActive,
    onChanged: notifyListeners,
  );

  /// Read-only access to the precomputed FEN → game-indices map.
  /// Returns null while the index is being built.
  Map<String, List<int>>? get fenIndex => _fenIndex.value;

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

  // -- Solitaire mode --
  final SolitaireController solitaire = SolitaireController();

  bool get isSolitaireMode => solitaire.active;

  static const _revealDelayKey = 'solitaire_reveal_delay_sec';
  static const _trophyThresholdKey = 'solitaire_trophy_threshold_cp';

  int trophyThresholdCp = 20;

  /// Trophies detected after the most recent analysis run (reset per game).
  List<SolitaireTrophy> lastDetectedTrophies = [];

  /// All-time trophy count (cached from service).
  int totalTrophyCount = 0;

  GameSortMode sortMode = GameSortMode.fileOrder;

  List<String> recentFiles = [];
  static const recentFilesKey = 'pgn_viewer_recent_files';
  static const maxRecentFiles = 10;

  String? collectionsDir;

  bool isFullScreen = false;

  Timer? persistDebounce;

  SliceRestoreInfo? pendingSliceRestore;

  String? errorMessage;

  int get currentPly => pgnWidgetController.mainLineIndex;

  void disposeController() {
    _autoPlay.dispose();
    solitaire.removeListener(_onSolitaireChanged);
    solitaire.dispose();
    persistDebounce?.cancel();
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
    final storage = StorageFactory.instance;
    final fileName = p.basename(path);

    if (!await storage.fileExists(path)) {
      errorMessage = 'File not found: $fileName';
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
    await _fenIndex.tryLoadPersisted(path, entries.length);
    await tryRestoreSavedSlice(path, entries);
    await loadCurrentGame();
    if (_fenIndex.value == null) _buildFenIndex();
  }

  /// Load PGN games directly from raw text (e.g. pasted from the clipboard).
  /// Held in memory only — there is no backing file, so rating/comment edits
  /// are not persisted to disk.
  Future<void> loadPgnContent(String content) async {
    errorMessage = null;
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      errorMessage = 'Clipboard is empty — copy some PGN first';
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
        .map((g) => (
              headers: Map<String, String>.from(g.headers),
              pgnText: g.pgnText,
            ))
        .toList();
    _fenIndex.build(gameData, filePath: filePath, gameTotal: allGames.length);
  }

  Future<void> tryRestoreSavedSlice(
      String path, List<PgnGameEntry> entries) async {
    final config = await SlicePersistence.load(path);
    if (config == null) return;

    final allRecords =
        entries.map((g) => (headers: g.headers, pgnText: g.pgnText)).toList();
    isLoading = true;
    notifyListeners();

    final indices =
        await applySliceConfig(config, allRecords, fenIndex: fenIndex);
    if (!isActive()) return;

    isLoading = false;
    if (indices.length == entries.length) {
      notifyListeners();
      return;
    }

    filteredGames = indices.map((i) => allGames[i]).toList();
    hasActiveFilters = true;
    activeSliceConfig = config;
    _activeSliceIndices = List<int>.from(indices);
    currentGameIndex = 0;
    pendingSliceRestore = SliceRestoreInfo(
      filteredCount: filteredGames.length,
      totalCount: allGames.length,
    );
    notifyListeners();
  }

  void clearPendingSliceRestore() => pendingSliceRestore = null;

  void orientBoardForCurrentGame() {
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    final w = (game.headers['White'] ?? '').toLowerCase().trim();
    final b = (game.headers['Black'] ?? '').toLowerCase().trim();

    switch (perspective.mode) {
      case PerspectiveMode.white:
        boardFlipped = false;
      case PerspectiveMode.black:
        boardFlipped = true;
      case PerspectiveMode.player:
        final target = perspective.playerName.toLowerCase().trim();
        if (b == target) {
          boardFlipped = true;
        } else if (w == target) {
          boardFlipped = false;
        }
    }
    notifyListeners();
  }

  void setPerspective(Perspective p) {
    perspective = p;
    notifyListeners();
    persistPerspective();
    orientBoardForCurrentGame();
    if (isSolitaireMode) _restartSolitaireForCurrentOrientation();
    onReclaimFocus?.call();
  }

  Future<void> persistPerspective() async {
    if (allGames.isEmpty) return;
    final first = allGames.first;
    final value = perspective.toHeaderValue();
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

    await persistMetadata();
  }

  String? detectProtagonist() => detectProtagonistFrom(allGames);

  /// Returns both player names when all games are between the same two players.
  ({String player1, String player2})? detectBothPlayers() =>
      detectBothPlayersFrom(allGames);

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
    currentGameIndex =
        (currentGameIndex + 1).clamp(0, filteredGames.length - 1);
    notifyListeners();
    loadCurrentGame();
  }

  void prevGame() {
    if (filteredGames.isEmpty) return;
    currentGameIndex =
        (currentGameIndex - 1).clamp(0, filteredGames.length - 1);
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

  void stopAutoPlay() => _autoPlay.stop();

  void setAutoPlaySpeed(double val) => _autoPlay.setSpeed(val);

  void setAutoNextGame(bool value) => _autoPlay.setAutoNextGame(value);

  void toggleBoardFlipped() {
    boardFlipped = !boardFlipped;
    notifyListeners();
    if (isSolitaireMode) _restartSolitaireForCurrentOrientation();
  }

  Future<void> toggleFullScreen() async {
    final entering = !isFullScreen;
    await windowManager.setFullScreen(entering);
    if (!isActive()) return;
    isFullScreen = entering;
    notifyListeners();
    onReclaimFocus?.call();
  }

  Future<void> exitFullScreen() async {
    if (!isFullScreen) return;
    await windowManager.setFullScreen(false);
    if (!isActive()) return;
    isFullScreen = false;
    notifyListeners();
    onReclaimFocus?.call();
  }

  void onWindowLeaveFullScreen() {
    if (isActive() && isFullScreen) {
      isFullScreen = false;
      notifyListeners();
    }
  }

  void onWindowEnterFullScreen() {
    if (isActive() && !isFullScreen) {
      isFullScreen = true;
      notifyListeners();
    }
  }

  void setRating(int stars) {
    if (filteredGames.isEmpty) return;
    final game = filteredGames[currentGameIndex];
    game.studyRating = stars;
    notifyListeners();
    persistMetadata();
    onReclaimFocus?.call();
  }

  Future<void> persistMetadata() async {
    persistDebounce?.cancel();
    persistDebounce = Timer(const Duration(milliseconds: 300), () {
      doPersistMetadata();
    });
  }

  Future<void> doPersistMetadata() async {
    if (filePath == null) return;
    final gameData = allGames
        .map((g) =>
            (pgn: g.pgnText, rating: g.studyRating, summary: g.studySummary))
        .toList();

    final result = await compute(buildMetadataOutput, gameData);

    if (!isActive()) return;
    for (int i = 0; i < result.length && i < allGames.length; i++) {
      allGames[i].pgnText = result[i];
    }
    try {
      await StorageFactory.instance
          .writeFile(filePath!, '${result.join('\n\n')}\n');
      _fenIndex.persist(filePath: filePath, gameTotal: allGames.length);
    } catch (e) {
      debugPrint('Failed to persist metadata: $e');
    }
  }

  void persistMoveComments(String updatedPgnMovetext) {
    if (filteredGames.isEmpty || filePath == null) return;
    final game = filteredGames[currentGameIndex];

    final headerEnd = RegExp(r'\]\s*\n').allMatches(game.pgnText).last;
    final headerPart = game.pgnText.substring(0, headerEnd.end);
    game.pgnText = '$headerPart\n$updatedPgnMovetext\n';

    persistMetadata();
  }

  void applySlice(List<int> indices, SliceConfig config) {
    if (_activeSliceIndices != null &&
        listEquals(_activeSliceIndices, indices) &&
        config.toJsonString() == activeSliceConfig.toJsonString()) {
      return;
    }
    _activeSliceIndices = List<int>.from(indices);
    filteredGames = indices.map((i) => allGames[i]).toList();
    hasActiveFilters = filteredGames.length != allGames.length;
    activeSliceConfig = config;
    currentGameIndex = 0;
    _viewerTree.clearTree();
    notifyListeners();
    persistSliceConfig(config);
    if (showOpeningTree) _viewerTree.rebuild();
    loadCurrentGame();
  }

  void resetFilters() {
    filteredGames = List.of(allGames);
    hasActiveFilters = false;
    activeSliceConfig = const SliceConfig.empty();
    _activeSliceIndices = null;
    currentGameIndex = 0;
    _viewerTree.clearTree();
    notifyListeners();
    clearSavedSlice();
    applySortMode();
    if (showOpeningTree) _viewerTree.rebuild();
    loadCurrentGame();
  }

  Future<void> removeSliceChip(int chipIndex) async {
    final labels = activeSliceConfig.chipLabels;
    if (chipIndex < 0 || chipIndex >= labels.length) return;

    final hasPos = activeSliceConfig.positionInput != null &&
        activeSliceConfig.positionInput!.isNotEmpty;
    final hasSeq = activeSliceConfig.sequencePattern != null &&
        activeSliceConfig.sequencePattern!.isNotEmpty;
    String? newPositionInput = activeSliceConfig.positionInput;
    String? newSequencePattern = activeSliceConfig.sequencePattern;
    int newSequenceGap = activeSliceConfig.sequenceGap;
    final newHeaders =
        List<HeaderFilterConfig>.from(activeSliceConfig.headerFilters);

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
      resetFilters();
      return;
    }

    final allRecords =
        allGames.map((g) => (headers: g.headers, pgnText: g.pgnText)).toList();
    isLoading = true;
    notifyListeners();

    final indices =
        await applySliceConfig(newConfig, allRecords, fenIndex: fenIndex);
    if (!isActive()) return;

    isLoading = false;
    filteredGames = indices.map((i) => allGames[i]).toList();
    hasActiveFilters = filteredGames.length != allGames.length;
    activeSliceConfig = newConfig;
    _activeSliceIndices = List<int>.from(indices);
    currentGameIndex = 0;
    _viewerTree.clearTree();
    notifyListeners();
    persistSliceConfig(newConfig);
    if (showOpeningTree) _viewerTree.rebuild();
    loadCurrentGame();
  }

  Future<void> persistSliceConfig(SliceConfig config) async {
    if (filePath == null) return;
    await SlicePersistence.save(filePath!, config);
  }

  Future<void> clearSavedSlice() async {
    if (filePath == null) return;
    await SlicePersistence.clear(filePath!);
  }

  void setSortMode(GameSortMode mode) {
    sortMode = mode;
    notifyListeners();
    applySortMode();
    currentGameIndex = 0;
    notifyListeners();
    loadCurrentGame();
  }

  void applySortMode() {
    _viewerTree.clearCache();
    switch (sortMode) {
      case GameSortMode.fileOrder:
        if (hasActiveFilters) {
          final filteredSet = filteredGames.toSet();
          filteredGames =
              allGames.where((g) => filteredSet.contains(g)).toList();
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

  void navigateBack() {
    if (isSolitaireMode) return;
    stopAutoPlay();
    if (showOpeningTree) {
      _viewerTree.goBack();
    } else {
      pgnWidgetController.goBack();
    }
  }

  void navigateForward() {
    if (isSolitaireMode) return;
    stopAutoPlay();
    if (showOpeningTree) {
      _viewerTree.goForward();
    } else {
      pgnWidgetController.goForward();
    }
  }

  void navigateToStart() {
    if (isSolitaireMode) return;
    stopAutoPlay();
    if (showOpeningTree) {
      _viewerTree.resetToStart();
    } else {
      pgnWidgetController.clearEphemeralMoves();
      pgnWidgetController.jumpToMove(1, true);
    }
  }

  void navigateToEnd() {
    if (isSolitaireMode) return;
    stopAutoPlay();
    if (showOpeningTree) {
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

  // ---------------------------------------------------------------------------
  // SOLITAIRE MODE
  // ---------------------------------------------------------------------------

  void toggleSolitaire() {
    if (isSolitaireMode) {
      solitaire.stop();
      notifyListeners();
    } else {
      _startSolitaire();
    }
  }

  Future<void> loadSolitaireSettings() async {
    final prefs = await SharedPreferences.getInstance();
    solitaire.revealDelaySec = prefs.getInt(_revealDelayKey) ?? 60;
    trophyThresholdCp = prefs.getInt(_trophyThresholdKey) ?? 20;
    final trophies = await SolitaireTrophyService.instance.loadAll();
    totalTrophyCount = trophies.length;
  }

  Future<void> setSolitaireRevealDelay(int seconds) async {
    solitaire.revealDelaySec = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_revealDelayKey, seconds);
    notifyListeners();
  }

  Future<void> setTrophyThreshold(int cp) async {
    trophyThresholdCp = cp;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_trophyThresholdKey, cp);
    notifyListeners();
  }

  void _startSolitaire() {
    if (filteredGames.isEmpty) return;
    stopAutoPlay();
    pgnWidgetController.clearEphemeralMoves();
    pgnWidgetController.goToMainLineIndex(0);

    solitaire.onAdvancePosition = () {
      pgnWidgetController.goForward();
      notifyListeners();
    };
    solitaire.onResetPosition = () {
      // no-op: board already shows the pre-move position since the move
      // wasn't applied to the widget
    };

    solitaire.start(
      mainLineLength: pgnWidgetController.mainLineLength,
      userPlaysWhite: !boardFlipped,
      whiteToMoveAtStart: currentPosition.turn == Side.white,
    );
    solitaire.removeListener(_onSolitaireChanged);
    solitaire.addListener(_onSolitaireChanged);
    notifyListeners();
  }

  void _restartSolitaireForCurrentOrientation() {
    pgnWidgetController.goToMainLineIndex(0);
    solitaire.onGameChanged(
      mainLineLength: pgnWidgetController.mainLineLength,
      userPlaysWhite: !boardFlipped,
      whiteToMoveAtStart: currentPosition.turn == Side.white,
    );
  }

  /// Build annotated PGN movetext with solitaire guess comments.
  String buildSolitaireGuessPgn() {
    return solitaire.buildGuessPgn(pgnWidgetController.mainLineMoves);
  }

  /// Inject solitaire guess annotations into the current game's PGN movetext.
  void _injectGuessComments() {
    if (filteredGames.isEmpty || filePath == null) return;
    final guessMovetext = buildSolitaireGuessPgn();
    persistMoveComments(guessMovetext);
  }

  void revealCurrentMove() {
    if (!isSolitaireMode || !solitaire.waitingForUser) return;
    final mainIdx = solitaire.revealedPly;
    final moveHistory = pgnWidgetController.mainLineMoves;
    if (mainIdx >= moveHistory.length) return;
    solitaire.revealMove(moveHistory[mainIdx]);
  }

  void _onSolitaireChanged() {
    if (solitaire.isComplete) {
      _injectGuessComments();
    }
    notifyListeners();
  }

  void _handleSolitaireMove(String san) {
    final mainIdx = solitaire.revealedPly;
    final moveHistory = pgnWidgetController.mainLineMoves;
    if (mainIdx >= moveHistory.length) return;

    final expectedSan = moveHistory[mainIdx];
    solitaire.handleMove(san, currentPosition, expectedSan);
  }

  /// After analysis completes, scan solitaire guess log for wrong attempts
  /// that beat the GM's move by [trophyThresholdCp] or more. Awards trophies.
  ///
  /// Returns the number of new trophies detected.
  Future<int> detectSolitaireTrophies() async {
    final guessLog = solitaire.guessLog;
    final evals = analysisController.evals;
    if (guessLog.isEmpty || evals.isEmpty) return 0;

    final evalByPly = <int, MoveEval>{};
    for (final e in evals) {
      evalByPly[e.ply] = e;
    }

    final game = filteredGames.isNotEmpty
        ? filteredGames[currentGameIndex]
        : null;
    final gameLabel = game != null ? game.label : '';
    final headers = game?.headers ?? <String, String>{};
    final gamePgn = game?.pgnText ?? '';
    final userIsWhite = solitaire.userIsWhite;

    final pool = StockfishPool.instance;
    final depth = analysisController.depth;

    final newTrophies = <SolitaireTrophy>[];

    try {
      await pool.ensureWorkers();

      for (final guess in guessLog) {
        if (guess.wrongAttempts.isEmpty) continue;

        final gmEval = evalByPly[guess.ply + 1];
        if (gmEval == null) continue;

        final fen = gmEval.fenBefore;
        final gmCp = gmEval.effectiveCp;

        for (final wrongSan in guess.wrongAttempts) {
          try {
            final pos = Chess.fromSetup(Setup.parseFen(fen));
            final move = pos.parseSan(wrongSan);
            if (move == null) continue;
            final afterPos = pos.play(move);
            final result = await pool.evaluateFen(afterPos.fen, depth);

            // Normalize to White's perspective (same as MoveEval.effectiveCp)
            final isWhiteToMoveAfter = afterPos.turn == Side.white;
            final userCpWhiteNorm =
                isWhiteToMoveAfter ? result.effectiveCp : -result.effectiveCp;

            // Advantage from the guessing side's perspective
            final advantage = userIsWhite
                ? (userCpWhiteNorm - gmCp)
                : (gmCp - userCpWhiteNorm);

            if (advantage >= trophyThresholdCp) {
              newTrophies.add(SolitaireTrophy(
                id: '${DateTime.now().microsecondsSinceEpoch}_${guess.ply}_$wrongSan',
                date: DateTime.now(),
                fen: fen,
                userMove: wrongSan,
                gmMove: guess.expectedSan,
                userEvalCp: userCpWhiteNorm,
                gmEvalCp: gmCp,
                advantageCp: advantage,
                gameLabel: gameLabel,
                headers: Map<String, String>.from(headers),
                pgn: gamePgn,
              ));
            }
          } catch (e) {
            debugPrint('Trophy eval failed for $wrongSan: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Trophy detection failed: $e');
    }

    if (newTrophies.isNotEmpty) {
      await SolitaireTrophyService.instance.addTrophies(newTrophies);
      totalTrophyCount = SolitaireTrophyService.instance.count;
    }
    lastDetectedTrophies = newTrophies;
    notifyListeners();
    return newTrophies.length;
  }

  List<int> gamesAtTreePosition() => _viewerTree.gamesAtTreePosition();

  void loadGameFromTree(int filteredIndex) {
    _viewerTree.hide();
    currentGameIndex = filteredIndex;
    notifyListeners();
    loadCurrentGame();
  }

  String? defaultExportFileName() {
    if (filePath == null) return null;
    return '${p.basenameWithoutExtension(filePath!)}_slice.pgn';
  }

  String buildExportContent() {
    return '${filteredGames.map((g) => g.pgnText).join('\n\n')}\n';
  }

  Future<String?> exportSliceToPath(String outPath) async {
    if (filteredGames.isEmpty || filePath == null) return null;
    final savePath = outPath.endsWith('.pgn') ? outPath : '$outPath.pgn';
    try {
      await StorageFactory.instance.writeFile(savePath, buildExportContent());
      return savePath;
    } catch (e) {
      debugPrint('Export failed: $e');
      return null;
    }
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
