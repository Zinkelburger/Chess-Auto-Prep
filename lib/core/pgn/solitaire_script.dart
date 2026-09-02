/// The order a solitaire session walks a game in.
///
/// A plain session is the mainline from some ply to the end. A variations
/// drill also descends into every saved sideline, in the order the movetext
/// prints them: a move, then the alternatives to it (each opened by its first
/// move as a shown premise), then the line resumes. Building that order once,
/// up front, is what lets [SolitaireController] stay a cursor over a list and
/// know nothing about trees.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/move_tree.dart';
import '../../utils/chess_utils.dart' show isNullMoveSan;
import 'viewer_game_model.dart';

/// One move the solver meets, with where it lives in the game.
class SolitaireStep {
  /// The move, in SAN.
  final String san;

  /// Board the move is played from.
  final Position before;

  /// Mainline index of this move (`moveHistory[mainlinePly]`); null for a
  /// sideline move.
  final int? mainlinePly;

  /// The sideline node, when this is a sideline move.
  final MoveNode? node;

  /// Mainline ply the sideline branches from; -1 for a mainline move.
  final int branchPly;

  /// The sideline node this move is played from, or null when it is played
  /// from a mainline position (a mainline move, or a sideline root).
  final MoveNode? parentNode;

  /// The first move of a sideline. It is shown, never guessed — it is the
  /// premise of the line ("suppose instead 12.Be2").
  final bool isPremise;

  const SolitaireStep({
    required this.san,
    required this.before,
    this.mainlinePly,
    this.node,
    this.branchPly = -1,
    this.parentNode,
    this.isPremise = false,
  });

  bool get isMainline => node == null;
  int? get parentNodeId => parentNode?.id;
  bool get isWhiteMove => before.turn == Side.white;
}

/// The walk a session follows plus what is already on show when it begins.
class SolitaireScript {
  final List<SolitaireStep> steps;

  /// Mainline moves visible before the first guess (`moveHistory[0..)`).
  final int startMainlinePly;

  /// Whether sidelines are part of the walk (and hidden until reached).
  final bool includesVariations;

  const SolitaireScript({
    required this.steps,
    required this.startMainlinePly,
    required this.includesVariations,
  });

  bool get isEmpty => steps.isEmpty;

  /// How many steps the user will be asked to guess (as [userIsWhite]).
  int userMoveCount(bool userIsWhite) =>
      steps.where((s) => !s.isPremise && s.isWhiteMove == userIsWhite).length;
}

/// Lay out a session over [model]'s game.
///
/// [fromMainlinePly] mainline moves stay visible and are skipped. With
/// [includeVariations], every saved (non-ephemeral) sideline branching at or
/// after that ply is drilled in movetext order; ephemeral scratch lines are
/// never part of a drill. Null-move plies (`--` / `Z0`) are walked through
/// but never asked.
SolitaireScript buildSolitaireScript(
  ViewerGameModel model, {
  int fromMainlinePly = 0,
  bool includeVariations = false,
}) {
  final history = model.moveHistory;
  final mainline = model.mainline;
  final from = fromMainlinePly.clamp(0, history.length);
  final steps = <SolitaireStep>[];

  /// Walk one sideline starting at [first], played from [before].
  /// [alternatives] are [first]'s siblings — alternatives to the same move —
  /// which the movetext prints right after it, so they are drilled right
  /// after it is guessed and before its line resumes.
  void walkLine(
    MoveNode first,
    Position before,
    List<MoveNode> alternatives,
    int branchPly,
    MoveNode? parentNode, {
    required bool premise,
  }) {
    var node = first;
    var pos = before;
    var alts = alternatives;
    var parent = parentNode;
    var isPremise = premise;
    while (true) {
      if (!isNullMoveSan(node.san)) {
        steps.add(
          SolitaireStep(
            san: node.san,
            before: pos,
            node: node,
            branchPly: branchPly,
            parentNode: parent,
            isPremise: isPremise,
          ),
        );
        isPremise = false;
      }
      for (final alt in alts) {
        if (alt.isEphemeral) continue;
        walkLine(alt, pos, const [], branchPly, parent, premise: true);
      }
      final after = node.positionOrNull;
      if (after == null || node.children.isEmpty) return;
      alts = node.children.skip(1).toList();
      parent = node;
      pos = after;
      node = node.children.first;
    }
  }

  void sidelinesAt(int ply) {
    if (!includeVariations) return;
    final roots = model.variationsByPly[ply];
    if (roots == null) return;
    final before = mainline.tryAt(ply);
    if (before == null) return;
    for (final root in roots) {
      if (root.isEphemeral) continue;
      walkLine(root, before, const [], ply, null, premise: true);
    }
  }

  for (var i = from; i < history.length; i++) {
    final before = mainline.tryAt(i);
    if (before == null) break;
    final san = history[i].san;
    if (!isNullMoveSan(san)) {
      steps.add(SolitaireStep(san: san, before: before, mainlinePly: i));
    }
    sidelinesAt(i);
  }
  // Sidelines that branch after the final move (user-added only).
  sidelinesAt(history.length);

  return SolitaireScript(
    steps: steps,
    startMainlinePly: from,
    includesVariations: includeVariations,
  );
}
