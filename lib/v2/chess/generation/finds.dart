import 'dart:math' as math;

import '../fen.dart';
import 'search_node.dart';
import 'traps.dart';

/// The positions worth pointing out in a finished search: read off the tree
/// the search already built, every move of ours followed, so finding them
/// costs no engine time of its own.
///
/// Four kinds, each a plain rule over the scores the tree holds:
///
/// * a trap — a reply the opponent plays at least a fifth of the time that
///   throws away half a pawn or more against their best ([trapsOf]);
/// * our only move — one move of ours holds and every other loses a pawn
///   and a half more;
/// * their only move — one reply holds the opponent's position, the rest
///   lose a pawn and a half more, and they find it less than half the time;
/// * a practical choice — the move worth most against the modelled opponent
///   is not the engine's best, and what it gives up is paid back in games.

/// What a find is.
enum FindKind { trap, onlyMove, theirOnlyMove, practical }

/// One position worth looking at, and the way to it.
final class Find {
  const Find({
    required this.kind,
    required this.sans,
    required this.ply,
    required this.keyPly,
    required this.fen,
    required this.evalCp,
    required this.lossCp,
    required this.share,
    required this.reach,
    required this.worth,
  });

  final FindKind kind;

  /// The line from the search's root, in SAN: to the position and on past
  /// it — the answer, or the punishment of a trap.
  final List<String> sans;

  /// How many of [sans] lead to the position.
  final int ply;

  /// Which of [sans] is the move the find is about: the blunder of a trap,
  /// the one move that holds, the practical choice.
  final int keyPly;

  /// The position.
  final Fen fen;

  /// The engine's score of the position, from the searched side, in
  /// centipawns.
  final int evalCp;

  /// What is at stake, in centipawns, never negative: what the trap throws
  /// away, what the other moves lose against the only one, what the
  /// practical choice gives up against the engine's best.
  final int lossCp;

  /// How often the opponent plays the move: the blunder of a trap, the one
  /// saving reply. Zero where the move is ours.
  final double share;

  /// How often a game from the root reaches the position: the product of
  /// the opponent's shares on the way, ours counted as sure.
  final double reach;

  /// What the finds are ranked by, most first: how often it comes up times
  /// how much it matters.
  final double worth;

  /// [sans] played after [prefix]: the same find seen from further back.
  Find after(List<String> prefix) => prefix.isEmpty
      ? this
      : Find(
          kind: kind,
          sans: [...prefix, ...sans],
          ply: ply + prefix.length,
          keyPly: keyPly + prefix.length,
          fen: fen,
          evalCp: evalCp,
          lossCp: lossCp,
          share: share,
          reach: reach,
          worth: worth,
        );
}

/// A move's loss counts up to this much when finds are ranked, so a missed
/// mate does not outrank a likelier piece by its size alone.
const findRankLossCapCp = 300;

/// What the other moves must lose against the only one that holds.
const onlyMoveGapCp = 150;

/// Past this the side is already lost or winning, and one move holding is
/// not news: our best must stand at least this well, and a winning second
/// move means the first was not the only one.
const onlyMoveFloorCp = -150;
const onlyMoveCeilingCp = 300;

/// What a practical choice may give up against the engine's best and still
/// be the same move ([practicalMinLossCp] less is a tie), and what it must
/// win back in expected score.
const practicalMinLossCp = 30;
const practicalMinGain = 0.02;

/// The most finds one search hands back, the most worth first.
const findsPerSearch = 1000;

/// Every find in [root], the most worth first, at most [limit].
List<Find> findsOf(SearchNode root, {int limit = findsPerSearch}) {
  final found = <(FindKind, String), Find>{};
  void keep(Find find) {
    final key = (find.kind, find.fen.position);
    final held = found[key];
    if (held == null || find.worth > held.worth) found[key] = find;
  }

  for (final trap in trapsOf(root, everyMove: true)) {
    keep(
      Find(
        kind: FindKind.trap,
        sans: [for (final move in trap.moves) move.move.san],
        ply: trap.toTrap.length + 1,
        keyPly: trap.toTrap.length,
        fen: trap.blunder.after,
        evalCp: _evalAfter(root, trap),
        lossCp: trap.lossCp,
        share: trap.share,
        reach: trap.reach,
        worth: trap.springs * math.min(trap.lossCp, findRankLossCapCp),
      ),
    );
  }

  void walk(SearchNode node, List<String> sofar, double reach) {
    switch (node) {
      case OurNode(:final candidates):
        _ourOnlyMove(node, sofar, reach, keep);
        _practical(node, sofar, reach, keep);
        for (final c in candidates) {
          walk(c.child, [...sofar, c.move.san], reach);
        }
      case OpponentNode(:final replies):
        _theirOnlyMove(node, sofar, reach, keep);
        for (final r in replies) {
          walk(r.child, [...sofar, r.move.san], reach * r.probability);
        }
      case TerminalNode() || HorizonNode() || FrontierNode():
        return;
    }
  }

  walk(root, const [], 1);
  final ranked = found.values.toList()
    ..sort((a, b) {
      final byWorth = b.worth.compareTo(a.worth);
      return byWorth != 0
          ? byWorth
          : a.sans.join(' ').compareTo(b.sans.join(' '));
    });
  return ranked.length > limit ? ranked.sublist(0, limit) : ranked;
}

/// The score of the position a trap's blunder leaves, from the tree.
int _evalAfter(SearchNode root, Trap trap) {
  var node = root;
  for (final move in [...trap.toTrap, trap.blunder]) {
    final next = _child(node, move.move.uci);
    if (next == null) return 0;
    node = next;
  }
  return node.evalForUs.cp;
}

SearchNode? _child(SearchNode node, String uci) => switch (node) {
  OurNode(:final candidates) =>
    candidates.where((c) => c.move.uci == uci).firstOrNull?.child,
  OpponentNode(:final replies) =>
    replies.where((r) => r.move.uci == uci).firstOrNull?.child,
  _ => null,
};

/// One move of ours holds and the rest lose [onlyMoveGapCp] more.
void _ourOnlyMove(
  OurNode node,
  List<String> sofar,
  double reach,
  void Function(Find) keep,
) {
  final scored = [
    for (final c in node.candidates)
      if (c.child.evaluated) c,
  ]..sort((a, b) => b.evalForUs.cp.compareTo(a.evalForUs.cp));
  if (scored.length < 2) return;
  final best = scored[0].evalForUs.cp;
  final second = scored[1].evalForUs.cp;
  final gap = best - second;
  if (best < onlyMoveFloorCp || second > onlyMoveCeilingCp) return;
  if (gap < onlyMoveGapCp) return;
  keep(
    Find(
      kind: FindKind.onlyMove,
      sans: [...sofar, scored[0].move.san],
      ply: sofar.length,
      keyPly: sofar.length,
      fen: node.fen,
      evalCp: node.evalForUs.cp,
      lossCp: gap,
      share: 0,
      reach: reach,
      worth: reach * math.min(gap, findRankLossCapCp),
    ),
  );
}

/// One reply holds the opponent's position and they find it less than half
/// the time.
void _theirOnlyMove(
  OpponentNode node,
  List<String> sofar,
  double reach,
  void Function(Find) keep,
) {
  final scored = [
    for (final r in node.replies)
      if (r.child.evaluated) r,
  ]..sort((a, b) => a.child.evalForUs.cp.compareTo(b.child.evalForUs.cp));
  if (scored.length < 2) return;
  final best = scored[0];
  // From our side: their best must leave them standing, their second must
  // not also be the end of us.
  final bestCp = best.child.evalForUs.cp;
  final secondCp = scored[1].child.evalForUs.cp;
  final gap = secondCp - bestCp;
  if (-bestCp < onlyMoveFloorCp || -secondCp > onlyMoveCeilingCp) return;
  if (gap < onlyMoveGapCp || best.probability >= 0.5) return;
  keep(
    Find(
      kind: FindKind.theirOnlyMove,
      sans: [...sofar, best.move.san],
      ply: sofar.length,
      keyPly: sofar.length,
      fen: node.fen,
      evalCp: node.evalForUs.cp,
      lossCp: gap,
      share: best.probability,
      reach: reach,
      worth: reach * (1 - best.probability) * math.min(gap, findRankLossCapCp),
    ),
  );
}

/// The move worth most against the opponent is not the engine's best, and
/// its subtree was searched, so its worth is more than the engine's word.
void _practical(
  OurNode node,
  List<String> sofar,
  double reach,
  void Function(Find) keep,
) {
  final pick = node.chosen;
  if (pick.child is! OurNode && pick.child is! OpponentNode) return;
  final engineBest = node.candidates.reduce(
    (a, b) => b.evalForUs.cp > a.evalForUs.cp ? b : a,
  );
  if (identical(engineBest, pick)) return;
  final given = engineBest.evalForUs.cp - pick.evalForUs.cp;
  final gain = pick.child.valuation.value - engineBest.child.valuation.value;
  if (given < practicalMinLossCp || gain < practicalMinGain) return;
  keep(
    Find(
      kind: FindKind.practical,
      sans: [...sofar, pick.move.san],
      ply: sofar.length,
      keyPly: sofar.length,
      fen: node.fen,
      evalCp: node.evalForUs.cp,
      lossCp: given,
      share: 0,
      reach: reach,
      // A gain of a tenth of a point is worth as much as a 300 cp trap.
      worth: reach * gain * findRankLossCapCp * 10,
    ),
  );
}
