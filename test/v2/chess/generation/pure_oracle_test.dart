import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

/// Thirty trees solved independently, in Python, by a script that knows
/// nothing about this code: `test/fixtures/generate_pure_oracles.py`. Each
/// node records the engine score it was given, the probability of the move
/// that reaches it, and the value the answer sheet says it has; our nodes
/// also record which move the search is supposed to come out with.
///
/// The positions are stand-ins — every node carries the same placement and a
/// made-up move name — because what is being checked here is the arithmetic
/// and the ordering, not the chess. `pure_search_oracle_test.dart` lays the
/// same trees out on a board and drives the real search through them; this
/// one keeps all thirty, including the five whose leaves pair a terminal
/// value with an engine score no board would pair it with.
const _oracles = 'test/fixtures/pure_expectimax_oracles.json';

/// The oracle stores engine scores the way UCI reports them, from the side to
/// move, which is the same convention [PositionEvaluator] answers in. The
/// conversion is the production one, so a sign error in it cannot be hidden
/// by the same sign error here.
Eval evalForUs(Map<String, Object?> node, {required Side us}) {
  final cp = Eval(node['engine_eval_cp']! as int);
  return cp.forUs(us, sideToMoveIn(node));
}

/// The side to move at [node], read from the oracle's FEN.
Side sideToMoveIn(Map<String, Object?> node) =>
    Fen(node['fen']! as String).whiteToMove ? Side.white : Side.black;

MoveRef _moveOf(Map<String, Object?> node) =>
    MoveRef(uci: node['move_uci']! as String, san: node['move_san']! as String);

/// The oracle records a finished game's value directly; a [TerminalNode]
/// works it out from who has no move, so a win is written as a mate with the
/// opponent to move and a loss as one with us to move.
TerminalNode _terminal(Map<String, Object?> node, double value, Eval eval) {
  final fen = Fen(node['fen']! as String);
  if (value == 0.5) {
    return TerminalNode(
      fen: fen,
      evalForUs: eval,
      kind: TerminalKind.stalemate,
      ourTurn: true,
    );
  }
  return TerminalNode(
    fen: fen,
    evalForUs: eval,
    kind: TerminalKind.checkmate,
    ourTurn: value == 0,
  );
}

/// Rebuilds one oracle node with the search's own types and checks it.
///
/// Children are rebuilt first, so every node in the tree is checked, even the
/// ones the loss window then rejects. The window and the node factories are
/// the production ones: the test supplies the numbers and the shape, never
/// the arithmetic.
SearchNode _rebuild(
  Map<String, Object?> node, {
  required Side us,
  required int lossLimitCp,
}) {
  final fen = Fen(node['fen']! as String);
  final eval = evalForUs(node, us: us);
  final children = (node['children'] as List<Object?>? ?? const [])
      .map((child) => child! as Map<String, Object?>)
      .toList();
  final built = [
    for (final child in children)
      (data: child, node: _rebuild(child, us: us, lossLimitCp: lossLimitCp)),
  ];
  final terminal = node['terminal_value'] as num?;
  final SearchNode rebuilt;
  if (terminal != null) {
    rebuilt = _terminal(node, terminal.toDouble(), eval);
  } else if (built.isEmpty) {
    rebuilt = HorizonNode(fen: fen, evalForUs: eval);
  } else if (sideToMoveIn(node) == us) {
    rebuilt = OurNode.over(
      fen: fen,
      evalForUs: eval,
      candidates: admittedMoves([
        for (final child in built)
          CandidateMove(move: _moveOf(child.data), child: child.node),
      ], lossLimitCp: lossLimitCp),
    );
  } else {
    rebuilt = OpponentNode.over(
      fen: fen,
      evalForUs: eval,
      replies: [
        for (final child in built)
          ReplyMove(
            move: _moveOf(child.data),
            probability: (child.data['move_probability']! as num).toDouble(),
            child: child.node,
          ),
      ],
    );
  }
  _expectMatches(rebuilt, node);
  return rebuilt;
}

void _expectMatches(SearchNode node, Map<String, Object?> expected) {
  final value = (expected['expected_value']! as num).toDouble();
  final where = 'node ${expected['id']}';
  expect(node.valuation.value, closeTo(value, 1e-12), reason: where);
  expect(node.valuation.lower, closeTo(value, 1e-12), reason: where);
  expect(node.valuation.upper, closeTo(value, 1e-12), reason: where);
  final pick = expected['expected_pick'] as int?;
  if (pick == null) return;
  final children = expected['children']! as List<Object?>;
  final chosen = children
      .map((child) => child! as Map<String, Object?>)
      .firstWhere((child) => child['id'] == pick);
  expect((node as OurNode).chosen.move.uci, chosen['move_uci'], reason: where);
}

void main() {
  test('solves the thirty oracle trees, node by node', () {
    final cases =
        jsonDecode(File(_oracles).readAsStringSync()) as List<Object?>;
    expect(cases, hasLength(30));
    for (final raw in cases) {
      final data = raw! as Map<String, Object?>;
      final config = data['config']! as Map<String, Object?>;
      final root = _rebuild(
        data['tree']! as Map<String, Object?>,
        us: config['play_as_white']! as bool ? Side.white : Side.black,
        lossLimitCp: config['max_eval_loss_cp']! as int,
      );
      expect(root.valuation.isExact, isTrue);
    }
  });
}
