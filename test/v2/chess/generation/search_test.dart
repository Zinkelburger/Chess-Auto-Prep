import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'search_harness.dart';

void main() {
  test('keeps the moves within the limit and drops the rest', () async {
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: matesForUs(),
    );
    final tree = treeOf(result) as OurNode;
    expect(
      tree.candidates.map((c) => c.move.uci),
      unorderedEquals(['e2e3', 'e2e4']),
    );
  });

  test('saturates both mates to a win and orders them by score', () async {
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: matesForUs(),
    );
    final tree = treeOf(result) as OurNode;
    expect(tree.valuation.value, 1);
    expect(tree.valuation.isExact, isTrue);
    // Both mates are worth exactly 1, so the score decides, not the name.
    expect(tree.chosen.move.uci, 'e2e4');
  });

  test('admits every legal move when they all score the same', () async {
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
    );
    final tree = treeOf(result) as OurNode;
    expect(tree.candidates, hasLength(6));
    expect(tree.valuation.value, closeTo(0.5, 1e-12));
    // Nothing tells the moves apart, so the name breaks the tie.
    expect(tree.chosen.move.uci, 'e1d1');
  });

  test(
    'a checkmate at the root is a loss for the side that is mated',
    () async {
      final evaluator = ScriptedEvaluator();
      final result = await searchFrom(
        foolsMate,
        config: const SearchConfig(side: Side.white),
        evaluator: evaluator,
      );
      final tree = treeOf(result) as TerminalNode;
      expect(tree.kind, TerminalKind.checkmate);
      expect(tree.valuation.value, 0);
      expect(evaluator.asked, isEmpty);
    },
  );

  test('the same checkmate is a win for the other side', () async {
    final result = await searchFrom(
      foolsMate,
      config: const SearchConfig(side: Side.black),
    );
    expect(treeOf(result).valuation.value, 1);
  });

  test('a stalemate at the root is half a point', () async {
    final result = await searchFrom(
      '7k/5Q2/6K1/8/8/8/8/8 b - - 0 1',
      config: const SearchConfig(side: Side.white),
    );
    final tree = treeOf(result) as TerminalNode;
    expect(tree.kind, TerminalKind.stalemate);
    expect(tree.valuation.value, 0.5);
  });

  test('the hundredth quiet half-move ends every line', () async {
    final result = await searchFrom(
      '4k3/8/8/8/8/8/3R4/4K3 w - - 99 60',
      config: const SearchConfig(side: Side.white),
    );
    final tree = treeOf(result) as OurNode;
    expect(
      tree.candidates.map((c) => c.child),
      everyElement(
        isA<TerminalNode>().having(
          (node) => node.kind,
          'kind',
          TerminalKind.fiftyMoveRule,
        ),
      ),
    );
    expect(tree.valuation.value, 0.5);
  });

  test('a mate beats every ordinary move at the window', () async {
    // A finished game carries the score an engine would report there, so a
    // mate is +10000 to us and a two-pawn window keeps nothing else.
    final result = await searchFrom(
      '7k/5Q2/6K1/8/8/8/8/8 w - - 0 1',
      config: const SearchConfig(side: Side.white, horizonPlies: 4),
    );
    final tree = treeOf(result) as OurNode;
    expect(
      tree.candidates.map((c) => c.child),
      everyElement(
        isA<TerminalNode>().having(
          (node) => node.kind,
          'kind',
          TerminalKind.checkmate,
        ),
      ),
    );
    expect(tree.chosen.evalForUs.cp, mateBaseCp);
    expect(tree.valuation.value, 1);
    expect(tree.valuation.isExact, isTrue);
  });

  test('a draw is a zero on the same scale as an engine score', () async {
    // The knight can take the last square from a bare king; every other move
    // is five pawns worse, so the stalemate — zero, like an equal position —
    // is the only move the two-pawn window keeps.
    final result = await searchFrom(
      '7k/8/2N3K1/8/8/p7/P7/8 w - - 0 1',
      config: const SearchConfig(side: Side.white, horizonPlies: 4),
      evaluator: ScriptedEvaluator(fallback: 500),
    );
    final tree = treeOf(result) as OurNode;
    expect(tree.candidates, hasLength(1));
    expect(tree.chosen.move.uci, 'c6e7');
    expect(tree.chosen.evalForUs.cp, 0);
    expect(tree.valuation.value, 0.5);
    expect(tree.valuation.isExact, isTrue);
  });

  test('shares out a policy that does not sum to one', () async {
    final root = positionOf(afterE4);
    final result = await searchFrom(
      afterE4,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: ScriptedEvaluator(
        scores: {
          afterUci(root, 'e7e5').fen: 100,
          afterUci(root, 'c7c5').fen: -200,
        },
      ),
      policy: const ScriptedPolicy({'e7e5': 0.6, 'c7c5': 0.3}),
    );
    final tree = treeOf(result) as OpponentNode;
    expect(tree.replies, hasLength(2));
    expect(
      {for (final reply in tree.replies) reply.move.uci: reply.probability},
      {'c7c5': closeTo(1 / 3, 1e-12), 'e7e5': closeTo(2 / 3, 1e-12)},
    );
    expect(
      tree.valuation.value,
      closeTo(
        2 / 3 * expectedScore(const Eval(100)) +
            1 / 3 * expectedScore(const Eval(-200)),
        1e-12,
      ),
    );
  });

  test('one node\'s moves are evaluated together', () async {
    // The engine is the slow part of a build, and the six positions after
    // our six moves do not depend on each other.
    final evaluator = CountingEvaluator();
    await searchFrom(
      kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: evaluator,
    );
    expect(evaluator.peakInFlight, 6);
  });
}
