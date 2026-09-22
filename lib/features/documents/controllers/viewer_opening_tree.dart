/// Owns Viewer opening-tree construction, progress, cursor and position cache.
/// Navigation drives the board through injected callbacks.
///
/// Cursor ownership: the merged opening tree is its own exploration surface,
/// not the current game's move list. Re-entering (T, or app-bar back after a
/// games-at-position click) restores this cursor onto the board. Syncing from
/// the remounted game would jump to the starting position, because showing the
/// tree unmounts [PgnViewerWidget].
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../repositories/viewer_opening_repository.dart';
import 'viewer_collection_controller.dart';
import '../repositories/viewer_computation.dart';
import '../../../models/opening_tree.dart';
import '../../../models/pgn_game_entry.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_position_replay.dart' as pgn;
import '../../../utils/chess_utils.dart'
    show recentMoveTrailSquares, tryParseFen;
import '../../../utils/fen_utils.dart';

class ViewerOpeningTree {
  ViewerOpeningTree({
    required this.repository,
    required this.isActive,
    required this.onChanged,
    required this.collection,
    required this.fenIndex,
    required this.currentFen,
    required this.applyPosition,
    this.onReclaimFocus,
  });

  final ViewerOpeningRepository repository;
  ViewerComputation<ViewerOpeningResult>? _task;
  bool _disposed = false;
  bool get _active => !_disposed && isActive();

  /// Whether the owning view is still mounted/active.
  final bool Function() isActive;

  /// Notify listeners (the controller's `notifyListeners`).
  final VoidCallback onChanged;

  final ViewerCollectionController collection;

  /// Precomputed FEN → allGames-indices map, or null while building.
  final Map<String, List<int>>? Function() fenIndex;

  /// Current board FEN (used as a sync fallback on first open).
  final String Function() currentFen;

  /// Push a board position derived from the tree cursor.
  final void Function(Position) applyPosition;

  /// Optional: reclaim keyboard focus after toggling the tree.
  final VoidCallback? onReclaimFocus;

  bool showOpeningTree = false;
  bool includeVariations = false;

  void setIncludeVariations(bool value) {
    if (includeVariations == value) return;
    includeVariations = value;
    clearTree();
    clearCache();
    unawaited(rebuild());
  }

  OpeningTree? openingTree;
  bool buildingTree = false;
  int treeBuildProcessed = 0;
  int treeBuildTotal = 0;
  int _generation = 0;
  List<String> treeCurrentMoveSequence = [];

  /// Only the move that produced the tree's current board. Replay the walked
  /// path, since a transposition's stored parent can describe another move.
  Set<String> get recentMoveSquares {
    final tree = openingTree;
    final root = tree == null ? null : tryParseFen(tree.cursorRoot.fen);
    if (tree == null || root == null) return const {};
    return recentMoveTrailSquares(root, tree.currentMovePath);
  }

  /// Tree cursor saved when leaving the tree (toggle off, or opening a game
  /// from the games-at-position list). Re-entering walks this sequence instead
  /// of syncing from the remounted game, which would jump to the start.
  List<String>? _savedMoveSequence;
  String? _cursorStartFen;

  /// True when the last leave was a click on a game at this position. The
  /// app-bar back button is only offered in that case; T always restores.
  bool _leftForGame = false;

  static const _maxCacheEntries = 500;
  final Map<String, List<int>> _positionGameCache = {};
  Map<String, List<int>>? _mainlineIndex;
  List<PgnGameEntry> _indexedGames = const [];

  /// Stop a pending build without discarding the currently displayed tree.
  void cancelBuild() {
    _generation++;
    _task?.cancel();
    _task = null;
    buildingTree = false;
  }

  /// Reset tree state when a new file is loaded.
  void resetForNewFile() {
    cancelBuild();
    _mainlineIndex = null;
    _indexedGames = const [];
    buildingTree = false;
    openingTree = null;
    showOpeningTree = false;
    treeCurrentMoveSequence = [];
    _savedMoveSequence = null;
    _leftForGame = false;
    _cursorStartFen = null;
    clearCache();
  }

  /// Drop the built tree (e.g. after re-slicing); a rebuild follows if shown.
  /// The saved return position is dropped too — it belongs to the old slice.
  void clearTree() {
    cancelBuild();
    _mainlineIndex = null;
    _indexedGames = const [];
    _cursorStartFen = openingTree?.cursorRoot.fen ?? _cursorStartFen;
    openingTree = null;
    buildingTree = false;
    clearCache();
    _savedMoveSequence = null;
    _leftForGame = false;
  }

  /// Whether the app-bar can offer "back to the tree" after a game click.
  bool get hasSavedPosition => _leftForGame && _savedMoveSequence != null;

  /// Remember the current tree cursor before leaving the tree.
  ///
  /// [leavingForGame] marks a games-at-position click so the app-bar back
  /// button appears while that game is on screen.
  void snapshotCursor({bool leavingForGame = false}) {
    final tree = openingTree;
    if (tree == null) return;
    _savedMoveSequence = tree.currentMovePath;
    _cursorStartFen = tree.cursorRoot.fen;
    if (leavingForGame) _leftForGame = true;
  }

  void clearSavedPosition() {
    _savedMoveSequence = null;
    _leftForGame = false;
  }

  /// Re-open the tree at the position saved by [snapshotCursor], restoring
  /// both the tree cursor and the board. Rebuilds the tree first if needed.
  Future<void> restoreSavedPosition() => enter();

  /// Hide the tree without notifying (the caller drives the follow-up reload).
  void hide() => showOpeningTree = false;

  /// Clear the cached FEN → game-index lookups (after a sort/order change).
  void clearCache() => _positionGameCache.clear();

  void toggle() {
    if (showOpeningTree) {
      snapshotCursor();
      showOpeningTree = false;
      onChanged();
      onReclaimFocus?.call();
      return;
    }
    unawaited(enter());
  }

  /// Show the tree and put the board on the saved tree cursor (or, on first
  /// open, on the current game FEN).
  Future<void> enter() async {
    if (!_active) return;
    showOpeningTree = true;
    _leftForGame = false;
    onChanged();
    if (openingTree == null) {
      if (collection.visibleGames.isNotEmpty) await rebuild();
      if (_active && showOpeningTree) onReclaimFocus?.call();
      return;
    }
    _restoreCursorOntoBoard(preferSaved: true);
    _savedMoveSequence = null;
    onChanged();
    onReclaimFocus?.call();
  }

  Future<void> rebuild() async {
    if (!_active) return;
    _task?.cancel();
    final generation = ++_generation;
    final boardFen = currentFen();
    _cursorStartFen = openingTree?.cursorRoot.fen ?? _cursorStartFen;
    if (collection.visibleGames.isEmpty) {
      openingTree = null;
      buildingTree = false;
      treeBuildProcessed = 0;
      treeBuildTotal = 0;
      _positionGameCache.clear();
      onChanged();
      return;
    }
    buildingTree = true;
    treeBuildProcessed = 0;
    treeBuildTotal = collection.visibleGames.length;
    _positionGameCache.clear();
    onChanged();

    try {
      final games = List<PgnGameEntry>.of(collection.visibleGames);
      final variations = includeVariations;
      final task = _task = repository.buildTree(
        [
          for (final game in games)
            (
              headers: Map<String, String>.unmodifiable(game.headers),
              pgnText: game.pgnText,
            ),
        ],
        includeVariations: variations,
        onProgress: (processed, total) {
          if (!_active || generation != _generation) return;
          treeBuildProcessed = processed;
          treeBuildTotal = total;
          onChanged();
        },
      );
      final result = await task.result;
      if (!_active || generation != _generation) return;
      final tree = result.tree;
      final mainlineIndex = result.mainlineIndex;
      _mainlineIndex = mainlineIndex;
      _indexedGames = games;
      openingTree = tree;
      buildingTree = false;
      treeBuildProcessed = treeBuildTotal;
      if (showOpeningTree) {
        _restoreCursorOntoBoard(preferSaved: true, fallbackFen: boardFen);
        _savedMoveSequence = null;
      }
      onChanged();
    } catch (e) {
      if (!_active || generation != _generation) return;
      buildingTree = false;
      openingTree = null;
      treeBuildProcessed = 0;
      treeBuildTotal = 0;
      onChanged();
      debugPrint('Failed to build opening tree: $e');
    }
  }

  void onMoveSelected(String move) {
    final tree = openingTree;
    if (tree == null) return;
    if (tree.makeMove(move)) {
      treeCurrentMoveSequence = tree.currentMovePath;
      _updatePositionFromTree();
    }
    onChanged();
  }

  void goBack() {
    final tree = openingTree;
    if (tree == null) return;
    tree.goBack();
    treeCurrentMoveSequence = tree.currentMovePath;
    _updatePositionFromTree();
    onChanged();
  }

  void goForward() {
    final moves = openingTree?.continuations;
    if (moves == null || moves.isEmpty) return;
    onMoveSelected(moves.first.move);
  }

  void resetToStart() {
    openingTree?.reset(startFen: openingTree?.cursorRoot.fen);
    treeCurrentMoveSequence = [];
    _updatePositionFromTree();
    onChanged();
  }

  void goToEnd() {
    final tree = openingTree;
    if (tree == null) return;
    // Follow the most-played continuation (merged across transpositions).
    // Transposition jumps can revisit positions (move repetitions), so track
    // visited nodes to guarantee termination.
    final visited = <OpeningTreeNode>{};
    while (visited.add(tree.currentNode)) {
      final moves = tree.continuations;
      if (moves.isEmpty || !tree.makeMove(moves.first.move)) break;
    }
    treeCurrentMoveSequence = tree.currentMovePath;
    _updatePositionFromTree();
    onChanged();
  }

  /// Put the tree (and board) back on a SAN cursor. [preferSaved] is true when
  /// re-entering the tree (the snapshot is the place we left). Rebuilds while
  /// the tree is already shown walk the live cursor instead — a stale snapshot
  /// from the last hide must not yank the user back mid-exploration.
  void _restoreCursorOntoBoard({
    required bool preferSaved,
    String? fallbackFen,
  }) {
    final saved = _savedMoveSequence;
    final seq = preferSaved && saved != null ? saved : treeCurrentMoveSequence;
    if ((preferSaved && saved != null) || seq.isNotEmpty) {
      _walkTo(seq);
      _updatePositionFromTree();
      return;
    }
    _syncToCurrentPosition(fallbackFen);
  }

  void _walkTo(List<String> seq) {
    final tree = openingTree;
    if (tree == null) return;
    final start = _cursorStartFen;
    if (start != null && !tree.fenToNodes.containsKey(normalizeFen(start))) {
      _syncToCurrentPosition(null);
      return;
    }
    tree.syncToMoveHistory(seq, startFen: start);
    treeCurrentMoveSequence = tree.currentMovePath;
  }

  /// Sync the opening tree cursor to the current board position via FEN
  /// lookup in the aggregate tree. Used on first open, when there is no
  /// saved tree cursor to restore.
  void _syncToCurrentPosition(String? fallbackFen) {
    final tree = openingTree;
    if (tree == null) return;
    tree.reset();
    if (!tree.navigateToFen(fallbackFen ?? currentFen())) {
      final start = collection.selectedGame?.headers['FEN'];
      if (start == null || !tree.navigateToFen(start)) tree.reset();
    }
    treeCurrentMoveSequence = tree.currentMovePath;
    // A missing variation falls back to the root. The board must follow that
    // fallback too, rather than retaining the hidden Game pane's position.
    _updatePositionFromTree();
  }

  /// Update the board position from the tree's current FEN (off-book
  /// cursor included).
  void _updatePositionFromTree() {
    final tree = openingTree;
    if (tree == null) return;
    _cursorStartFen = tree.cursorRoot.fen;
    final position = tryParseFen(tree.currentFen);
    // An unparsable cursor FEN (rare, from a malformed game) leaves the board
    // where it was rather than failing the navigation.
    if (position != null) applyPosition(position);
  }

  /// Indices into the filtered games of every game that reaches the tree
  /// cursor's position, cached per position until the games change.
  List<int> gamesAtTreePosition() {
    final tree = openingTree;
    if (tree == null) return [];
    final fen = normalizeFen(tree.currentFen);
    return _positionGameCache.putIfAbsent(fen, () {
      _trimPositionCache();
      final filtered = collection.visibleGames;
      final mainlineIndex = _mainlineIndex;
      if (!includeVariations && mainlineIndex != null) {
        return _filteredIndicesOf(filtered, {
          for (final i in mainlineIndex[fen] ?? const <int>[]) _indexedGames[i],
        });
      }
      final fenIndexValue = fenIndex();
      if (includeVariations && fenIndexValue != null) {
        return _filteredIndicesFromFenIndex(
          filtered,
          fenIndexValue[fen] ?? const [],
        );
      }
      return [
        for (final (i, game) in filtered.indexed)
          if (pgn.gamePassesThroughFen(
            game.headers,
            game.pgnText,
            fen,
            includeVariations: includeVariations,
          ))
            i,
      ];
    });
  }

  /// Drop the oldest quarter of the cache once it is full.
  void _trimPositionCache() {
    if (_positionGameCache.length < _maxCacheEntries) return;
    final oldest = _positionGameCache.keys.take(_maxCacheEntries ~/ 4).toList();
    for (final key in oldest) {
      _positionGameCache.remove(key);
    }
  }

  static List<int> _filteredIndicesOf(
    List<PgnGameEntry> filtered,
    Set<PgnGameEntry> matching,
  ) => [
    for (final (i, game) in filtered.indexed)
      if (matching.contains(game)) i,
  ];

  /// Map FEN-index hits (indices into all games) onto filtered-list indices,
  /// keeping the hit order.
  List<int> _filteredIndicesFromFenIndex(
    List<PgnGameEntry> filtered,
    List<int> allIndices,
  ) {
    if (allIndices.isEmpty) return const [];
    final all = collection.games;
    final entryToFiltered = {for (final (i, game) in filtered.indexed) game: i};
    return [
      for (final ai in allIndices)
        // A persisted `.fenidx` can be stale relative to the current games
        // (reloaded across an edit that changed the game set), leaving
        // indices out of range. Skip those rather than crash the tree panel.
        if (ai >= 0 && ai < all.length) ?entryToFiltered[all[ai]],
    ];
  }

  void dispose() {
    _disposed = true;
    cancelBuild();
  }
}
