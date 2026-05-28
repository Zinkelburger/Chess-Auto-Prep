/// Produces candidate move lists for browse mode.
///
/// Merges [BuildTree] children with Lichess Explorer data when the tree is
/// missing or sparse at a position. Uses [CoverageService] for Explorer API
/// access (shared client and cache).
library;

import 'package:flutter/foundation.dart';

import '../../../models/build_tree_node.dart';
import '../../../models/explorer_response.dart';
import '../../../models/opening_tree.dart';
import '../../../services/generation/fen_map.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';

/// A single candidate move at the current position.
class CandidateMove {
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

  bool get hasTreeData => evalCp != null;
  bool get hasDbData => dbGames != null;
}

/// Merges BuildTree and Lichess Explorer into sorted browse candidates.
class CandidateService {
  final BuildTree? tree;
  final FenMap? fenMap;
  final OpeningTree? openingTree;
  final CoverageResult? coverage;
  final CoverageService? coverageService;

  CandidateService({
    this.tree,
    this.fenMap,
    this.openingTree,
    this.coverage,
    this.coverageService,
  });

  /// Returns sorted candidates, merging tree data with Lichess Explorer when
  /// the tree is missing or sparse at [fen].
  Future<List<CandidateMove>> getCandidates({
    required String fen,
    required bool isOurTurn,
    required bool playAsWhite,
    List<String> pathFromRoot = const [],
    int maxCandidates = 8,
  }) async {
    final treeCandidates = getTreeCandidates(
      fen: fen,
      isOurTurn: isOurTurn,
      playAsWhite: playAsWhite,
      pathFromRoot: pathFromRoot,
    );

    ExplorerResponse? explorer;
    if (_shouldFetchExplorer(treeCandidates) && coverageService != null) {
      final data = await coverageService!.getPositionData(fen);
      if (data != null) {
        explorer = ExplorerResponse.fromJson(data, fen: fen);
      }
    }

    return mergeWithExplorer(
      treeCandidates: treeCandidates,
      explorer: explorer,
      fen: fen,
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

    final candidates = <CandidateMove>[];
    for (final child in node.children) {
      int trapCount = 0;
      if (child.children.isNotEmpty) {
        trapCount = _countTraps(child);
      }

      candidates.add(CandidateMove(
        san: child.moveSan,
        uci: child.moveUci,
        evalCp: child.hasEngineEval
            ? child.evalForUs(playAsWhite)
            : null,
        ease: child.ease,
        myEase: child.myEase >= 0 ? child.myEase : null,
        expectimax:
            child.hasExpectimax ? child.expectimaxValue : null,
        subtreeTrapCount: trapCount,
        isRepertoireMove: child.isRepertoireMove,
        inRepertoire: openingTree?.hasMove(fen, child.moveSan) ?? false,
        coverageDelta: coverageDeltaForMove(
          coverage,
          pathFromRoot,
          child.moveSan,
        ),
        evalSource: 'tree',
        treeNode: child,
        ply: child.ply,
        dbGames: child.totalGames > 0 ? child.totalGames : null,
        dbFrequency: child.moveProbability > 0
            ? child.moveProbability
            : null,
      ));
    }

    return sortCandidates(candidates, isOurTurn: isOurTurn);
  }

  bool _shouldFetchExplorer(List<CandidateMove> treeCandidates) {
    if (tree == null) return true;
    if (treeCandidates.isEmpty) return true;
    if (treeCandidates.every((c) => !c.hasDbData)) return true;
    return false;
  }

  /// Merge tree candidates with Explorer moves; testable without HTTP.
  @visibleForTesting
  static List<CandidateMove> mergeWithExplorer({
    required List<CandidateMove> treeCandidates,
    required ExplorerResponse? explorer,
    required String fen,
    required bool isOurTurn,
    required OpeningTree? openingTree,
    required CoverageResult? coverage,
    required List<String> pathFromRoot,
    int maxCandidates = 8,
  }) {
    if (explorer == null || explorer.moves.isEmpty) {
      return _limitCandidates(
        sortCandidates(treeCandidates, isOurTurn: isOurTurn),
        maxCandidates,
      );
    }

    final explorerBySan = {
      for (final move in explorer.moves) move.san: move,
    };
    final merged = <CandidateMove>[];
    final seenSans = <String>{};

    for (final treeMove in treeCandidates) {
      seenSans.add(treeMove.san);
      final dbMove = explorerBySan[treeMove.san];
      merged.add(
        dbMove != null
            ? _enrichWithExplorer(treeMove, dbMove)
            : treeMove,
      );
    }

    for (final dbMove in explorer.moves) {
      if (seenSans.contains(dbMove.san)) continue;
      merged.add(_candidateFromExplorerMove(
        fen: fen,
        move: dbMove,
        openingTree: openingTree,
        coverage: coverage,
        pathFromRoot: pathFromRoot,
      ));
    }

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
    final sorted = List<CandidateMove>.from(candidates);
    if (isOurTurn) {
      sorted.sort((a, b) {
        if (a.isRepertoireMove == true && b.isRepertoireMove != true) {
          return -1;
        }
        if (b.isRepertoireMove == true && a.isRepertoireMove != true) {
          return 1;
        }
        final aV = a.expectimax ?? 0.0;
        final bV = b.expectimax ?? 0.0;
        return bV.compareTo(aV);
      });
    } else {
      sorted.sort((a, b) {
        final aF = a.dbFrequency ?? 0.0;
        final bF = b.dbFrequency ?? 0.0;
        return bF.compareTo(aF);
      });
    }
    return sorted;
  }

  static List<CandidateMove> _limitCandidates(
    List<CandidateMove> candidates,
    int maxCandidates,
  ) {
    if (candidates.length <= maxCandidates) return candidates;
    return candidates.sublist(0, maxCandidates);
  }

  static CandidateMove _enrichWithExplorer(
    CandidateMove treeMove,
    ExplorerMove dbMove,
  ) {
    final total = dbMove.total;
    final (whiteWin, draw, blackWin) = _resultRates(dbMove);
    return CandidateMove(
      san: treeMove.san,
      uci: treeMove.uci.isNotEmpty ? treeMove.uci : dbMove.uci,
      evalCp: treeMove.evalCp,
      ease: treeMove.ease,
      myEase: treeMove.myEase,
      expectimax: treeMove.expectimax,
      subtreeTrapCount: treeMove.subtreeTrapCount,
      isRepertoireMove: treeMove.isRepertoireMove,
      dbGames: total > 0 ? total : treeMove.dbGames,
      dbFrequency:
          total > 0 ? dbMove.playFraction : treeMove.dbFrequency,
      dbWhiteWin: whiteWin ?? treeMove.dbWhiteWin,
      dbDraw: draw ?? treeMove.dbDraw,
      dbBlackWin: blackWin ?? treeMove.dbBlackWin,
      inRepertoire: treeMove.inRepertoire,
      coverageDelta: treeMove.coverageDelta,
      evalSource: treeMove.evalSource,
      treeNode: treeMove.treeNode,
      ply: treeMove.ply,
    );
  }

  static CandidateMove _candidateFromExplorerMove({
    required String fen,
    required ExplorerMove move,
    required OpeningTree? openingTree,
    required CoverageResult? coverage,
    required List<String> pathFromRoot,
  }) {
    final total = move.total;
    final (whiteWin, draw, blackWin) = _resultRates(move);
    return CandidateMove(
      san: move.san,
      uci: move.uci,
      dbGames: total > 0 ? total : null,
      dbFrequency: total > 0 ? move.playFraction : null,
      dbWhiteWin: whiteWin,
      dbDraw: draw,
      dbBlackWin: blackWin,
      inRepertoire: openingTree?.hasMove(fen, move.san) ?? false,
      coverageDelta: coverageDeltaForMove(coverage, pathFromRoot, move.san),
      evalSource: 'db',
    );
  }

  static (double?, double?, double?) _resultRates(ExplorerMove move) {
    final total = move.total;
    if (total <= 0) return (null, null, null);
    return (
      move.white / total,
      move.draws / total,
      move.black / total,
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
      if (um.move == san && _listEquals(um.parentMoves, pathFromRoot)) {
        return (um.gameCount / coverage.rootGameCount) * 100;
      }
    }
    return null;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  BuildTreeNode? _findNode(String fen) {
    if (fenMap != null) {
      return fenMap!.getCanonical(fen);
    }
    if (tree == null) return null;
    if (tree!.root.fen == fen) return tree!.root;
    return _bfsFind(tree!.root, fen);
  }

  static BuildTreeNode? _bfsFind(BuildTreeNode root, String fen) {
    final queue = <BuildTreeNode>[root];
    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      for (final child in node.children) {
        if (child.fen == fen) return child;
        queue.add(child);
      }
    }
    return null;
  }

  static int _countTraps(BuildTreeNode node) {
    int count = 0;
    if (node.trapScore > 0) count++;
    for (final child in node.children) {
      count += _countTraps(child);
    }
    return count;
  }
}
