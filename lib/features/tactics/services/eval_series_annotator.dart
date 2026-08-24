/// Writing an engine pass's per-ply scores onto a game's moves as standard
/// `[%eval]` comments.
///
/// The tactics pass searches every position it walks through on the way to
/// finding puzzles — the position before each of my moves and the position
/// after it, which between them is every position in the game. It used to
/// reduce all of that to three mistake counts and drop the scores, so opening
/// the same game in the viewer searched it from scratch to draw a graph the
/// pass already had the numbers for. This is the other half of that: the
/// series on its way into the games cache, where the viewer reads it back.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/pgn_comment_utils.dart';

/// One ply's engine score, normalized to White's perspective — the sign
/// convention `[%eval]` comments use, regardless of whose move it was.
class PlyEval {
  const PlyEval({this.cp, this.mate, required this.depth});

  /// Centipawns, positive = good for White. Ignored when [mate] is set.
  final int? cp;

  /// Mate in N, positive = White mates.
  final int? mate;

  /// Search depth that produced the score, written into the comment so a
  /// later reader can tell how much to trust it.
  final int depth;
}

/// [moveNodes] with each ply's score written onto it, rendered as movetext —
/// or null when too many plies went unscored for a reader to accept the game
/// as analyzed.
///
/// [plyEvals] is indexed by 0-based ply and holds the score of the position
/// *after* that move, matching where `[%eval]` comments attach. Entries may be
/// null; [lastPlyIsCheckmate] excuses the final one, which legitimately
/// carries no score (a mate-0 has no sign, so the reader takes the result off
/// the board instead).
///
/// The budget is checked before anything is written, so a game that does not
/// clear it leaves [moveNodes] untouched rather than half-annotated.
String? annotateMovetextWithEvals({
  required List<PgnNodeData> moveNodes,
  required List<PlyEval?> plyEvals,
  required bool lastPlyIsCheckmate,
  required String result,
}) {
  if (moveNodes.isEmpty) return null;

  var missing = 0;
  for (var i = 0; i < moveNodes.length; i++) {
    if (i < plyEvals.length && plyEvals[i] != null) continue;
    if (i == moveNodes.length - 1 && lastPlyIsCheckmate) continue;
    missing++;
  }
  if (missing > kMaxUnevaluatedPlies) return null;

  for (var i = 0; i < moveNodes.length; i++) {
    final eval = i < plyEvals.length ? plyEvals[i] : null;
    if (eval == null) continue;
    final value = formatEvalCommentValue(
      scoreCp: eval.cp,
      scoreMate: eval.mate,
      depth: eval.depth,
    );
    final node = moveNodes[i];
    final comments = node.comments;
    // Written into the existing comment rather than beside it, so the clock
    // annotations these games arrive with survive — they are what the tempo
    // flaw tags read on the next pass.
    if (comments != null && comments.isNotEmpty) {
      comments[0] = setEvalInComment(comments[0], value);
    } else {
      node.comments = ['[%eval $value]'];
    }
  }
  return buildMovetext(moveNodes, result: result);
}
