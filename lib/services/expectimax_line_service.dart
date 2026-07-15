/// Expectimax line generation for the ExpectimaxLinesPane.
///
/// Walks a precomputed [BuildTree] to produce engine-style "best lines"
/// using practical win probability (V) instead of raw engine eval.
library;

import 'dart:collection' show Queue;

import '../models/build_tree_node.dart';
import '../utils/ease_utils.dart' show expectedCpFromWinProb;
import 'generation/eca_calculator.dart';
import 'generation/fen_map.dart';
import 'generation/generation_config.dart';

/// One line of expectimax output, analogous to a Stockfish DiscoveryLine.
class ExpectimaxLine {
  final int rank;
  final double expectimaxValue;

  /// Expected eval in centipawns, derived from the expectimax win probability.
  /// Accounts for opponent mistake probabilities — will be higher than raw
  /// engine eval when opponents are likely to blunder.
  final int expectedEvalCp;

  final int? evalCp;
  final int depth;
  final List<String> movesSan;
  final List<String> movesUci;
  final List<ExpectimaxMoveInfo> moveInfo;

  const ExpectimaxLine({
    required this.rank,
    required this.expectimaxValue,
    required this.expectedEvalCp,
    required this.evalCp,
    required this.depth,
    required this.movesSan,
    required this.movesUci,
    required this.moveInfo,
  });

  /// Same line at a different display rank.
  ExpectimaxLine withRank(int newRank) => ExpectimaxLine(
    rank: newRank,
    expectimaxValue: expectimaxValue,
    expectedEvalCp: expectedEvalCp,
    evalCp: evalCp,
    depth: depth,
    movesSan: movesSan,
    movesUci: movesUci,
    moveInfo: moveInfo,
  );

  factory ExpectimaxLine.fromPath(
    BuildTreeNode start,
    List<BuildTreeNode> path,
    TreeBuildConfig config, {
    int rank = 0,
  }) {
    final v = path.isNotEmpty ? path.first.expectimaxValue : 0.5;
    return ExpectimaxLine(
      rank: rank,
      expectimaxValue: v,
      expectedEvalCp: expectedCpFromWinProb(v),
      evalCp: path.isNotEmpty && path.first.hasEngineEval
          ? path.first.evalForUs(config.playAsWhite)
          : null,
      depth: path.length,
      movesSan: path.map((n) => n.moveSan).toList(),
      movesUci: path.map((n) => n.moveUci).toList(),
      moveInfo: path
          .map(
            (n) => ExpectimaxMoveInfo(
              moveProbability: n.moveProbability,
              isOurMove: n.isWhiteToMove != config.playAsWhite,
              isRepertoireMove: n.isRepertoireMove,
              evalCp: n.hasEngineEval ? n.evalForUs(config.playAsWhite) : null,
              ease: n.ease,
              trapScore: n.trapScore >= 0 ? n.trapScore : null,
              expectimaxValue: n.hasExpectimax ? n.expectimaxValue : null,
            ),
          )
          .toList(),
    );
  }
}

/// Per-move metadata in an expectimax line.
class ExpectimaxMoveInfo {
  final double moveProbability;
  final bool isOurMove;
  final bool isRepertoireMove;
  final int? evalCp;
  final double? ease;
  final double? trapScore;
  final double? expectimaxValue;

  const ExpectimaxMoveInfo({
    required this.moveProbability,
    required this.isOurMove,
    required this.isRepertoireMove,
    this.evalCp,
    this.ease,
    this.trapScore,
    this.expectimaxValue,
  });
}

/// Follow the expectimax-optimal path from [start] for up to [maxPlies].
///
/// At our-move nodes: pick the child with the highest expectimax value.
/// At opponent nodes: pick the child with the highest moveProbability.
List<BuildTreeNode> followExpectimaxLine(
  BuildTreeNode start,
  TreeBuildConfig config,
  ExpectimaxCalculator eca, {
  required int maxPlies,
  FenMap? fenMap,
}) {
  final path = <BuildTreeNode>[];
  var node = start;

  for (var i = 0; i < maxPlies && node.children.isNotEmpty; i++) {
    final resolved = resolveTransposition(node, fenMap);
    if (resolved.children.isEmpty) break;

    final isOurMove = resolved.isWhiteToMove == config.playAsWhite;
    BuildTreeNode? next;

    if (isOurMove) {
      final scored = eca.scoreOurMoveChildren(resolved);
      next = scored?.child;
    } else {
      double bestProb = -1;
      for (final child in resolved.children) {
        if (child.moveProbability > bestProb) {
          bestProb = child.moveProbability;
          next = child;
        }
      }
    }

    if (next == null) break;
    path.add(next);
    node = next;
  }

  return path;
}

/// Top-[topLines] expectimax PV rows from [start].
///
/// At our-move nodes: rank children by expectimax value.
/// At opponent nodes: rank children by move probability.
/// Each row is one first move plus [followExpectimaxLine] continuation.
List<ExpectimaxLine> generateExpectimaxLines(
  BuildTreeNode start,
  TreeBuildConfig config,
  ExpectimaxCalculator eca, {
  required int topLines,
  required int maxPlies,
  FenMap? fenMap,
}) {
  final limit = topLines.clamp(1, TreeBuildConfig.maxOurCandidates);
  if (start.children.isEmpty) return [];

  final isOurMove = start.isWhiteToMove == config.playAsWhite;
  final starters = <BuildTreeNode>[];

  if (isOurMove) {
    final scored = <ScoredChild>[];
    for (final child in start.children) {
      if (!child.hasExpectimax) continue;
      scored.add(
        ScoredChild(child: child, expectimaxValue: child.expectimaxValue),
      );
    }
    scored.sort((a, b) => b.expectimaxValue.compareTo(a.expectimaxValue));
    for (var i = 0; i < limit && i < scored.length; i++) {
      starters.add(scored[i].child);
    }
  } else {
    final sorted = List<BuildTreeNode>.from(start.children)
      ..sort((a, b) => b.moveProbability.compareTo(a.moveProbability));
    for (var i = 0; i < limit && i < sorted.length; i++) {
      starters.add(sorted[i]);
    }
  }

  final lines = <ExpectimaxLine>[];
  for (var i = 0; i < starters.length; i++) {
    final firstChild = starters[i];
    final continuation = followExpectimaxLine(
      firstChild,
      config,
      eca,
      maxPlies: maxPlies - 1,
      fenMap: fenMap,
    );
    lines.add(
      ExpectimaxLine.fromPath(
        start,
        [firstChild, ...continuation],
        config,
        rank: i + 1,
      ),
    );
  }

  return lines;
}

/// Generate a single expectimax line starting with [firstChild].
ExpectimaxLine? generateLineForFirstMove(
  BuildTreeNode root,
  BuildTreeNode firstChild,
  TreeBuildConfig config,
  ExpectimaxCalculator eca, {
  required int maxPlies,
  FenMap? fenMap,
}) {
  final continuation = followExpectimaxLine(
    firstChild,
    config,
    eca,
    maxPlies: maxPlies - 1,
    fenMap: fenMap,
  );
  if (!firstChild.hasExpectimax) return null;
  return ExpectimaxLine.fromPath(
    root,
    [firstChild, ...continuation],
    config,
    rank: 0,
  );
}

/// True when [fen] exists in [tree] with expectimax and the subtree reaches
/// at least [targetPly] (suitable for multi-move precomputed PV).
bool hasPrecomputedExpectimaxAtPly(BuildTree tree, String fen, int targetPly) {
  final node = findNodeByFen(tree, fen);
  if (node == null || !node.hasExpectimax || node.children.isEmpty) {
    return false;
  }
  return maxSubtreePly(node) >= targetPly;
}

/// Deepest [BuildTreeNode.ply] in [node]'s subtree (including [node]).
int maxSubtreePly(BuildTreeNode node) {
  var max = node.ply;
  for (final child in node.children) {
    final childMax = maxSubtreePly(child);
    if (childMax > max) max = childMax;
  }
  return max;
}

/// Whether [node]'s subtree has been fully explored up to [targetPly].
bool isBranchCompleteToPly(BuildTreeNode node, int targetPly) {
  if (node.ply >= targetPly) return true;
  if (!node.explored && node.children.isEmpty) return false;
  if (node.children.isEmpty) return node.explored;
  return node.children.every((c) => isBranchCompleteToPly(c, targetPly));
}

/// Find a node in the tree by FEN (BFS — returns the shallowest match,
/// which is normally the canonical expansion of a transposed position).
BuildTreeNode? findNodeByFen(BuildTree tree, String fen) {
  if (tree.root.fen == fen) return tree.root;
  final queue = Queue<BuildTreeNode>()..add(tree.root);
  while (queue.isNotEmpty) {
    final node = queue.removeFirst();
    for (final child in node.children) {
      if (child.fen == fen) return child;
      queue.add(child);
    }
  }
  return null;
}
