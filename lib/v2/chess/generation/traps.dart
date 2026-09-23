import 'dart:math' as math;

import '../fen.dart';
import 'draft_lines.dart';
import 'eval.dart';
import 'search_node.dart';

/// The traps a finished search walked past: replies the opponent is likely
/// to play that throw away much of what the position was worth, with our
/// punishment after them.
///
/// A trap is the owner's trick-line rule (the October 2025 greedy finder's):
/// a reply the opponent plays at least a fifth of the time that loses at
/// least half a pawn against their best reply there. It is read off the tree
/// the search already built — the replies at every opponent position are
/// scored, because the search scores every position it creates — so finding
/// traps costs no engine time of its own.

/// One trap: the way to it, the tempting reply, and how we answer it.
final class Trap {
  const Trap({
    required this.toTrap,
    required this.blunder,
    required this.punishment,
    required this.share,
    required this.lossCp,
    required this.reach,
    required this.afterBest,
    required this.afterBlunder,
  });

  /// The moves from the search root to the position the opponent is to move
  /// in; empty when the trap is set at the root.
  final List<DraftMove> toTrap;

  /// The tempting reply; never ours.
  final DraftMove blunder;

  /// Our refutation and the search's line after it, at most the
  /// `punishPlies` it was asked for; empty when the search stopped at the
  /// position after the blunder and never answered it.
  final List<DraftMove> punishment;

  /// How often the opponent plays [blunder] at the trap position.
  final double share;

  /// What [blunder] throws away against the opponent's best reply, in
  /// centipawns from our side; always positive.
  final int lossCp;

  /// How often a game from the root reaches the trap position: the product
  /// of the opponent's shares along the way, our own moves counted as sure.
  final double reach;

  /// The engine's score for us after the opponent's best reply.
  final Eval afterBest;

  /// The engine's score for us after [blunder].
  final Eval afterBlunder;

  /// How often playing from the root springs it.
  double get springs => reach * share;

  List<DraftMove> get moves => [...toTrap, blunder, ...punishment];
}

/// A loss is counted up to this many centipawns when traps are ranked, so a
/// missed mate does not outrank a likelier piece blunder by its size alone.
const int trapRankLossCapCp = 300;

/// The most a loss is reported as: a mate against the opponent reads as
/// this, whatever distance the engine gave it.
const int trapLossCapCp = mateBaseCp;

/// Every trap along the lines [root] prepares, the ones most worth knowing
/// first.
///
/// The walk follows our chosen move at each of our positions — the other
/// candidates are not what we would play — and every reply at the opponent's.
/// Two traps that leave the same position after the blunder are one trap,
/// kept where it springs more often. They are ranked by how often they spring
/// times how much they win, the win capped at [trapRankLossCapCp].
List<Trap> trapsOf(
  SearchNode root, {
  double minShare = 0.2,
  int minLossCp = 50,
  int punishPlies = 6,
}) {
  final found = <String, Trap>{};

  void walk(SearchNode node, List<DraftMove> sofar, double reach) {
    switch (node) {
      case OurNode(:final chosen):
        walk(chosen.child, [
          ...sofar,
          _step(node.fen, chosen.move, chosen.child, ours: true),
        ], reach);
      case OpponentNode(:final replies):
        for (final trap in _trapsAt(
          node,
          sofar,
          reach,
          minShare: minShare,
          minLossCp: minLossCp,
          punishPlies: punishPlies,
        )) {
          final key = trap.blunder.after.position;
          final held = found[key];
          if (held == null || trap.springs > held.springs) found[key] = trap;
        }
        for (final reply in replies) {
          walk(reply.child, [
            ...sofar,
            _step(node.fen, reply.move, reply.child, ours: false),
          ], reach * reply.probability);
        }
      case TerminalNode() || HorizonNode() || FrontierNode():
        return;
    }
  }

  walk(root, const [], 1);
  final traps = found.values.toList()
    ..sort((a, b) {
      final byWorth = _worth(b).compareTo(_worth(a));
      return byWorth != 0 ? byWorth : _ucis(a).compareTo(_ucis(b));
    });
  return traps;
}

/// The traps set at [node]: every reply likely enough and bad enough
/// against the opponent's best there. A position with fewer than two scored
/// replies has nothing to compare, so it sets none.
Iterable<Trap> _trapsAt(
  OpponentNode node,
  List<DraftMove> sofar,
  double reach, {
  required double minShare,
  required int minLossCp,
  required int punishPlies,
}) sync* {
  final scored = [
    for (final reply in node.replies)
      if (reply.child.evaluated) reply,
  ];
  if (scored.length < 2) return;
  final best = scored.reduce(
    (a, b) => b.child.evalForUs.cp < a.child.evalForUs.cp ? b : a,
  );
  for (final reply in scored) {
    if (identical(reply, best) || reply.probability < minShare) continue;
    final loss = math.min(
      reply.child.evalForUs.cp - best.child.evalForUs.cp,
      trapLossCapCp,
    );
    if (loss < minLossCp) continue;
    yield Trap(
      toTrap: List.unmodifiable(sofar),
      blunder: _step(node.fen, reply.move, reply.child, ours: false),
      punishment: List.unmodifiable(_punishment(reply.child, punishPlies)),
      share: reply.probability,
      lossCp: loss,
      reach: reach,
      afterBest: best.child.evalForUs,
      afterBlunder: reply.child.evalForUs,
    );
  }
}

double _worth(Trap trap) =>
    trap.springs * math.min(trap.lossCp, trapRankLossCapCp);

String _ucis(Trap trap) => trap.moves.map((m) => m.move.uci).join(' ');

/// The search's answer to a blunder: our chosen move at our positions and
/// the opponent's likeliest reply at theirs, until the tree ends or [plies]
/// moves are written.
List<DraftMove> _punishment(SearchNode from, int plies) {
  final moves = <DraftMove>[];
  var node = from;
  while (moves.length < plies) {
    switch (node) {
      case OurNode(:final chosen):
        moves.add(_step(node.fen, chosen.move, chosen.child, ours: true));
        node = chosen.child;
      case OpponentNode(:final replies) when replies.isNotEmpty:
        final likeliest = replies.reduce(
          (a, b) => b.probability > a.probability ? b : a,
        );
        moves.add(
          _step(node.fen, likeliest.move, likeliest.child, ours: false),
        );
        node = likeliest.child;
      default:
        return moves;
    }
  }
  return moves;
}

/// A move as the draft writes it, with what the search thought the position
/// after it was worth.
DraftMove _step(
  Fen from,
  MoveRef move,
  SearchNode child, {
  required bool ours,
}) => DraftMove(
  move: move,
  before: from.position,
  after: child.fen,
  value: child.valuation.value,
  ours: ours,
);

/// [plan] with each of [traps] as a line of its own after the plan's, so a
/// draft holds every trap the search found and can be dragged into the
/// chapter like any other line. A trap a kept line already walks — one is
/// the start of the other — is not written again.
DraftPlan withTraps(DraftPlan plan, List<Trap> traps) {
  final written = [for (final entry in plan.entries) entry.line.ucis.join(' ')];
  final added = <DraftEntry>[];
  for (final trap in traps) {
    final line = DraftLine(moves: trap.moves, reach: trap.springs);
    final ucis = line.ucis.join(' ');
    if (written.any(
      (kept) =>
          kept == ucis ||
          kept.startsWith('$ucis ') ||
          ucis.startsWith('$kept '),
    )) {
      continue;
    }
    written.add(ucis);
    added.add(DraftEntry(line: line));
  }
  if (added.isEmpty) return plan;
  return DraftPlan(
    entries: List.unmodifiable([...plan.entries, ...added]),
    folded: plan.folded,
    dropped: plan.dropped,
    alreadyThere: plan.alreadyThere,
  );
}
