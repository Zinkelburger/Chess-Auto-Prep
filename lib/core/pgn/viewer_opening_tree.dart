/// Opening-tree mode for the PGN viewer, extracted from `PgnViewerController`.
///
/// Owns the tree state (build progress, current cursor, position cache) and the
/// tree-mode navigation logic, driving the board through injected callbacks.
/// `PgnViewerController` keeps its public tree getters/methods and delegates
/// here, so existing call-sites are unchanged.
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

import '../../constants/engine_defaults.dart';
import '../../models/opening_tree.dart';
import '../../services/opening_tree_builder.dart';
import '../../services/pgn_parsing_service.dart' as pgn;
import '../../utils/fen_utils.dart';
import '../../models/pgn_game_entry.dart';

class ViewerOpeningTree {
  ViewerOpeningTree({
    required this.isActive,
    required this.onChanged,
    required this.filteredGames,
    required this.allGames,
    required this.fenIndex,
    required this.currentFen,
    required this.applyPosition,
    this.onReclaimFocus,
  });

  /// Whether the owning view is still mounted/active.
  final bool Function() isActive;

  /// Notify listeners (the controller's `notifyListeners`).
  final VoidCallback onChanged;

  /// Current filtered/sorted games (the tree is built from these).
  final List<PgnGameEntry> Function() filteredGames;

  /// All loaded games (for FEN-index → filtered-index mapping).
  final List<PgnGameEntry> Function() allGames;

  /// Precomputed FEN → allGames-indices map, or null while building.
  final Map<String, List<int>>? Function() fenIndex;

  /// Current board FEN (used as a sync fallback on first open).
  final String Function() currentFen;

  /// Push a board position derived from the tree cursor.
  final void Function(Position) applyPosition;

  /// Optional: reclaim keyboard focus after toggling the tree.
  final VoidCallback? onReclaimFocus;

  bool showOpeningTree = false;
  OpeningTree? openingTree;
  bool buildingTree = false;
  int treeBuildProcessed = 0;
  int treeBuildTotal = 0;
  int _generation = 0;
  List<String> treeCurrentMoveSequence = [];

  /// Tree cursor saved when leaving the tree (toggle off, or opening a game
  /// from the games-at-position list). Re-entering walks this sequence instead
  /// of syncing from the remounted game, which would jump to the start.
  List<String>? _savedMoveSequence;

  /// True when the last leave was a click on a game at this position. The
  /// app-bar back button is only offered in that case; T always restores.
  bool _leftForGame = false;

  static const _maxCacheEntries = 500;
  final Map<String, List<int>> _positionGameCache = {};

  /// Reset tree state when a new file is loaded.
  void resetForNewFile() {
    openingTree = null;
    showOpeningTree = false;
    treeCurrentMoveSequence = [];
    _savedMoveSequence = null;
    _leftForGame = false;
  }

  /// Drop the built tree (e.g. after re-slicing); a rebuild follows if shown.
  /// The saved return position is dropped too — it belongs to the old slice.
  void clearTree() {
    openingTree = null;
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
    if (openingTree == null) return;
    _savedMoveSequence = List.of(treeCurrentMoveSequence);
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
    showOpeningTree = true;
    _leftForGame = false;
    onChanged();
    if (openingTree == null) {
      if (filteredGames().isNotEmpty) await rebuild();
      onReclaimFocus?.call();
      return;
    }
    _restoreCursorOntoBoard(preferSaved: true);
    onChanged();
    onReclaimFocus?.call();
  }

  Future<void> rebuild() async {
    final generation = ++_generation;
    if (filteredGames().isEmpty) {
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
    treeBuildTotal = filteredGames().length;
    _positionGameCache.clear();
    onChanged();

    try {
      final tree = await OpeningTreeBuilder.buildTree(
        pgnList: filteredGames().map((g) => g.pgnText).toList(),
        username: '',
        userIsWhite: null,
        strictPlayerMatching: false,
        maxDepth: kOpeningTreeMaxDepth,
        onProgress: (processed, total) {
          if (!isActive() || generation != _generation) return;
          treeBuildProcessed = processed;
          treeBuildTotal = total;
          onChanged();
        },
      );
      if (!isActive() || generation != _generation) return;
      openingTree = tree;
      buildingTree = false;
      treeBuildProcessed = treeBuildTotal;
      _restoreCursorOntoBoard(preferSaved: false);
      onChanged();
    } catch (e) {
      if (!isActive() || generation != _generation) return;
      buildingTree = false;
      openingTree = null;
      treeBuildProcessed = 0;
      treeBuildTotal = 0;
      onChanged();
      debugPrint('Failed to build opening tree: $e');
    }
  }

  void onMoveSelected(String move) {
    if (openingTree == null) return;
    if (openingTree!.makeMove(move)) {
      treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
      _updatePositionFromTree();
    }
    onChanged();
  }

  void goBack() {
    if (openingTree == null) return;
    openingTree!.goBack();
    treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
    _updatePositionFromTree();
    onChanged();
  }

  void goForward() {
    if (openingTree == null) return;
    final moves = openingTree!.currentGroup.children;
    if (moves.isNotEmpty) {
      onMoveSelected(moves.first.move);
    }
  }

  void resetToStart() {
    openingTree?.reset();
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
      final moves = tree.currentGroup.children;
      if (moves.isEmpty || !tree.makeMove(moves.first.move)) break;
    }
    treeCurrentMoveSequence = tree.currentNode.getMovePath();
    _updatePositionFromTree();
    onChanged();
  }

  /// Put the tree (and board) back on a SAN cursor. [preferSaved] is true when
  /// re-entering the tree (the snapshot is the place we left). Rebuilds while
  /// the tree is already shown walk the live cursor instead — a stale snapshot
  /// from the last hide must not yank the user back mid-exploration.
  void _restoreCursorOntoBoard({required bool preferSaved}) {
    final saved = _savedMoveSequence;
    final seq = (preferSaved && saved != null && saved.isNotEmpty)
        ? saved
        : treeCurrentMoveSequence;
    if (seq.isNotEmpty) {
      _walkTo(seq);
      _updatePositionFromTree();
      return;
    }
    _syncToCurrentPosition();
  }

  void _walkTo(List<String> seq) {
    final tree = openingTree;
    if (tree == null) return;
    tree.reset();
    for (final move in seq) {
      if (!tree.makeMove(move)) break;
    }
    treeCurrentMoveSequence = tree.currentNode.getMovePath();
  }

  /// Sync the opening tree cursor to the current board position via FEN
  /// lookup in the aggregate tree. Used on first open, when there is no
  /// saved tree cursor to restore.
  void _syncToCurrentPosition() {
    if (openingTree == null) return;
    openingTree!.reset();
    if (openingTree!.navigateToFen(currentFen())) {
      treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
    } else {
      openingTree!.reset();
      treeCurrentMoveSequence = [];
    }
  }

  /// Update the board position from the tree's current node FEN.
  void _updatePositionFromTree() {
    if (openingTree == null) return;
    final fen = openingTree!.currentNode.fen;
    try {
      applyPosition(Chess.fromSetup(Setup.parseFen(fen)));
    } catch (_) {
      // FEN may be invalid in rare cases; ignore.
    }
  }

  List<int> gamesAtTreePosition() {
    if (openingTree == null) return [];
    final fen = normalizeFen(openingTree!.currentNode.fen);
    return _positionGameCache.putIfAbsent(fen, () {
      if (_positionGameCache.length >= _maxCacheEntries) {
        final keysToRemove = _positionGameCache.keys
            .take(_maxCacheEntries ~/ 4)
            .toList();
        for (final k in keysToRemove) {
          _positionGameCache.remove(k);
        }
      }

      final filtered = filteredGames();

      // Fast path: map FEN-index (allGames indices) → filteredGames indices.
      final fenIndexValue = fenIndex();
      if (fenIndexValue != null) {
        final allIndices = fenIndexValue[fen] ?? const [];
        if (allIndices.isEmpty) return <int>[];
        final all = allGames();
        final entryToFiltered = <PgnGameEntry, int>{};
        for (int fi = 0; fi < filtered.length; fi++) {
          entryToFiltered[filtered[fi]] = fi;
        }
        final results = <int>[];
        for (final ai in allIndices) {
          // A persisted `.fenidx` can be stale relative to the current
          // `allGames` (e.g. reloaded across an edit that changed the game
          // set), leaving indices that are out of range. Skip those rather
          // than throwing a RangeError that crashes the tree panel.
          if (ai < 0 || ai >= all.length) continue;
          final fi = entryToFiltered[all[ai]];
          if (fi != null) results.add(fi);
        }
        return results;
      }

      final results = <int>[];
      for (int i = 0; i < filtered.length; i++) {
        if (pgn.gamePassesThroughFen(
          filtered[i].headers,
          filtered[i].pgnText,
          fen,
        )) {
          results.add(i);
        }
      }
      return results;
    });
  }
}
