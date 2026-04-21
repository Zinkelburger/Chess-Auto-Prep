/// Shared color helpers and threshold constants for eval-tree widgets.
///
/// Used by the eval-tree details pane and custom viewport so the color
/// language stays consistent across the rewritten viewer.
library;

import 'package:flutter/material.dart';

import '../features/eval_tree/models/eval_tree_snapshot.dart';

// ── CPL thresholds (move loss vs best sibling) ─────────────────────────────

const double kCplBlunderThreshold = 40;
const double kCplBigMistakeThreshold = 25;
const double kCplMistakeThreshold = 15;
const double kCplInaccuracyThreshold = 8;

// ── Graph-node colors by move quality ─────────────────────────────────────

const Color kNodeColorOurMoveRepertoire = Color(0xFF2E7D32); // green[800]
const Color kNodeColorOurMove = Color(0xFF1B5E20); // green[900]
const Color kNodeColorOpponentMove = Color(0xFF37474F); // blueGrey[800]
const Color kNodeColorBlunder = Color(0xFFE53935); // red[600]
const Color kNodeColorBigMistake = Color(0xFFF4511E); // deepOrange[600]
const Color kNodeColorMistake = Color(0xFFFB8C00); // orange[600]
const Color kNodeColorInaccuracy = Color(0xFFFDD835); // yellow[600]
const Color kNodeColorNeutral = Color(0xFF424242); // grey[800]
const Color kNodeAccentRepertoire = Color(0xFFB2DFDB); // teal[100]

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

Color evalColor(int cpForUs) {
  if (cpForUs > 100) return Colors.green;
  if (cpForUs > 30) return Colors.green[300]!;
  if (cpForUs > -30) return Colors.grey[400]!;
  if (cpForUs > -100) return Colors.orange;
  return Colors.red;
}

Color evalBgColor(int cpForUs) {
  if (cpForUs > 100) return Colors.green[900]!;
  if (cpForUs > 30) return Colors.green[800]!.withValues(alpha: 0.7);
  if (cpForUs > -30) return Colors.grey[800]!;
  if (cpForUs > -100) return Colors.orange[900]!.withValues(alpha: 0.7);
  return Colors.red[900]!;
}

Color evalTextColor(int cpForUs) {
  if (cpForUs > 30) return Colors.green[200]!;
  if (cpForUs > -30) return Colors.grey[300]!;
  return Colors.red[200]!;
}

// ── Other metric colors ───────────────────────────────────────────────────

Color easeColor(double ease) {
  if (ease > 0.8) return Colors.green[300]!;
  if (ease > 0.6) return Colors.yellow[300]!;
  return Colors.orange[300]!;
}

Color cplColor(double cpl) {
  if (cpl < 5) return Colors.green[300]!;
  if (cpl < 15) return Colors.lightGreen[300]!;
  if (cpl < 30) return Colors.yellow[300]!;
  return Colors.orange[300]!;
}

Color trapColor(double trap) {
  if (trap > 0.5) return Colors.red[300]!;
  if (trap > 0.2) return Colors.orange[300]!;
  return Colors.yellow[300]!;
}

Color vColor(double v) {
  if (v > 0.65) return Colors.green[300]!;
  if (v > 0.55) return Colors.green[200]!;
  if (v > 0.45) return Colors.grey[400]!;
  return Colors.orange[300]!;
}
