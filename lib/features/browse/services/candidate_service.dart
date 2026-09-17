/// Produces candidate move lists for browse mode.
///
/// Merges [BuildTree] children with Lichess Explorer data when the tree is
/// missing or sparse at a position. Uses [CoverageService] for Explorer API
/// access (shared client and cache).
library;

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../models/build_tree_node.dart';
import '../../../models/explorer_response.dart';
import '../../../services/explorer_cache_service.dart';
import '../../../services/generation/fen_map.dart';
import '../../coverage/services/coverage_service.dart';

/// A single candidate move at the current position.
///
/// Tree fields ([evalCp], [ease], [expectimax], [treeNode], ...) come from the
/// build tree; `db*` fields from the games database (the tree's own counts,
/// or the Explorer when it was consulted). [evalSource] says which supplied
/// the row: `'tree'` or `'db'`.
@immutable
class CandidateMove {
  const CandidateMove({
    required this.san,
    required this.uci,
    this.evalCp,
    this.ease,
    this.myEase,
    this.expectimax,
    this.subtreeTrapCount,
    this.isRepertoireMove,
    this.dbGames,
    this.dbFrequency,
    this.dbWhiteWin,
    this.dbDraw,
    this.dbBlackWin,
    this.inRepertoire = false,
    this.coverageDelta,
    this.evalSource,
    this.treeNode,
    this.ply = 0,
  });

  final String san;
  final String uci;

  final int? evalCp;
  final double? ease;
  final double? myEase;
  final double? expectimax;
  final int? subtreeTrapCount;
  final bool? isRepertoireMove;

  final int? dbGames;
  final double? dbFrequency;
  final double? dbWhiteWin;
  final double? dbDraw;
  final double? dbBlackWin;

  final bool inRepertoire;
  final double? coverageDelta;
  final String? evalSource;

  final BuildTreeNode? treeNode;
  final int ply;

  bool get hasDbData => dbGames != null;

  /// The same move with the games-database fields of [db] when it has
  /// games, keeping this row's own numbers where the Explorer has none.
  CandidateMove withExplorerStats(ExplorerMove db) {
    final total = db.total;
    final hasGames = total > 0;
    return CandidateMove(
      san: san,
      uci: uci.isNotEmpty ? uci : db.uci,
      evalCp: evalCp,
      ease: ease,
      myEase: myEase,
      expectimax: expectimax,
      subtreeTrapCount: subtreeTrapCount,
      isRepertoireMove: isRepertoireMove,
      dbGames: hasGames ? total : dbGames,
      dbFrequency: hasGames ? db.playFraction : dbFrequency,
      dbWhiteWin: hasGames ? db.white / total : dbWhiteWin,
      dbDraw: hasGames ? db.draws / total : dbDraw,
      dbBlackWin: hasGames ? db.black / total : dbBlackWin,
      inRepertoire: inRepertoire,
      coverageDelta: coverageDelta,
      evalSource: evalSource,
      treeNode: treeNode,
      ply: ply,
    );
  }
}

/// Merges BuildTree and Lichess Explorer into sorted browse candidates.
class CandidateService {
  const CandidateService({
    this.tree,
    this.fenMap,
    this.openingTree,
    this.coverage,
    this.coverageService,
    this.explorerCache,
    this.explorerSource,
  });

  final BuildTree? tree;
  final FenMap? fenMap;
  final OpeningGraph? openingTree;
  final CoverageResult? coverage;
  final CoverageService? coverageService;

  /// Live Explorer stats source. When provided (with [explorerSource]) it is
  /// preferred over [coverageService], whose fetch path is mothballed.
  final ExplorerCacheService? explorerCache;
  final ExplorerSourceConfig? explorerSource;

  /// Returns sorted candidates, merging tree data with Lichess Explorer when
  /// the tree is missing or sparse at [fen].
  Future<List<CandidateMove>> getCandidates({
    required String fen,
    required bool isOurTurn,
    required bool playAsWhite,
    List<String> pathFromRoot = const [],
    int? maxCandidates,
  }) async {
    final treeCandidates = getTreeCandidates(
      fen: fen,
      isOurTurn: isOurTurn,
      playAsWhite: playAsWhite,
      pathFromRoot: pathFromRoot,
    );

    final explorer = _needsExplorer(treeCandidates)
        ? await _fetchExplorer(fen)
        : null;

    return mergeWithExplorer(
      treeCandidates: treeCandidates,
      explorer: explorer,
      isOurTurn: isOurTurn,
      openingTree: openingTree,
      coverage: coverage,
      pathFromRoot: pathFromRoot,
      maxCandidates: maxCandidates,
    );
  }

  /// Get candidates at a FEN from the BuildTree only (sync, no network).
  List<CandidateMove> getTreeCandidates({
    required String fen,
    required bool isOurTurn,
    required bool playAsWhite,
    List<String> pathFromRoot = const [],
  }) {
    if (tree == null) return [];
    final node = _findNode(fen);
    if (node == null) return [];
    final candidates = [
      for (final child in node.children)
        _candidateFromTreeNode(
          child,
          playAsWhite: playAsWhite,
          pathFromRoot: pathFromRoot,
        ),
    ];
    return sortCandidates(candidates, isOurTurn: isOurTurn);
  }

  CandidateMove _candidateFromTreeNode(
    BuildTreeNode child, {
    required bool playAsWhite,
    required List<String> pathFromRoot,
  }) => CandidateMove(
    san: child.moveSan,
    uci: child.moveUci,
    evalCp: child.hasEngineEval ? child.evalForUs(playAsWhite) : null,
    ease: child.ease,
    myEase: child.myEase >= 0 ? child.myEase : null,
    expectimax: child.hasExpectimax ? child.expectimaxValue : null,
    // TODO(audit): a leaf child's own trapScore is not counted, while a
    // child with children counts itself; decide whether "subtree" includes
    // the move itself and make both cases agree.
    subtreeTrapCount: child.children.isEmpty ? 0 : _countTraps(child),
    isRepertoireMove: child.isRepertoireMove,
    inRepertoire:
        openingTree?.hasMoveOnPath(pathFromRoot, child.moveSan) ?? false,
    coverageDelta: coverageDeltaForMove(coverage, pathFromRoot, child.moveSan),
    evalSource: 'tree',
    treeNode: child,
    ply: child.ply,
    dbGames: child.totalGames > 0 ? child.totalGames : null,
    dbFrequency: child.moveProbability > 0 ? child.moveProbability : null,
  );

  /// Whether the tree says too little at this position for the Explorer to
  /// be worth asking: no tree, no candidates, or none with game counts.
  bool _needsExplorer(List<CandidateMove> treeCandidates) =>
      tree == null ||
      treeCandidates.isEmpty ||
      treeCandidates.every((c) => !c.hasDbData);

  Future<ExplorerResponse?> _fetchExplorer(String fen) async {
    final cache = explorerCache;
    final source = explorerSource;
    if (cache != null && source != null) return cache.fetch(fen, source);
    final data = await coverageService?.getPositionData(fen);
    return data == null ? null : ExplorerResponse.fromJson(data, fen: fen);
  }

  /// Merge tree candidates with Explorer moves; testable without HTTP.
  @visibleForTesting
  static List<CandidateMove> mergeWithExplorer({
    required List<CandidateMove> treeCandidates,
    required ExplorerResponse? explorer,
    required bool isOurTurn,
    required OpeningGraph? openingTree,
    required CoverageResult? coverage,
    required List<String> pathFromRoot,
    int? maxCandidates,
  }) {
    if (explorer == null || explorer.moves.isEmpty) {
      return _limitCandidates(
        sortCandidates(treeCandidates, isOurTurn: isOurTurn),
        maxCandidates,
      );
    }

    final explorerBySan = {for (final move in explorer.moves) move.san: move};
    final treeSans = {for (final move in treeCandidates) move.san};
    final merged = [
      for (final treeMove in treeCandidates)
        switch (explorerBySan[treeMove.san]) {
          final dbMove? => treeMove.withExplorerStats(dbMove),
          null => treeMove,
        },
      for (final dbMove in explorer.moves)
        if (!treeSans.contains(dbMove.san))
          _candidateFromExplorerMove(
            move: dbMove,
            openingTree: openingTree,
            coverage: coverage,
            pathFromRoot: pathFromRoot,
          ),
    ];

    return _limitCandidates(
      sortCandidates(merged, isOurTurn: isOurTurn),
      maxCandidates,
    );
  }

  @visibleForTesting
  static List<CandidateMove> sortCandidates(
    List<CandidateMove> candidates, {
    required bool isOurTurn,
  }) {
    final sorted = List<CandidateMove>.of(candidates);
    if (isOurTurn) {
      // Our moves: repertoire moves first, then by expectimax.
      sorted.sort((a, b) {
        final aRepertoire = a.isRepertoireMove == true;
        final bRepertoire = b.isRepertoireMove == true;
        if (aRepertoire != bRepertoire) return aRepertoire ? -1 : 1;
        return (b.expectimax ?? 0.0).compareTo(a.expectimax ?? 0.0);
      });
    } else {
      // Their moves: most played first.
      sorted.sort(
        (a, b) => (b.dbFrequency ?? 0.0).compareTo(a.dbFrequency ?? 0.0),
      );
    }
    return sorted;
  }

  /// Truncates to [maxCandidates]; `null` means "no limit" — the browser
  /// splits common vs. rare moves itself, so a hidden top-N cut here would
  /// drop legal replies before the user could ever see them.
  static List<CandidateMove> _limitCandidates(
    List<CandidateMove> candidates,
    int? maxCandidates,
  ) {
    if (maxCandidates == null || candidates.length <= maxCandidates) {
      return candidates;
    }
    return candidates.sublist(0, maxCandidates);
  }

  static CandidateMove _candidateFromExplorerMove({
    required ExplorerMove move,
    required OpeningGraph? openingTree,
    required CoverageResult? coverage,
    required List<String> pathFromRoot,
  }) {
    final total = move.total;
    final hasGames = total > 0;
    return CandidateMove(
      san: move.san,
      uci: move.uci,
      dbGames: hasGames ? total : null,
      dbFrequency: hasGames ? move.playFraction : null,
      dbWhiteWin: hasGames ? move.white / total : null,
      dbDraw: hasGames ? move.draws / total : null,
      dbBlackWin: hasGames ? move.black / total : null,
      inRepertoire: openingTree?.hasMoveOnPath(pathFromRoot, move.san) ?? false,
      coverageDelta: coverageDeltaForMove(coverage, pathFromRoot, move.san),
      evalSource: 'db',
    );
  }

  @visibleForTesting
  static double? coverageDeltaForMove(
    CoverageResult? coverage,
    List<String> pathFromRoot,
    String san,
  ) {
    if (coverage == null || coverage.rootGameCount == 0) return null;

    for (final um in coverage.unaccountedMoves) {
      if (um.move == san && listEquals(um.parentMoves, pathFromRoot)) {
        return (um.gameCount / coverage.rootGameCount) * 100;
      }
    }
    return null;
  }

  /// The tree node at [fen]: by the canonical map when there is one, else a
  /// breadth-first search of [tree].
  BuildTreeNode? _findNode(String fen) {
    final map = fenMap;
    if (map != null) return map.getCanonical(fen);
    final root = tree?.root;
    if (root == null) return null;
    return root.fen == fen ? root : _bfsFind(root, fen);
  }

  static BuildTreeNode? _bfsFind(BuildTreeNode root, String fen) {
    final queue = Queue<BuildTreeNode>()..add(root);
    while (queue.isNotEmpty) {
      final node = queue.removeFirst();
      for (final child in node.children) {
        if (child.fen == fen) return child;
        queue.add(child);
      }
    }
    return null;
  }

  /// Nodes with a trap score in [node]'s subtree, [node] included.
  static int _countTraps(BuildTreeNode node) {
    var count = node.trapScore > 0 ? 1 : 0;
    for (final child in node.children) {
      count += _countTraps(child);
    }
    return count;
  }
}
