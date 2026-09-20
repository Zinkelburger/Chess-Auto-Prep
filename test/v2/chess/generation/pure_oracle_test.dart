import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/move_admission.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:flutter_test/flutter_test.dart';

/// Thirty trees solved independently, in Python, by a script that knows
/// nothing about this code: `test/fixtures/generate_pure_oracles.py`. Each
/// node records the engine score it was given, the probability of the move
/// that reaches it, and the value the answer sheet says it has; our nodes
/// also record which move the search is supposed to come out with.
///
/// The positions are stand-ins — every node carries the same placement and a
/// made-up move name — because what is being checked is the arithmetic and
/// the ordering, not the chess. The rules that need a board are checked in
/// `search_test.dart`, against real positions.
const _oracles = 'test/fixtures/pure_expectimax_oracles.json';

/// The oracle stores engine scores the way UCI reports them, from the side to
/// move, which is the same convention [PositionEvaluator] answers in.
Eval _evalForUs(Map<String, Object?> node, {required bool playAsWhite}) {
  final cp = node['engine_eval_cp']! as int;
  final ourTurn = Fen(node['fen']! as String).whiteToMove == playAsWhite;
  return Eval(ourTurn ? cp : -cp);
}

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
  required bool playAsWhite,
  required int lossLimitCp,
}) {
  final fen = Fen(node['fen']! as String);
  final eval = _evalForUs(node, playAsWhite: playAsWhite);
  final children = (node['children'] as List<Object?>? ?? const [])
      .map((child) => child! as Map<String, Object?>)
      .toList();
  final built = [
    for (final child in children)
      (
        data: child,
        node: _rebuild(
          child,
          playAsWhite: playAsWhite,
          lossLimitCp: lossLimitCp,
        ),
      ),
  ];
  final terminal = node['terminal_value'] as num?;
  final SearchNode rebuilt;
  if (terminal != null) {
    rebuilt = _terminal(node, terminal.toDouble(), eval);
  } else if (built.isEmpty) {
    rebuilt = HorizonNode(fen: fen, evalForUs: eval);
  } else if (fen.whiteToMove == playAsWhite) {
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
        playAsWhite: config['play_as_white']! as bool,
        lossLimitCp: config['max_eval_loss_cp']! as int,
      );
      expect(root.valuation.isExact, isTrue);
    }
  });
}
