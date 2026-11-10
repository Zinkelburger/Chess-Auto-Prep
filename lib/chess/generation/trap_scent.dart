import 'dart:math' as math;

import 'finds.dart' show findMaxGivenCp, trapMinEvalCp, trapMinGainCp;
import 'search_node.dart';
import 'traps.dart' show trapRepliesAt;

/// The traps in the lines below a position: how many, and how often a game
/// from the position springs the likeliest of them, our own moves counted
/// as sure.
///
/// This is what tells a reader which move to follow: a row of the
/// Expectimax table says how many traps wait under it before any of them is
/// on the board.
typedef TrapScent = ({int traps, double likeliest});

const TrapScent noTraps = (traps: 0, likeliest: 0);

/// The traps below our positions and below the opponent's replies, kept by
/// node: a search hands out the same subtree for as long as nothing under
/// it changes, so only what a run has touched is counted again.
final _underOurs = Expando<TrapScent>();
final _underReplies = Expando<TrapScent>();

/// The traps set at [node] and in every line below it, by the Positions
/// list's rule: a reply played often enough that loses enough
/// ([trapRepliesAt]), leaves us at least level and, where a move of ours
/// led to it, better than our best move there would have.
///
/// [bestBefore] is the engine's score of our best move at the position
/// before [node], when [node] is the opponent's and one of our moves led to
/// it; without it the traps set at [node] itself are counted as they stand.
/// A move of ours that gives up more than a line may is not followed.
///
/// A trap two move orders reach is counted on each: the count is of what
/// lies below, not of distinct positions.
TrapScent trapsBelow(SearchNode node, {int? bestBefore}) => switch (node) {
  OurNode() => _underOurs[node] ??= _belowOurs(node),
  OpponentNode() => _sum(
    _setAt(node, bestBefore),
    _underReplies[node] ??= _belowReplies(node),
  ),
  TerminalNode() || HorizonNode() || FrontierNode() => noTraps,
};

TrapScent _belowOurs(OurNode node) {
  final best = node.candidates
      .map((c) => c.evalForUs.cp)
      .reduce((a, b) => a > b ? a : b);
  var scent = noTraps;
  for (final candidate in node.candidates) {
    if (best - candidate.evalForUs.cp > findMaxGivenCp) continue;
    final below = trapsBelow(candidate.child, bestBefore: best);
    // Our moves are alternatives: the traps under each are all there to
    // find, and the likeliest is the likeliest under any one of them.
    scent = (
      traps: scent.traps + below.traps,
      likeliest: math.max(scent.likeliest, below.likeliest),
    );
  }
  return scent;
}

TrapScent _belowReplies(OpponentNode node) {
  var scent = noTraps;
  for (final reply in node.replies) {
    final below = trapsBelow(reply.child);
    scent = (
      traps: scent.traps + below.traps,
      likeliest: math.max(scent.likeliest, reply.probability * below.likeliest),
    );
  }
  return scent;
}

/// The traps the replies at [node] themselves are.
TrapScent _setAt(OpponentNode node, int? bestBefore) {
  var scent = noTraps;
  for (final (reply, _) in trapRepliesAt(node)) {
    final cp = reply.child.evalForUs.cp;
    if (cp < trapMinEvalCp) continue;
    if (bestBefore != null && cp - bestBefore < trapMinGainCp) continue;
    scent = (
      traps: scent.traps + 1,
      likeliest: math.max(scent.likeliest, reply.probability),
    );
  }
  return scent;
}

TrapScent _sum(TrapScent a, TrapScent b) =>
    (traps: a.traps + b.traps, likeliest: math.max(a.likeliest, b.likeliest));
