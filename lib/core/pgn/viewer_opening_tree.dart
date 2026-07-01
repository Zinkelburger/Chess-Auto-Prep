/// Opening-tree mode for the PGN viewer, extracted from `PgnViewerController`
/// (MAINTAINABILITY_PLAN WS-C / runbook A2).
///
/// Owns the tree state (build progress, current cursor, position cache) and the
/// tree-mode navigation logic, driving the board through injected callbacks.
/// `PgnViewerController` keeps its public tree getters/methods and delegates
/// here, so existing call-sites are unchanged.
library;

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
    required this.mainLineIndex,
    required this.mainLineLength,
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

  /// Board mainline cursor index / length (to sync the tree to the board).
  final int Function() mainLineIndex;
  final int Function() mainLineLength;

  /// Current board FEN (used as a sync fallback).
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

  static const _maxCacheEntries = 500;
  final Map<String, List<int>> _positionGameCache = {};

  /// Reset tree state when a new file is loaded.
  void resetForNewFile() {
    openingTree = null;
    showOpeningTree = false;
    treeCurrentMoveSequence = [];
  }

  /// Drop the built tree (e.g. after re-slicing); a rebuild follows if shown.
  void clearTree() => openingTree = null;

  /// Hide the tree without notifying (the caller drives the follow-up reload).
  void hide() => showOpeningTree = false;

  /// Clear the cached FEN → game-index lookups (after a sort/order change).
  void clearCache() => _positionGameCache.clear();

  void toggle() {
    showOpeningTree = !showOpeningTree;
    onChanged();
    if (showOpeningTree && openingTree == null && filteredGames().isNotEmpty) {
      rebuild();
    } else if (showOpeningTree && openingTree != null) {
      _syncToCurrentPosition();
    }
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
      _syncToCurrentPosition();
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
    final children = openingTree!.currentNode.sortedChildren;
    if (children.isNotEmpty) {
      onMoveSelected(children.first.move);
    }
  }

  void resetToStart() {
    openingTree?.reset();
    treeCurrentMoveSequence = [];
    _updatePositionFromTree();
    onChanged();
  }

  void goToEnd() {
    while (openingTree != null &&
        openingTree!.currentNode.sortedChildren.isNotEmpty) {
      openingTree!.makeMove(openingTree!.currentNode.sortedChildren.first.move);
    }
    if (openingTree != null) {
      treeCurrentMoveSequence = openingTree!.currentNode.getMovePath();
      _updatePositionFromTree();
      onChanged();
    }
  }

  /// Sync the opening tree cursor to the current board position via FEN
  /// lookup in the aggregate tree.
  void _syncToCurrentPosition() {
    if (openingTree == null) return;
    openingTree!.reset();
    if (mainLineLength() == 0) {
      treeCurrentMoveSequence = [];
      return;
    }
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
        final keysToRemove =
            _positionGameCache.keys.take(_maxCacheEntries ~/ 4).toList();
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
            filtered[i].headers, filtered[i].pgnText, fen)) {
          results.add(i);
        }
      }
      return results;
    });
  }
}
