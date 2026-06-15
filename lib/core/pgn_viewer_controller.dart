import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../constants/engine_defaults.dart';
import '../models/opening_tree.dart';
import '../models/pgn_filter_models.dart';
import '../services/default_pgn_service.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/storage/storage_factory.dart';
import '../services/game_analysis_controller.dart';
import '../services/opening_tree_builder.dart';
import '../utils/fen_utils.dart';
import '../widgets/pgn_viewer_widget.dart';

// ---------------------------------------------------------------------------
// Lightweight model wrapping a single parsed game + its raw text for rewrite.
// ---------------------------------------------------------------------------
class PgnGameEntry {
  final Map<String, String> headers;
  String pgnText; // full single-game PGN (headers + moves)
  int studyRating; // 0 = unrated, 1-5
  String studySummary; // user's one-line summary of the game

  PgnGameEntry({
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
  static const slicePrefsPrefix = 'pgn_slice:';

  int currentGameIndex = 0;
  Position currentPosition = Chess.initial;
  bool boardFlipped = false;

  Perspective perspective = const Perspective();

  bool showOpeningTree = false;
  OpeningTree? openingTree;
  bool buildingTree = false;
  int treeBuildProcessed = 0;
  int treeBuildTotal = 0;
  int treeBuildGeneration = 0;
  final Map<String, List<int>> treePositionGameCache = {};
  List<String> treeCurrentMoveSequence = [];

  Map<String, List<int>>? _fenIndex;
  int _fenIndexGeneration = 0;

  /// Read-only access to the precomputed FEN → game-indices map.
  /// Returns null while the index is being built.
  Map<String, List<int>>? get fenIndex => _fenIndex;

  bool isLoading = false;

  Timer? autoPlayTimer;
  bool isAutoPlaying = false;
  bool autoNextGame = false;
  double autoPlayDelaySec = 1.0;
  bool isFirstAutoPlayStep = false;
  DateTime? lastAutoPlayStepTime;

  int? activeEngineLineMoveIdx;

  GameSortMode sortMode = GameSortMode.fileOrder;

  List<String> recentFiles = [];
  static const recentFilesKey = 'pgn_viewer_recent_files';
  static const maxRecentFiles = 10;

  String? collectionsDir;

  bool isFullScreen = false;

  Timer? persistDebounce;

  SliceRestoreInfo? pendingSliceRestore;

  String? errorMessage;

  static const maxTreeCacheEntries = 500;

  int get currentPly => pgnWidgetController.mainLineIndex;

  void disposeController() {
    autoPlayTimer?.cancel();
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
    openingTree = null;
    showOpeningTree = false;
    treeCurrentMoveSequence = [];
    notifyListeners();

    await addToRecentFiles(path);
    await _tryLoadPersistedFenIndex(path, entries.length);
    await tryRestoreSavedSlice(path, entries);
    await loadCurrentGame();
    if (_fenIndex == null) _buildFenIndex();
  }

  Future<void> _tryLoadPersistedFenIndex(String pgnPath, int gameCount) async {
    try {
      final storage = StorageFactory.instance;
      final stat = await storage.fileStat(pgnPath);
      if (stat == null) return;

      final idxPath = '$pgnPath.fenidx';
      if (!await storage.fileExists(idxPath)) return;
      final data = await storage.readFile(idxPath);
      if (data == null || data.isEmpty) return;
      final index = pgn.deserializeFenIndex(
        data,
        expectedGameCount: gameCount,
        expectedFileSize: stat.size,
        expectedModifiedMs: stat.modified.millisecondsSinceEpoch,
      );
      if (index == null) return;
      _fenIndex = index;
    } catch (_) {
      // Corrupt or unreadable — fall through to building from scratch.
    }
  }

  Future<void> _buildFenIndex() async {
    final generation = ++_fenIndexGeneration;
    _fenIndex = null;

    final gameData = allGames
        .map((g) => (
              headers: Map<String, String>.from(g.headers),
              pgnText: g.pgnText,
            ))
        .toList();

    final index = await Isolate.run(() => pgn.buildFenIndex(gameData));
    if (!isActive() || generation != _fenIndexGeneration) return;

    _fenIndex = index;
    notifyListeners();
    _persistFenIndex();
  }

  Future<void> _persistFenIndex() async {
    if (filePath == null || _fenIndex == null) return;
    try {
      final storage = StorageFactory.instance;
      final stat = await storage.fileStat(filePath!);
      if (stat == null) return;
      final data = pgn.serializeFenIndex(
        _fenIndex!,
        gameCount: allGames.length,
        fileSize: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
      await storage.writeFile('$filePath.fenidx', data);
    } catch (e) {
      debugPrint('Failed to persist FEN index: $e');
    }
  }

  Future<void> tryRestoreSavedSlice(
      String path, List<PgnGameEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('$slicePrefsPrefix$path');
    if (json == null) return;
    final config = SliceConfig.fromJsonString(json);
    if (config.isEmpty) return;

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
    activeEngineLineMoveIdx = null;
    orientBoardForCurrentGame();
    final game = filteredGames[currentGameIndex];
    await analysisController.tryLoadFromPgn(game.pgnText);
    if (!isActive()) return;
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
    if (isAutoPlaying) {
      stopAutoPlay();
    } else {
      startAutoPlay();
    }
    onReclaimFocus?.call();
  }

  void startAutoPlay() {
    isFirstAutoPlayStep = true;
    isAutoPlaying = true;
    notifyListeners();
    scheduleNextAutoPlayStep();
  }

  void stopAutoPlay() {
    autoPlayTimer?.cancel();
    autoPlayTimer = null;
    if (isAutoPlaying) {
      isAutoPlaying = false;
      notifyListeners();
    }
  }

  void scheduleNextAutoPlayStep() {
    autoPlayTimer?.cancel();
    if (!isAutoPlaying) return;
    final delayMs =
        isFirstAutoPlayStep ? 300 : (autoPlayDelaySec * 1000).round();
    isFirstAutoPlayStep = false;
    autoPlayTimer = Timer(Duration(milliseconds: delayMs), autoPlayStep);
  }

  void autoPlayStep() {
    if (!isActive() || !isAutoPlaying) return;
    if (pgnWidgetController.currentFen == null) return;
    lastAutoPlayStepTime = DateTime.now();

    final fenBefore = pgnWidgetController.currentFen;
    pgnWidgetController.goForward();

    final checkAfterForward = () {
      if (!isActive() || !isAutoPlaying) return;
      final fenAfter = pgnWidgetController.currentFen;
      if (fenAfter == fenBefore) {
        if (autoNextGame && currentGameIndex < filteredGames.length - 1) {
          nextGame();
          startAutoPlay();
        } else {
          stopAutoPlay();
        }
      } else {
        scheduleNextAutoPlayStep();
      }
    };

    if (schedulePostFrame != null) {
      schedulePostFrame!(checkAfterForward);
    } else {
      checkAfterForward();
    }
  }

  void setAutoPlaySpeed(double val) {
    autoPlayDelaySec = val;
    notifyListeners();
    if (!isAutoPlaying || lastAutoPlayStepTime == null) return;

    autoPlayTimer?.cancel();
    final elapsedMs =
        DateTime.now().difference(lastAutoPlayStepTime!).inMilliseconds;
    final newDelayMs = (val * 1000).round();
    final remainingMs = newDelayMs - elapsedMs;

    if (remainingMs <= 0) {
      autoPlayStep();
    } else {
      autoPlayTimer = Timer(Duration(milliseconds: remainingMs), autoPlayStep);
    }
  }

  void setAutoNextGame(bool value) {
    autoNextGame = value;
    notifyListeners();
  }

  void toggleBoardFlipped() {
    boardFlipped = !boardFlipped;
    notifyListeners();
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
      _persistFenIndex();
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
    openingTree = null;
    notifyListeners();
    persistSliceConfig(config);
    if (showOpeningTree) rebuildOpeningTree();
    loadCurrentGame();
  }

  void resetFilters() {
    filteredGames = List.of(allGames);
    hasActiveFilters = false;
    activeSliceConfig = const SliceConfig.empty();
    _activeSliceIndices = null;
    currentGameIndex = 0;
    openingTree = null;
    notifyListeners();
    clearSavedSlice();
    applySortMode();
    if (showOpeningTree) rebuildOpeningTree();
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
    openingTree = null;
    notifyListeners();
    persistSliceConfig(newConfig);
    if (showOpeningTree) rebuildOpeningTree();
    loadCurrentGame();
  }

  Future<void> persistSliceConfig(SliceConfig config) async {
    if (filePath == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (config.isEmpty) {
      await prefs.remove('$slicePrefsPrefix$filePath');
    } else {
      await prefs.setString(
          '$slicePrefsPrefix$filePath', config.toJsonString());
    }
  }

  Future<void> clearSavedSlice() async {
    if (filePath == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$slicePrefsPrefix$filePath');
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
    treePositionGameCache.clear();
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
    if (activeEngineLineMoveIdx != null &&
        pgnWidgetController.variationDepth == 0) {
      activeEngineLineMoveIdx = null;
    }
    notifyListeners();
  }

  void toggleOpeningTree() {
    showOpeningTree = !showOpeningTree;
    notifyListeners();
    if (showOpeningTree && openingTree == null && filteredGames.isNotEmpty) {
      rebuildOpeningTree();
    } else if (showOpeningTree && openingTree != null) {
      _syncTreeToCurrentPosition();
    }
    onReclaimFocus?.call();
  }

  Future<void> rebuildOpeningTree() async {
    final generation = ++treeBuildGeneration;
    if (filteredGames.isEmpty) {
      openingTree = null;
      buildingTree = false;
      treeBuildProcessed = 0;
      treeBuildTotal = 0;
      treePositionGameCache.clear();
      notifyListeners();
      return;
    }
    buildingTree = true;
    treeBuildProcessed = 0;
    treeBuildTotal = filteredGames.length;
    treePositionGameCache.clear();
    notifyListeners();

    try {
      final tree = await OpeningTreeBuilder.buildTree(
        pgnList: filteredGames.map((g) => g.pgnText).toList(),
        username: '',
        userIsWhite: null,
        strictPlayerMatching: false,
        maxDepth: kOpeningTreeMaxDepth,
        onProgress: (processed, total) {
          if (!isActive() || generation != treeBuildGeneration) return;
          treeBuildProcessed = processed;
          treeBuildTotal = total;
          notifyListeners();
        },
      );
      if (!isActive() || generation != treeBuildGeneration) return;
      openingTree = tree;
      buildingTree = false;
      treeBuildProcessed = treeBuildTotal;
      _syncTreeToCurrentPosition();
      notifyListeners();
    } catch (e) {
      if (!isActive() || generation != treeBuildGeneration) return;
      buildingTree = false;
      openingTree = null;
      treeBuildProcessed = 0;
      treeBuildTotal = 0;
      notifyListeners();
      debugPrint('Failed to build opening tree: $e');
    }
  }

  void onTreeMoveSelected(String move) {
    if (openingTree == null) return;
    if (openingTree!.makeMove(move)) {
      treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
      _updatePositionFromTree();
    }
    notifyListeners();
  }

  void onTreeGoBack() {
    if (openingTree == null) return;
    openingTree!.goBack();
    treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
    _updatePositionFromTree();
    notifyListeners();
  }

  void onTreeGoForward() {
    if (openingTree == null) return;
    final children = openingTree!.currentNode.sortedChildren;
    if (children.isNotEmpty) {
      onTreeMoveSelected(children.first.move);
    }
  }

  // ── Unified navigation (mode-aware) ──

  void navigateBack() {
    stopAutoPlay();
    if (showOpeningTree) {
      onTreeGoBack();
    } else {
      pgnWidgetController.goBack();
    }
  }

  void navigateForward() {
    stopAutoPlay();
    if (showOpeningTree) {
      onTreeGoForward();
    } else {
      pgnWidgetController.goForward();
    }
  }

  void navigateToStart() {
    stopAutoPlay();
    if (showOpeningTree) {
      openingTree?.reset();
      treeCurrentMoveSequence = [];
      _updatePositionFromTree();
      notifyListeners();
    } else {
      pgnWidgetController.clearEphemeralMoves();
      pgnWidgetController.jumpToMove(1, true);
    }
  }

  void navigateToEnd() {
    stopAutoPlay();
    if (showOpeningTree) {
      while (openingTree != null &&
          openingTree!.currentNode.sortedChildren.isNotEmpty) {
        openingTree!
            .makeMove(openingTree!.currentNode.sortedChildren.first.move);
      }
      if (openingTree != null) {
        treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
        _updatePositionFromTree();
        notifyListeners();
      }
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
      onTreeMoveSelected(san);
    } else {
      stopAutoPlay();
      pgnWidgetController.addEphemeralMove(san);
    }
  }

  /// Sync the opening tree cursor to the current board position by replaying
  /// the PGN widget's mainline moves through the tree.
  void _syncTreeToCurrentPosition() {
    if (openingTree == null) return;
    final mainIdx = pgnWidgetController.mainLineIndex;
    if (mainIdx <= 0) {
      openingTree!.reset();
      treeCurrentMoveSequence = [];
      return;
    }
    // Walk the tree along the game's mainline moves up to mainIdx.
    openingTree!.reset();
    final state = pgnWidgetController;
    // Use the mainline length to rebuild the move list.
    final moveCount = state.mainLineLength;
    if (moveCount == 0) {
      treeCurrentMoveSequence = [];
      return;
    }
    // Navigate to current position via FEN lookup as a fallback.
    final fen = currentPosition.fen;
    if (openingTree!.navigateToFen(fen)) {
      treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
    } else {
      openingTree!.reset();
      treeCurrentMoveSequence = [];
    }
  }

  /// Update [currentPosition] from the tree's current node FEN.
  void _updatePositionFromTree() {
    if (openingTree == null) return;
    final fen = openingTree!.currentNode.fen;
    try {
      currentPosition = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      // FEN may be invalid in rare cases; ignore.
    }
  }

  List<int> gamesAtTreePosition() {
    if (openingTree == null) return [];
    final fen = normalizeFen(openingTree!.currentNode.fen);
    return treePositionGameCache.putIfAbsent(fen, () {
      if (treePositionGameCache.length >= maxTreeCacheEntries) {
        final keysToRemove =
            treePositionGameCache.keys.take(maxTreeCacheEntries ~/ 4).toList();
        for (final k in keysToRemove) {
          treePositionGameCache.remove(k);
        }
      }

      // Fast path: map FEN-index (allGames indices) → filteredGames indices
      if (_fenIndex != null) {
        final allIndices = _fenIndex![fen] ?? const [];
        if (allIndices.isEmpty) return <int>[];
        final entryToFiltered = <PgnGameEntry, int>{};
        for (int fi = 0; fi < filteredGames.length; fi++) {
          entryToFiltered[filteredGames[fi]] = fi;
        }
        final results = <int>[];
        for (final ai in allIndices) {
          final fi = entryToFiltered[allGames[ai]];
          if (fi != null) results.add(fi);
        }
        return results;
      }

      final results = <int>[];
      for (int i = 0; i < filteredGames.length; i++) {
        if (pgn.gamePassesThroughFen(
            filteredGames[i].headers, filteredGames[i].pgnText, fen)) {
          results.add(i);
        }
      }
      return results;
    });
  }

  void loadGameFromTree(int filteredIndex) {
    showOpeningTree = false;
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

    activeEngineLineMoveIdx = clickedIndex;
    notifyListeners();
    onReclaimFocus?.call();
  }
}
