import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../models/pgn_game_entry.dart';
import '../../../utils/chess_utils.dart' show tryParseFen;
import '../../../utils/safe_change_notifier.dart';
import '../models/viewer_session.dart';
import '../repositories/pgn_viewer_handle.dart';
import '../repositories/viewer_analysis_port.dart';
import '../repositories/viewer_opening_repository.dart';
import '../repositories/viewer_preferences_repository.dart';
import '../repositories/viewer_solitaire_repository.dart';
import 'auto_play_engine.dart';
import 'viewer_collection_controller.dart';
import 'viewer_opening_tree.dart';
import 'viewer_presentation_controller.dart';
import 'viewer_session_controller.dart';
import 'viewer_solitaire_session.dart';

/// Owns the reading cursor, mode transitions and selection-bound analysis.
/// Document replacement is owned separately; widgets use playback, tree and
/// Solitaire directly for their own commands and state.
class ViewerReadingController extends ChangeNotifier with SafeChangeNotifier {
  ViewerReadingController({
    required this.collection,
    required this.handle,
    required this.analysis,
    required this.presentation,
    required ViewerOpeningRepository openings,
    required ViewerSolitaireRepository solitaireRepository,
    required ViewerPreferencesRepository preferences,
    required this.path,
    required this.collectionLoading,
    required Map<String, List<int>>? Function() index,
    required this.onAnnotatedGame,
    required this.isActive,
    this.schedulePostFrame,
    this.onReclaimFocus,
  }) : sessions = ViewerSessionController(preferences) {
    tree = ViewerOpeningTree(
      repository: openings,
      isActive: isActive,
      onChanged: notifyListeners,
      collection: collection,
      fenIndex: index,
      currentFen: () => currentPosition.fen,
      applyPosition: (position) => currentPosition = position,
      onReclaimFocus: onReclaimFocus,
    );
    playback = AutoPlayEngine(
      isActive: isActive,
      handle: handle,
      hasNextGame: () =>
          collection.selectedIndex < collection.visibleGames.length - 1,
      nextGame: nextGame,
      onChanged: notifyListeners,
      schedulePostFrame: schedulePostFrame,
    );
    solitaire = ViewerSolitaireSession(
      repository: solitaireRepository,
      onError: (error) {
        if (isDisposed) return;
        errorMessage = error;
        notifyListeners();
      },
      handle: handle,
      hasGames: () => collection.visibleGames.isNotEmpty,
      userPlaysWhite: () => !presentation.boardFlipped,
      stopAutoPlay: playback.stop,
      onChanged: notifyListeners,
    );
  }

  final ViewerCollectionController collection;
  final PgnViewerHandle handle;
  final ViewerAnalysisPort analysis;
  final ViewerPresentationController presentation;
  final ViewerSessionController sessions;
  final String? Function() path;
  final bool Function() collectionLoading;
  final void Function(PgnGameEntry, String) onAnnotatedGame;
  final bool Function() isActive;
  final void Function(void Function())? schedulePostFrame;
  final VoidCallback? onReclaimFocus;
  late final ViewerOpeningTree tree;
  late final AutoPlayEngine playback;
  late final ViewerSolitaireSession solitaire;
  Position currentPosition = Chess.initial;
  String? pgnInitialFen;
  String? _gameCursorFen;
  final Map<PgnGameEntry, int> _resumePlyByGame = {};
  bool restoringSession = false;
  String? errorMessage;
  int _selectionEpoch = 0;
  bool _abandoning = false;

  int resumePlyFor(PgnGameEntry game) => _resumePlyByGame[game] ?? 0;
  void bookmark(PgnGameEntry game, int ply) => _resumePlyByGame[game] = ply;
  Map<PgnGameEntry, int> captureBookmarks() =>
      Map.unmodifiable(_resumePlyByGame);
  void restoreBookmarks(Map<PgnGameEntry, int> bookmarks) =>
      _resumePlyByGame.addAll(bookmarks);

  /// Cancellation publishes no half-transition. The document command publishes
  /// after its replacement state is installed.
  void abandon() {
    _selectionEpoch++;
    restoringSession = false;
    _abandoning = true;
    try {
      tree.cancelBuild();
      playback.stop();
      analysis.cancel();
      analysis.clearEvals();
      if (solitaire.isActive) solitaire.stop();
      solitaire.cancelSetup();
    } finally {
      _abandoning = false;
    }
  }

  void resetForCollection() {
    _resumePlyByGame.clear();
    pgnInitialFen = null;
    _gameCursorFen = null;
    tree.resetForNewFile();
  }

  @override
  void notifyListeners() {
    if (!_abandoning) super.notifyListeners();
  }

  void onViewerGameLoaded() {
    if (solitaire.isActive) solitaire.restartForNewGame();
  }

  Future<void> loadSolitaireSettings() async {
    try {
      await solitaire.loadSettings();
    } catch (error) {
      if (isDisposed || !isActive()) return;
      errorMessage = 'Could not load solitaire progress: $error';
      notifyListeners();
    }
  }

  Future<void> setSolitaireRevealDelay(int seconds) async {
    try {
      await solitaire.setRevealDelay(seconds);
    } catch (_) {
      if (isDisposed || !isActive()) return;
      errorMessage = 'Could not save solitaire settings. Try again.';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _selectionEpoch++;
    tree.dispose();
    playback.dispose();
    solitaire.dispose();
    analysis.cancel();
    super.dispose();
  }

  void rememberCurrentPlace() {
    if (tree.showOpeningTree || solitaire.isActive || collectionLoading()) {
      return;
    }
    if (collection.selectedIndex < 0 ||
        collection.selectedIndex >= collection.visibleGames.length) {
      return;
    }
    _resumePlyByGame[collection.visibleGames[collection.selectedIndex]] = handle
        .mainLineIndex
        .clamp(0, 100000);
  }

  /// Called only by the game reader; tree/reference cursors are independent.
  void rememberReadingPosition() {
    if (restoringSession || collectionLoading()) return;
    rememberCurrentPlace();
    unawaited(saveSession());
    notifyListeners();
  }

  Future<void> closeSession() => _reportSessionResult(sessions.close());

  Future<void> saveSession() {
    final path = this.path();
    if (restoringSession ||
        collectionLoading() ||
        path == null ||
        collection.visibleGames.isEmpty) {
      return Future.value();
    }
    final game = collection.visibleGames[collection.selectedIndex];
    final session = ViewerSession(
      gameIndex: collection.games.indexOf(game),
      gameKey: ViewerSession.keyFor(game),
      ply: resumePlyFor(game),
      sortMode: collection.sortMode,
    );
    return _reportSessionResult(sessions.save(path, session));
  }

  static const _sessionFailure =
      'Could not save the reading position. Try again before closing.';
  Future<void> _reportSessionResult(Future<bool> operation) async {
    await operation;
    if (isDisposed || !isActive()) return;
    if (sessions.error != null) {
      errorMessage = _sessionFailure;
      notifyListeners();
    } else if (errorMessage == _sessionFailure) {
      errorMessage = null;
      notifyListeners();
    }
  }

  void orientBoardForCurrentGame() {
    final games = collection.visibleGames;
    presentation.orient(
      games.isEmpty ? null : games[collection.selectedIndex].headers,
    );
  }

  Future<void> loadCurrentGame({bool enrich = true}) async {
    if (isDisposed || !isActive()) return;
    final gameLoadEpoch = ++_selectionEpoch;
    playback.stop();
    analysis.cancel();
    if (collection.visibleGames.isEmpty) {
      analysis.clearEvals();
      pgnInitialFen = null;
      _gameCursorFen = null;
      currentPosition = Chess.initial;
      if (solitaire.isActive) solitaire.stop();
      solitaire.cancelSetup();
      notifyListeners();
      return;
    }
    final game = collection.visibleGames[collection.selectedIndex];
    if (!tree.showOpeningTree) {
      currentPosition =
          _tryParseFen(pgnInitialFen) ??
          _tryParseFen(game.headers['FEN']) ??
          Chess.initial;
    }
    orientBoardForCurrentGame();
    final restored = await analysis.tryLoadFromPgn(game.pgnText);
    if (isDisposed || !isActive() || gameLoadEpoch != _selectionEpoch) return;
    notifyListeners();
    onReclaimFocus?.call();
    if (restored && enrich) unawaited(_fillMissingBestLines(game));
    unawaited(saveSession());
  }

  /// A stored graph whose mistakes carry no line gets them now: a few short
  /// searches, written back onto [game] so it happens once. The widget
  /// adopts the new comments in place, so the reader is not moved.
  Future<void> _fillMissingBestLines(PgnGameEntry game) async {
    final source = collection.games;
    await analysis.fillMissingBestLines(
      game.pgnText,
      onAnnotatedMovetext: (movetext) {
        if (isDisposed || !isActive() || !identical(source, collection.games)) {
          return;
        }
        onAnnotatedGame(game, movetext);
        notifyListeners();
      },
    );
  }

  void nextGame() {
    if (collection.visibleGames.isEmpty) return;
    rememberCurrentPlace();
    pgnInitialFen = null;
    collection.select(
      (collection.selectedIndex + 1).clamp(
        0,
        collection.visibleGames.length - 1,
      ),
    );
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  void prevGame() {
    if (collection.visibleGames.isEmpty) return;
    rememberCurrentPlace();
    pgnInitialFen = null;
    collection.select(
      (collection.selectedIndex - 1).clamp(
        0,
        collection.visibleGames.length - 1,
      ),
    );
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  void goToGame(int index) => unawaited(selectGame(index));

  /// Select through the owner and await cached-analysis restoration before a
  /// caller decides whether this game needs another engine pass.
  Future<bool> selectGame(int index) async {
    if (isDisposed ||
        !isActive() ||
        index < 0 ||
        index >= collection.visibleGames.length) {
      return false;
    }
    rememberCurrentPlace();
    final source = collection.games;
    final game = collection.visibleGames[index];
    pgnInitialFen = null;
    collection.select(index);
    final selection = collection.selectionRevision;
    notifyListeners();
    if (selection != collection.selectionRevision ||
        !identical(source, collection.games) ||
        collection.visibleGames.isEmpty ||
        !identical(collection.visibleGames[collection.selectedIndex], game)) {
      return false;
    }
    final request = _selectionEpoch + 1;
    final pending = loadCurrentGame();
    await pending;
    return !isDisposed &&
        isActive() &&
        request == _selectionEpoch &&
        selection == collection.selectionRevision &&
        identical(source, collection.games) &&
        collection.visibleGames.isNotEmpty &&
        identical(collection.visibleGames[collection.selectedIndex], game);
  }

  void toggleAutoPlay() {
    if (solitaire.isActive) return;
    playback.toggle();
    onReclaimFocus?.call();
  }

  void onPositionChanged(Position pos) {
    currentPosition = pos;
    notifyListeners();
  }

  void toggleOpeningTree() {
    if (solitaire.isActive) solitaire.stop();
    solitaire.cancelSetup();
    if (tree.showOpeningTree) {
      tree.toggle();
      pgnInitialFen = _gameCursorFen;
      final restored = _tryParseFen(_gameCursorFen);
      if (restored != null) currentPosition = restored;
      notifyListeners();
      return;
    }
    _gameCursorFen = currentPosition.fen;
    tree.toggle();
  }

  // An explicit reader belongs to the visible reference pane (or fullscreen
  // game). Otherwise navigation follows the current game/tree/Solitaire mode.
  // Capture it at the command, never retain a second active-reader state.

  // Solitaire allows browsing the revealed region: the PGN widget caps all
  // mainline navigation at the revealed frontier, so back/forward/home/end
  // can delegate to it directly. clearEphemeralMoves is skipped there — it
  // would wipe the wrong-attempt variations recorded during play.
  //
  // Solitaire is checked before the tree throughout: entering solitaire
  // leaves the tree, but a stale tree flag must never win over a session.

  void navigateBack({PgnViewerHandle? reader}) {
    playback.stop();
    if (reader != null) {
      reader.goBack();
    } else if (!solitaire.isActive && tree.showOpeningTree) {
      tree.goBack();
    } else {
      handle.goBack();
    }
  }

  void navigateForward({PgnViewerHandle? reader}) {
    playback.stop();
    if (reader != null) {
      reader.goForward();
    } else if (!solitaire.isActive && tree.showOpeningTree) {
      tree.goForward();
    } else {
      handle.goForward();
    }
  }

  void navigateToStart({PgnViewerHandle? reader}) {
    playback.stop();
    if (reader != null) {
      reader.goToMainLineIndex(0);
    } else if (solitaire.isActive) {
      handle.goToMainLineIndex(0);
    } else if (tree.showOpeningTree) {
      tree.resetToStart();
    } else {
      handle.clearEphemeralMoves();
      handle.jumpToMove(1, true);
    }
  }

  /// Park the cursor on a mainline position by half-move index. Out-of-range
  /// values clamp to the game, so a moment computed from a longer copy of the
  /// game still lands somewhere in it.
  void goToPly(int ply) {
    playback.stop();
    if (solitaire.isActive || tree.showOpeningTree) return;
    final len = handle.mainLineLength;
    handle.clearEphemeralMoves();
    handle.goToMainLineIndex(ply.clamp(0, len < 0 ? 0 : len));
  }

  void navigateToEnd({PgnViewerHandle? reader}) {
    playback.stop();
    if (reader != null) {
      reader.goToMainLineIndex(reader.mainLineLength);
    } else if (solitaire.isActive) {
      // Back to the guessing frontier (the widget caps at revealedPly).
      handle.goToMainLineIndex(solitaire.controller.revealedPly);
    } else if (tree.showOpeningTree) {
      tree.goToEnd();
    } else {
      final len = handle.mainLineLength;
      if (len > 0) {
        final moveNum = (len + 1) ~/ 2;
        final isWhite = len % 2 == 1;
        handle.jumpToMove(moveNum, isWhite);
      }
    }
  }

  /// Handle a board move in the current mode context.
  void onBoardMove(String san, {PgnViewerHandle? reader}) {
    playback.stop();
    if (reader != null) {
      reader.addEphemeralMove(san);
    } else if (tree.showOpeningTree) {
      tree.onMoveSelected(san);
    } else if (solitaire.isActive) {
      solitaire.handleBoardMove(san);
    } else {
      handle.addEphemeralMove(san);
    }
  }

  void loadGameFromTree(int filteredIndex) {
    if (filteredIndex < 0 || filteredIndex >= collection.visibleGames.length) {
      return;
    }
    rememberCurrentPlace();
    tree.snapshotCursor(leavingForGame: true);
    final landingFen = tree.openingTree?.currentFen;
    pgnInitialFen = landingFen;
    _gameCursorFen = landingFen;
    tree.hide();
    collection.select(filteredIndex);
    currentPosition = _tryParseFen(landingFen) ?? Chess.initial;
    notifyListeners();
    unawaited(loadCurrentGame());
  }

  /// True when a tree position saved by [loadGameFromTree] can be returned to.

  /// Re-open the opening tree at the position explored before the last
  /// [loadGameFromTree], restoring the tree cursor and the board.
  Future<void> returnToTreePosition() {
    _gameCursorFen = currentPosition.fen;
    return tree.restoreSavedPosition();
  }

  Position? _tryParseFen(String? fen) {
    if (fen == null || fen.isEmpty) return null;
    return tryParseFen(fen);
  }

  void onEngineLineMoveTapped(List<String> sanMoves, int clickedIndex) {
    if (sanMoves.isEmpty || clickedIndex < 0) return;
    playback.stop();

    for (final san in sanMoves) {
      handle.addEphemeralMove(san);
    }

    final stepsBack = sanMoves.length - 1 - clickedIndex;
    for (int i = 0; i < stepsBack; i++) {
      handle.goBack();
    }

    notifyListeners();
    onReclaimFocus?.call();
  }
}
