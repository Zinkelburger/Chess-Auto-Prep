/// Shared color helpers and threshold constants for eval-tree widgets.
///
/// Used by the eval-tree details pane and custom viewport so the color
/// language stays consistent across the rewritten viewer.
library;

import 'package:flutter/material.dart';

import 'models/eval_tree_snapshot.dart';
import '../../theme/app_colors.dart';

// ── CPL thresholds (move loss vs best sibling) ─────────────────────────────

const double kCplBlunderThreshold = 40;
const double kCplBigMistakeThreshold = 25;
const double kCplMistakeThreshold = 15;
const double kCplInaccuracyThreshold = 8;

// ── Graph-node colors by move quality ─────────────────────────────────────

const Color kNodeColorOurMoveRepertoire = AppColors.treeNodeOurMoveRepertoire;
const Color kNodeColorOurMove = AppColors.treeNodeOurMove;
const Color kNodeColorOpponentMove = AppColors.treeNodeOpponentMove;
const Color kNodeColorBlunder = AppColors.treeNodeBlunder;
const Color kNodeColorBigMistake = AppColors.treeNodeBigMistake;
const Color kNodeColorMistake = AppColors.treeNodeMistake;
const Color kNodeColorInaccuracy = AppColors.treeNodeInaccuracy;
const Color kNodeColorNeutral = AppColors.treeNodeNeutral;
const Color kNodeAccentRepertoire = AppColors.treeNodeAccentRepertoire;

/// Returns the centipawn loss of the move represented by [node] compared with
/// the mover's best sibling move from the same parent position: the highest
/// eval for us among our moves, the lowest among the opponent's.
double? nodeMoveLossCp(EvalTreeSnapshot snapshot, EvalTreeNodeSnapshot node) {
  final parent = snapshot.parentOf(node.id);
  final nodeEval = node.evalForUsCp;
  if (parent == null || nodeEval == null) return null;

  final ourMove = snapshot.isOurMove(node.id);
  int? bestEvalForUs;
  for (final sibling in snapshot.childrenOf(parent.id)) {
    final eval = sibling.evalForUsCp;
    if (eval == null) continue;
    final best = bestEvalForUs;
    if (best == null || (ourMove ? eval > best : eval < best)) {
      bestEvalForUs = eval;
    }
  }
  if (bestEvalForUs == null) return null;
  final loss = ourMove ? bestEvalForUs - nodeEval : nodeEval - bestEvalForUs;
  return loss <= 0 ? 0.0 : loss.toDouble();
}

/// Returns the node fill color for an eval-tree node in the visual graph.
///
/// Colors follow the move shown on the chip, not the side to move in the
/// resulting position. Good moves for us are green, strong opponent replies
/// stay dark, and suboptimal moves from either side use warm colors.
Color graphNodeColor({
  required EvalTreeSnapshot snapshot,
  required EvalTreeNodeSnapshot node,
}) {
  if (node.parentId == null) {
    return kNodeColorNeutral;
  }

  final moveLossCp = nodeMoveLossCp(snapshot, node);
  if (moveLossCp != null) {
    if (moveLossCp >= kCplBlunderThreshold) return kNodeColorBlunder;
    if (moveLossCp >= kCplBigMistakeThreshold) return kNodeColorBigMistake;
    if (moveLossCp >= kCplMistakeThreshold) return kNodeColorMistake;
    if (moveLossCp >= kCplInaccuracyThreshold) return kNodeColorInaccuracy;
  }

  if (snapshot.isOurMove(node.id)) {
    return node.isRepertoireMove
        ? kNodeColorOurMoveRepertoire
        : kNodeColorOurMove;
  }
  return kNodeColorOpponentMove;
}

/// Title text on any node fill: ink reads on every fill in the palette.
const Color kNodeTextColor = AppColors.ink;

/// Secondary text on any node fill. 0.92 keeps the raw ratio at or above
/// 4.5:1 even on the brightest fill (treeNodeInaccuracy: 4.66:1); the 1px
/// glyph outline adds further margin.
final Color kNodeSecondaryTextColor = AppColors.ink.withValues(alpha: 0.92);

Color nodeSelectionColor(Color fillColor) {
  return ThemeData.estimateBrightnessForColor(fillColor) == Brightness.light
      ? AppColors.onWarning
      : AppColors.ink;
}

/// A 1px outline around node text, as eight hard shadows, so the text reads
/// on any fill.
List<Shadow> nodeTextOutline(Color fillColor) {
  final outlineColor = AppColors.backdrop.withValues(alpha: 0.9);
  const outlineWidth = 1.0;
  return [
    for (final dx in const [-outlineWidth, 0.0, outlineWidth])
      for (final dy in const [-outlineWidth, 0.0, outlineWidth])
        if (dx != 0 || dy != 0)
          Shadow(offset: Offset(dx, dy), blurRadius: 0, color: outlineColor),
  ];
}
