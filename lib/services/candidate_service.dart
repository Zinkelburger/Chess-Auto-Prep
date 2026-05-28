/// Produces unified candidate move lists for browse mode.
///
/// Merges BuildTree children with Lichess DB data to provide
/// context-rich move suggestions at any position.
library;

import '../models/build_tree_node.dart';
import 'generation/fen_map.dart';

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

/// Produces candidate lists from a BuildTree.
class CandidateService {
  final BuildTree? tree;
  final FenMap? fenMap;

  CandidateService({this.tree, this.fenMap});

  /// Get candidates at a FEN from the tree.
  List<CandidateMove> getTreeCandidates({
    required String fen,
    required bool isOurTurn,
    required bool playAsWhite,
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
        evalSource: 'tree',
        treeNode: child,
        ply: child.ply,
        dbGames: child.totalGames > 0 ? child.totalGames : null,
        dbFrequency: child.moveProbability > 0
            ? child.moveProbability
            : null,
      ));
    }

    if (isOurTurn) {
      candidates.sort((a, b) {
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
      candidates.sort((a, b) {
        final aF = a.dbFrequency ?? 0.0;
        final bF = b.dbFrequency ?? 0.0;
        return bF.compareTo(aF);
      });
    }

    return candidates;
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
