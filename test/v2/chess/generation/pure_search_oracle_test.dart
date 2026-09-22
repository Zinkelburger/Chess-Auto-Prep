import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/legal_moves.dart';
import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:chess_auto_prep/v2/chess/generation/terminal.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';

import 'scripted_sources.dart';

/// The thirty independently solved trees of `generate_pure_oracles.py`, run
/// through [buildSearchTree] itself rather than rebuilt out of its parts.
///
/// The fixture is abstract: made-up move names, one placeholder placement,
/// and two to four children a node. So it is laid out on a real board first.
/// One knight moves at each half-move from the root — c4, then c5, then f4,
/// then f5 — and a fixture node's children are given that knight's first
/// quiet moves in name order. Two different paths therefore always end on two
/// different placements, which is what lets a scripted engine and a scripted
/// model answer per position: the engine reads the fixture's score off the
/// position the move reached, and the model reads the fixture's probabilities
/// off the position the opponent is thinking in.
///
/// Every legal move the fixture did not use is answered with a score far past
/// a mate against us, so the loss window rejects it and the tree the search
/// builds has exactly the fixture's shape. What is then compared, node by
/// node, is everything the search decides and the arithmetic oracle cannot
/// see: the horizon, the move the window admitted, the BFS order finishing
/// the tree, the probabilities, the sign of every score, and the value,
/// bounds and pick at every node.
const _oracles = 'test/fixtures/pure_expectimax_oracles.json';

/// Two knights a side with a blocked pawn each, so neither side is ever down
/// to bare pieces, and the kings out of the way in opposite corners. Nothing
/// here can be captured, checked or mated within four half-moves.
const _board = '7k/8/8/2n2n2/2N2N2/1p6/1P6/K7 w - - 0 1';

/// The piece that moves at each half-move from the root.
const _movers = ['c4', 'c5', 'f4', 'f5'];

/// What the engine says about a position the fixture never mentions: so far
/// past a mate against us that no window can admit the move that reached it.
const _rejected = 20000;

/// One fixture tree, and what it takes to play it out.
final class _Case {
  _Case({required this.us, required this.lossLimitCp});

  final Side us;
  final int lossLimitCp;

  /// What the engine answers, by position.
  final Map<String, int> scores = {};

  /// What the model answers, by the position the opponent is thinking in.
  final Map<String, Map<String, double>> policies = {};

  /// The move that reaches each fixture node, by the fixture's node id.
  final Map<int, String> uciById = {};
}

List<Map<String, Object?>> _childrenOf(Map<String, Object?> node) => [
  for (final child in node['children'] as List<Object?>? ?? const [])
    child! as Map<String, Object?>,
];

Side _sideToMove(Map<String, Object?> node) =>
    Fen(node['fen']! as String).whiteToMove ? Side.white : Side.black;

/// The score an engine would report at [node], from the side to move.
///
/// A fixture leaf carries an abstract terminal value instead of a finished
/// game, so it is played as the saturated score that is worth the same: the
/// score this search and the builder that shipped both write in for a real
/// terminal.
int _reportedScore(Map<String, Object?> node, Side us) {
  final terminal = node['terminal_value'] as num?;
  if (terminal == null) return node['engine_eval_cp']! as int;
  final forUs = terminal == 0.5
      ? 0
      : (terminal == 1 ? mateBaseCp : -mateBaseCp);
  return us == _sideToMove(node) ? forUs : -forUs;
}

int _evalForUs(Map<String, Object?> node, Side us) {
  final stm = _sideToMove(node);
  return Eval(_reportedScore(node, us)).forUs(us, stm).cp;
}

/// The mover's first [count] moves that change nothing but its own square:
/// no capture, no check, no finished game, and no position this tree has
/// already used, so one position never has to answer for two nodes.
List<NamedMove> _quietMoves(
  Position position, {
  required String from,
  required int count,
  required Set<String> used,
}) {
  final origin = Square.fromName(from);
  final quiet = <NamedMove>[];
  for (final named in legalMovesOf(position)) {
    if (named.move.from != origin) continue;
    if (position.board.pieceAt(named.move.to) != null) continue;
    final after = position.play(named.move);
    final ended = terminalKind(after, [repetitionKey(Fen(after.fen))]) != null;
    if (ended || after.isCheck || used.contains(after.fen)) continue;
    quiet.add(named);
    if (quiet.length == count) break;
  }
  return quiet;
}

/// Writes [node] and everything below it onto the board at [position].
void _layOut(
  _Case fixture,
  Position position,
  Map<String, Object?> node, {
  required int ply,
  required Set<String> used,
}) {
  fixture.scores[position.fen] = _reportedScore(node, fixture.us);
  final children = _childrenOf(node);
  if (children.isEmpty) return;
  final moves = _quietMoves(
    position,
    from: _movers[ply],
    count: children.length,
    used: used,
  );
  expect(moves, hasLength(children.length), reason: 'no room at ply $ply');
  final weights = <String, double>{};
  for (final (index, child) in children.indexed) {
    final named = moves[index];
    fixture.uciById[child['id']! as int] = named.uci;
    weights[named.uci] = (child['move_probability']! as num).toDouble();
    final after = position.play(named.move);
    used.add(after.fen);
    _layOut(fixture, after, child, ply: ply + 1, used: used);
  }
  if (position.turn != fixture.us) fixture.policies[position.fen] = weights;
}

/// The children an engine-loss window keeps, worked out from the fixture's
/// own numbers rather than from the code under test.
List<Map<String, Object?>> _withinWindow(
  List<Map<String, Object?>> children,
  _Case fixture,
) {
  final evals = [for (final child in children) _evalForUs(child, fixture.us)];
  final best = evals.reduce(math.max);
  return [
    for (final (index, child) in children.indexed)
      if (evals[index] >= best - fixture.lossLimitCp) child,
  ];
}

void _expectSame(SearchNode node, Map<String, Object?> expected, _Case f) {
  final where = 'node ${expected['id']}';
  final value = (expected['expected_value']! as num).toDouble();
  expect(node.valuation.value, closeTo(value, 1e-12), reason: where);
  expect(node.valuation.lower, closeTo(value, 1e-12), reason: where);
  expect(node.valuation.upper, closeTo(value, 1e-12), reason: where);
  expect(node.evalForUs.cp, _evalForUs(expected, f.us), reason: where);
  final children = _childrenOf(expected);
  if (children.isEmpty) {
    expect(node, isA<HorizonNode>(), reason: where);
    return;
  }
  if (_sideToMove(expected) == f.us) {
    _expectOurs(node, expected, children, f);
  } else {
    _expectTheirs(node, children, f);
  }
}

/// Our node: the window's survivors, in the order we would play them, and
/// the move the fixture says the search comes out with.
void _expectOurs(
  SearchNode node,
  Map<String, Object?> expected,
  List<Map<String, Object?>> children,
  _Case fixture,
) {
  final where = 'node ${expected['id']}';
  final ours = node as OurNode;
  final admitted = _withinWindow(children, fixture);
  expect(ours.candidates.map((candidate) => candidate.move.uci).toSet(), {
    for (final child in admitted) fixture.uciById[child['id']],
  }, reason: where);
  expect(
    ours.chosen.move.uci,
    fixture.uciById[expected['expected_pick']! as int],
    reason: where,
  );
  for (final candidate in ours.candidates) {
    final child = admitted.firstWhere(
      (child) => fixture.uciById[child['id']] == candidate.move.uci,
    );
    _expectSame(candidate.child, child, fixture);
  }
}

/// The opponent's node: every reply the model gave weight, and its share.
void _expectTheirs(
  SearchNode node,
  List<Map<String, Object?>> children,
  _Case fixture,
) {
  final theirs = node as OpponentNode;
  expect(theirs.replies, hasLength(children.length));
  for (final child in children) {
    final uci = fixture.uciById[child['id']]!;
    final reply = theirs.replies.firstWhere(
      (reply) => reply.move.uci == uci,
      orElse: () => fail('the search played no $uci'),
    );
    final share = (child['move_probability']! as num).toDouble();
    expect(reply.probability, closeTo(share, 1e-12), reason: 'share of $uci');
    _expectSame(reply.child, child, fixture);
  }
}

/// A tree no legal position can produce.
///
/// Ten of the fixtures end their lines with an abstract terminal value — a
/// win, a draw or a loss drawn at random — beside an engine score drawn just
/// as randomly. Chess does not pair the two: a finished game carries the
/// score of the finish. Under one of the opponent's nodes that changes
/// nothing, because the probabilities decide the value there; under one of
/// ours the loss window reads the score, so the fixture's own answer is one
/// no board could give. Those five stay with `pure_oracle_test.dart`, which
/// checks the same arithmetic without a board.
bool _unplayable(Map<String, Object?> node, Side us) {
  final children = _childrenOf(node);
  final ours = _sideToMove(node) == us;
  for (final child in children) {
    if (ours && child['terminal_value'] != null) return true;
    if (_unplayable(child, us)) return true;
  }
  return false;
}

Future<void> _buildAndCheck(Map<String, Object?> data) async {
  final tree = data['tree']! as Map<String, Object?>;
  final config = data['config']! as Map<String, Object?>;
  final fixture = _Case(
    us: config['play_as_white']! as bool ? Side.white : Side.black,
    lossLimitCp: config['max_eval_loss_cp']! as int,
  );
  _layOut(fixture, positionOf(_board), tree, ply: 0, used: {_board});
  final result = await buildSearchTree(
    root: positionOf(_board),
    config: SearchConfig(
      side: fixture.us,
      horizonPlies: config['max_depth']! as int,
      lossLimitCp: fixture.lossLimitCp,
    ),
    evaluator: ScriptedEvaluator(scores: fixture.scores, fallback: _rejected),
    policy: TabulatedPolicy(fixture.policies),
  );
  expect(result, isA<SearchComplete>());
  _expectSame((result as SearchComplete).tree, tree, fixture);
}

void main() {
  test('the search itself solves the oracle trees, node by node', () async {
    final cases =
        jsonDecode(File(_oracles).readAsStringSync()) as List<Object?>;
    expect(cases, hasLength(30));
    var played = 0;
    var setAside = 0;
    for (final raw in cases) {
      final data = raw! as Map<String, Object?>;
      final tree = data['tree']! as Map<String, Object?>;
      final config = data['config']! as Map<String, Object?>;
      final us = config['play_as_white']! as bool ? Side.white : Side.black;
      if (_unplayable(tree, us)) {
        setAside++;
        continue;
      }
      await _buildAndCheck(data);
      played++;
    }
    expect(played, 25);
    expect(setAside, 5);
  });
}
