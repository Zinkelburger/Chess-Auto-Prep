/// Shared child-selection helpers for the generation pipeline.
///
/// Several selectors share the same shape: find the best sibling engine eval,
/// keep children within `maxEvalLossCp` of it, argmax a value function over
/// the survivors, and fall back to considering all children when nothing
/// passes the filter. This file is the single implementation; the subtle
/// differences between call sites (which eligibility guard applies, and
/// whether it also guards the fallback pass) are parameters, not copies.
library;

import '../../models/build_tree_node.dart';
import '../../utils/eval_constants.dart';

/// Highest [BuildTreeNode.evalForUs] among [children] that have an engine
/// eval, or [kWorstEvalCp] when none do.
int bestSiblingEvalCp(
  List<BuildTreeNode> children, {
  required bool playAsWhite,
}) {
  var best = kWorstEvalCp;
  for (final child in children) {
    if (!child.hasEngineEval) continue;
    final cpUs = child.evalForUs(playAsWhite);
    if (cpUs > best) best = cpUs;
  }
  return best;
}

/// Argmax of [value] over the [children] whose eval-for-us is within
/// [maxEvalLossCp] of the best sibling eval, falling back to all children
/// when none pass the filter.
///
/// [eligible] gates candidates in the filtered pass. Whether it also gates
/// the fallback pass differs between historical call sites (the expectimax
/// selector requires `hasExpectimax` in both passes; the trappy selector
/// requires `hasEngineEval` only in the filtered pass), so that is controlled
/// by [eligibleGuardsFallback] rather than duplicated.
///
/// A candidate is picked only when its value is strictly greater than
/// [minValue]; callers seed this with their historical accumulator init
/// (`-1.0` for probability/CPL values) to preserve exact semantics.
///
/// Children without an engine eval that reach the eval filter are compared
/// using `evalForUs == 0`, matching the original loops.
BuildTreeNode? pickChildByValue(
  List<BuildTreeNode> children, {
  required bool playAsWhite,
  required int maxEvalLossCp,
  required double Function(BuildTreeNode child) value,
  bool Function(BuildTreeNode child)? eligible,
  bool eligibleGuardsFallback = true,
  double minValue = -1.0,
}) {
  if (children.isEmpty) return null;

  final bestCp = bestSiblingEvalCp(children, playAsWhite: playAsWhite);

  var bestV = minValue;
  BuildTreeNode? bestChild;
  var passing = 0;

  for (final child in children) {
    if (eligible != null && !eligible(child)) continue;
    final cpUs = child.evalForUs(playAsWhite);
    if (cpUs < bestCp - maxEvalLossCp) continue;
    passing++;
    final v = value(child);
    if (v > bestV) {
      bestV = v;
      bestChild = child;
    }
  }

  // Fallback: all filtered out → consider all (eligible) children.
  if (passing == 0) {
    for (final child in children) {
      if (eligibleGuardsFallback && eligible != null && !eligible(child)) {
        continue;
      }
      final v = value(child);
      if (v > bestV) {
        bestV = v;
        bestChild = child;
      }
    }
  }

  return bestChild;
}
