/// Shared color helpers and threshold constants for eval-tree widgets.
///
/// Used by the eval-tree details pane and custom viewport so the color
/// language stays consistent across the rewritten viewer.
library;

import 'package:flutter/material.dart';

import '../features/eval_tree/models/eval_tree_snapshot.dart';
import '../theme/app_colors.dart';

// ── CPL thresholds (move loss vs best sibling) ─────────────────────────────

const double kCplBlunderThreshold = 40;
const double kCplBigMistakeThreshold = 25;
const double kCplMistakeThreshold = 15;
const double kCplInaccuracyThreshold = 8;

// ── Graph-node colors by move quality ─────────────────────────────────────

const Color kNodeColorOurMoveRepertoire = Color(0xFF3D5245);
const Color kNodeColorOurMove = Color(0xFF354840);
const Color kNodeColorOpponentMove = Color(0xFF3A4248);
const Color kNodeColorBlunder = Color(0xFF6E4545);
const Color kNodeColorBigMistake = Color(0xFF6E4F3D);
const Color kNodeColorMistake = Color(0xFF6E5A3D);
const Color kNodeColorInaccuracy = Color(0xFF6E6640);
const Color kNodeColorNeutral = Color(0xFF424242);
const Color kNodeAccentRepertoire = Color(0xFF8A9E9A);

/// Returns true when the move represented by [node] was played by us.
bool isOurMoveNode(EvalTreeSnapshot snapshot, EvalTreeNodeSnapshot node) {
  final parent = snapshot.parentOf(node.id);
  if (parent == null) return false;
  return parent.sideToMoveIsWhite == snapshot.playAsWhite;
}

/// Returns the centipawn loss of the move represented by [node] compared with
/// the mover's best sibling move from the same parent position.
double? nodeMoveLossCp(EvalTreeSnapshot snapshot, EvalTreeNodeSnapshot node) {
  final parent = snapshot.parentOf(node.id);
  final nodeEval = node.evalForUsCp;
  if (parent == null || nodeEval == null) return null;

  final siblings = snapshot.childrenOf(parent.id);
  var hasAnyEval = false;
  final ourMove = parent.sideToMoveIsWhite == snapshot.playAsWhite;
  var bestEvalForUs = ourMove ? -1000000 : 1000000;

  for (final sibling in siblings) {
    final eval = sibling.evalForUsCp;
    if (eval == null) continue;
    hasAnyEval = true;
    if (ourMove) {
      if (eval > bestEvalForUs) bestEvalForUs = eval;
    } else {
      if (eval < bestEvalForUs) bestEvalForUs = eval;
    }
  }

  if (!hasAnyEval) return null;
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

  if (isOurMoveNode(snapshot, node)) {
    return node.isRepertoireMove
        ? kNodeColorOurMoveRepertoire
        : kNodeColorOurMove;
  }
  return kNodeColorOpponentMove;
}

Color nodeTextColor(Color fillColor) {
  return Colors.white;
}

Color nodeSecondaryTextColor(Color fillColor) {
  return Colors.white.withValues(alpha: 0.86);
}

Color nodeSelectionColor(Color fillColor) {
  return ThemeData.estimateBrightnessForColor(fillColor) == Brightness.light
      ? Colors.black.withValues(alpha: 0.88)
      : Colors.white;
}

List<Shadow> nodeTextOutline(Color fillColor) {
  final outlineColor = Colors.black.withValues(alpha: 0.9);
  const outlineWidth = 1.0;
  return [
    Shadow(
      offset: Offset(outlineWidth, 0),
      blurRadius: 0,
      color: outlineColor,
    ),
    Shadow(
      offset: Offset(-outlineWidth, 0),
      blurRadius: 0,
      color: outlineColor,
    ),
    Shadow(
      offset: Offset(0, outlineWidth),
      blurRadius: 0,
      color: outlineColor,
    ),
    Shadow(
      offset: Offset(0, -outlineWidth),
      blurRadius: 0,
      color: outlineColor,
    ),
    Shadow(
      offset: Offset(outlineWidth, outlineWidth),
      blurRadius: 0,
      color: outlineColor,
    ),
    Shadow(
      offset: Offset(-outlineWidth, outlineWidth),
      blurRadius: 0,
      color: outlineColor,
    ),
    Shadow(
      offset: Offset(outlineWidth, -outlineWidth),
      blurRadius: 0,
      color: outlineColor,
    ),
    Shadow(
      offset: Offset(-outlineWidth, -outlineWidth),
      blurRadius: 0,
      color: outlineColor,
    ),
  ];
}

Color roleBadgeColor(bool isOurTurn) {
  return isOurTurn ? kNodeColorOurMove : kNodeColorOpponentMove;
}

// ── Eval color (stats panel) ──────────────────────────────────────────────

Color evalColor(int cpForUs) => AppColors.cpEval(cpForUs);

Color evalBgColor(int cpForUs) => AppColors.cpEvalBg(cpForUs);

Color evalTextColor(int cpForUs) => AppColors.cpEval(cpForUs);

// ── Other metric colors ───────────────────────────────────────────────────

Color easeColor(double ease) => AppColors.ease(ease);

Color cplColor(double cpl) => AppColors.cpl(cpl);

Color trapColor(double trap) => AppColors.trapScore(trap);

Color vColor(double v) => AppColors.winProbability(v);
