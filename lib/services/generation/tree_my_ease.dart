/// "My Ease" computation for [BuildTreeNode] trees.
///
/// Measures how natural/easy each of OUR chosen moves is to find,
/// based on Maia move-probability data already stored on nodes.
///
/// Runs as a post-processing pass after ease and expectimax calculation.
library;

import 'dart:math' as math;

import '../../models/build_tree_node.dart';

/// Compute my-ease for all our-move children in the tree.
///
/// At each our-turn node, each child receives a [BuildTreeNode.myEase]
/// score in [0, 1] reflecting how natural that move is for a human.
/// Returns the number of nodes that received a value.
int calculateMyEase(BuildTree tree, {required bool playAsWhite}) {
  return _myEaseRecursive(tree.root, playAsWhite);
}

int _myEaseRecursive(BuildTreeNode node, bool playAsWhite) {
  int count = 0;
  final isOurTurn = node.isWhiteToMove == playAsWhite;

  if (isOurTurn && node.children.isNotEmpty) {
    for (final child in node.children) {
      child.myEase = _computeMyEase(child, node);
      count++;
    }
  }

  for (final child in node.children) {
    count += _myEaseRecursive(child, playAsWhite);
  }
  return count;
}

/// Compute how natural a single our-move child is.
///
/// Primary signal: [BuildTreeNode.maiaFrequency] — Maia's predicted
/// probability that a human would play this move.
double _computeMyEase(BuildTreeNode ourMoveChild, BuildTreeNode parent) {
  double ease =
      ourMoveChild.maiaFrequency >= 0 ? ourMoveChild.maiaFrequency : 0.5;

  if (_isOnlyReasonableMove(ourMoveChild, parent)) {
    ease = 1.0;
  } else if (ease < 0.15 && _isEngineBest(ourMoveChild, parent)) {
    ease = ease.clamp(0.0, 0.5);
  }

  return ease.clamp(0.0, 1.0);
}

/// True when the engine gap between this move and the second-best
/// is so large that the move is effectively forced.
bool _isOnlyReasonableMove(BuildTreeNode child, BuildTreeNode parent) {
  if (parent.children.length < 2) return true;

  final evaluated = parent.children.where((c) => c.hasEngineEval).toList();
  if (evaluated.length < 2) return true;

  evaluated
      .sort((a, b) => (b.engineEvalCp ?? 0).compareTo(a.engineEvalCp ?? 0));

  final gap = (evaluated[0].engineEvalCp! - evaluated[1].engineEvalCp!).abs();
  return gap > 200;
}

/// True when this child has the best engine eval among siblings.
bool _isEngineBest(BuildTreeNode child, BuildTreeNode parent) {
  if (!child.hasEngineEval) return false;
  for (final sibling in parent.children) {
    if (sibling == child) continue;
    if (!sibling.hasEngineEval) continue;
    if (sibling.engineEvalCp! > child.engineEvalCp!) return false;
  }
  return true;
}

/// Combined position quality at a single node.
///
/// At our-move nodes: how natural is our best move here.
/// At opponent-move nodes: how hard it is for the opponent (1 - ease).
double computePositionQuality(
  BuildTreeNode node,
  bool playAsWhite,
) {
  final isOurMove = node.isWhiteToMove == playAsWhite;

  if (isOurMove) {
    final bestChild = node.children.isEmpty
        ? null
        : node.children.where((c) => c.isRepertoireMove).firstOrNull ??
            node.children.first;
    if (bestChild == null) return 0.5;
    return bestChild.myEase >= 0 ? bestChild.myEase : 0.5;
  } else {
    return 1.0 - (node.ease ?? 0.5);
  }
}

/// Aggregated playability metrics for a full line through the tree.
class LinePlayability {
  final double playability;
  final double bottleneckQuality;
  final int bottleneckPly;

  /// Whether the bottleneck is at a position where it is our turn to move.
  /// When false the bottleneck reflects opponent ease, not our difficulty.
  final bool bottleneckIsOurMove;
  final int easyMoveCount;
  final int hardMoveCount;

  const LinePlayability({
    required this.playability,
    required this.bottleneckQuality,
    required this.bottleneckPly,
    this.bottleneckIsOurMove = true,
    required this.easyMoveCount,
    required this.hardMoveCount,
  });

  static const neutral = LinePlayability(
    playability: 0.5,
    bottleneckQuality: 0.5,
    bottleneckPly: 0,
    easyMoveCount: 0,
    hardMoveCount: 0,
  );
}

/// Compute playability for a line (list of tree nodes from root to leaf).
///
/// [linePath] starts with the root position (index 0) followed by the node
/// after each successive move.  The root is the starting position, not a
/// move, so it is included in the geometric-mean quality but excluded from
/// the bottleneck search.  Additionally the first ply where it is our turn
/// is the user's deliberate opening choice (e.g. 1…d5 in the Scandinavian)
/// and is also excluded from the bottleneck — it is not "hard to find."
LinePlayability computeLinePlayability(
  List<BuildTreeNode> linePath,
  bool playAsWhite,
) {
  final qualities = <double>[];
  double minQuality = 1.0;
  int minPly = 0;
  int easy = 0;
  int hard = 0;

  bool seenFirstOurMove = false;

  for (var i = 0; i < linePath.length; i++) {
    final node = linePath[i];
    final quality = computePositionQuality(node, playAsWhite);
    qualities.add(quality);

    final isOurMove = node.isWhiteToMove == playAsWhite;

    // Skip root position (not a move) and our first move (opening choice)
    // from the bottleneck search.
    final skipBottleneck =
        i == 0 || (isOurMove && !seenFirstOurMove);
    if (isOurMove && !seenFirstOurMove) seenFirstOurMove = true;

    if (!skipBottleneck && quality < minQuality) {
      minQuality = quality;
      minPly = i;
    }
    if (quality > 0.7) easy++;
    if (quality < 0.3) hard++;
  }

  if (qualities.isEmpty) return LinePlayability.neutral;

  final logSum = qualities
      .map((q) => math.log(q.clamp(0.01, 1.0)))
      .reduce((a, b) => a + b);
  final geoMean = math.exp(logSum / qualities.length);

  final bottleneckIsOurMove = minPly < linePath.length &&
      linePath[minPly].isWhiteToMove == playAsWhite;

  return LinePlayability(
    playability: geoMean.clamp(0.0, 1.0),
    bottleneckQuality: minQuality,
    bottleneckPly: minPly,
    bottleneckIsOurMove: bottleneckIsOurMove,
    easyMoveCount: easy,
    hardMoveCount: hard,
  );
}
