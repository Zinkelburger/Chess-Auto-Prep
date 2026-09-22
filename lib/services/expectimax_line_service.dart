/// Expectimax continuations used by the live trick probe.
///
/// Walks a precomputed (cooked) [BuildTree] to produce engine-style "best
/// lines" using practical win probability (V) instead of raw engine eval.
/// Everything here is a pure read of values the build already stored —
/// nothing runs the engine.
library;

import 'dart:collection' show Queue;

import '../chess_core/generation/build_tree_node.dart';
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

  /// The line along [path], whose first node carries the line's value.
  /// An empty path is a line of value 0.5 with no eval.
  factory ExpectimaxLine.fromPath(
    List<BuildTreeNode> path,
    TreeBuildConfig config, {
    int rank = 0,
  }) {
    final first = path.firstOrNull;
    final value = first?.expectimaxValue ?? 0.5;
    return ExpectimaxLine(
      rank: rank,
      expectimaxValue: value,
      expectedEvalCp: expectedCpFromWinProb(value),
      evalCp: first != null && first.hasEngineEval
          ? first.evalForUs(config.playAsWhite)
          : null,
      depth: path.length,
      movesSan: [for (final n in path) n.moveSan],
      movesUci: [for (final n in path) n.moveUci],
      moveInfo: [for (final n in path) ExpectimaxMoveInfo.of(n, config)],
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

  /// The metadata of the move that reaches [node]. Values the build never
  /// stored (no eval, no expectimax pass, a negative trap score) are null.
  factory ExpectimaxMoveInfo.of(BuildTreeNode node, TreeBuildConfig config) =>
      ExpectimaxMoveInfo(
        moveProbability: node.moveProbability,
        isOurMove: node.isWhiteToMove != config.playAsWhite,
        isRepertoireMove: node.isRepertoireMove,
        evalCp: node.hasEngineEval ? node.evalForUs(config.playAsWhite) : null,
        ease: node.ease,
        trapScore: node.trapScore >= 0 ? node.trapScore : null,
        expectimaxValue: node.hasExpectimax ? node.expectimaxValue : null,
      );
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
    final next = isOurMove
        ? eca.scoreOurMoveChildren(resolved)?.child
        : _mostProbableChild(resolved);
    if (next == null) break;
    path.add(next);
    node = next;
  }

  return path;
}

/// The child the opponent is likeliest to play. Null only when [node] has
/// no children.
BuildTreeNode? _mostProbableChild(BuildTreeNode node) {
  BuildTreeNode? best;
  for (final child in node.children) {
    if (best == null || child.moveProbability > best.moveProbability) {
      best = child;
    }
  }
  return best;
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
}) => _linesFrom(
  start,
  config,
  eca,
  limit: topLines.clamp(1, TreeBuildConfig.maxOurCandidates),
  maxPlies: maxPlies,
  fenMap: fenMap,
);

/// One expectimax PV row for *every* move the tree holds at [start] — the
/// position table the Expectimax pane shows.  Same ordering as
/// [generateExpectimaxLines] (by value on our move, by probability on the
/// opponent's), with no cap: the point is to see the whole candidate set,
/// including the moves the build considered and passed over.
List<ExpectimaxLine> expectimaxLinesForAllMoves(
  BuildTreeNode start,
  TreeBuildConfig config,
  ExpectimaxCalculator eca, {
  required int maxPlies,
  FenMap? fenMap,
}) => _linesFrom(
  resolveTransposition(start, fenMap),
  config,
  eca,
  limit: null,
  maxPlies: maxPlies,
  fenMap: fenMap,
);

List<ExpectimaxLine> _linesFrom(
  BuildTreeNode start,
  TreeBuildConfig config,
  ExpectimaxCalculator eca, {
  required int? limit,
  required int maxPlies,
  FenMap? fenMap,
}) {
  final ranked = _rankedChildren(start, config);
  final starters = limit == null ? ranked : ranked.take(limit);
  return [
    for (final (i, firstChild) in starters.indexed)
      ExpectimaxLine.fromPath(
        [
          firstChild,
          ...followExpectimaxLine(
            firstChild,
            config,
            eca,
            maxPlies: maxPlies - 1,
            fenMap: fenMap,
          ),
        ],
        config,
        rank: i + 1,
      ),
  ];
}

/// [start]'s children in line order: by expectimax value on our move, by
/// move probability on the opponent's.
///
/// Only children the build evaluated are listed.  A node the build never
/// reached still carries the 0.0 default, which reads back as a lost
/// position — on a paused or partial build every unexplored reply would
/// otherwise be listed as a forced loss.
List<BuildTreeNode> _rankedChildren(
  BuildTreeNode start,
  TreeBuildConfig config,
) {
  final evaluated = [
    for (final child in start.children)
      if (child.hasExpectimax) child,
  ];
  final isOurMove = start.isWhiteToMove == config.playAsWhite;
  evaluated.sort(
    isOurMove
        ? (a, b) => b.expectimaxValue.compareTo(a.expectimaxValue)
        : (a, b) => b.moveProbability.compareTo(a.moveProbability),
  );
  return evaluated;
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
