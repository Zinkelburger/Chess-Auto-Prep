import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_sources.dart';

/// White king and pawn against a bare black king: six legal moves for White,
/// few enough to write down.
const _kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

/// The opponent has one king move everywhere below [_kingAndPawn], so the
/// tests can say what our side does without also modelling a reply.
const _oneReply = ScriptedPolicy({'e8d8': 1});

Future<SearchResult> searchFrom(
  String fen, {
  required SearchConfig config,
  PositionEvaluator? evaluator,
  OpponentPolicy policy = _oneReply,
  CancelSignal? isCancelled,
}) => buildSearchTree(
  root: positionOf(fen),
  config: config,
  evaluator: evaluator ?? ScriptedEvaluator(),
  policy: policy,
  isCancelled: isCancelled ?? () => false,
);

int nodesIn(SearchNode node) => switch (node) {
  OurNode(:final candidates) =>
    1 + candidates.fold(0, (sum, c) => sum + nodesIn(c.child)),
  OpponentNode(:final replies) =>
    1 + replies.fold(0, (sum, r) => sum + nodesIn(r.child)),
  _ => 1,
};

SearchNode treeOf(SearchResult result) => switch (result) {
  SearchComplete(:final tree) => tree,
  SearchIncomplete(:final tree) => tree,
  _ => fail('expected a tree, got $result'),
};

/// Two mates for us, one slightly slower than the other.
///
/// Scores are reported from the side to move, and after one of our moves that
/// is the opponent, so a mate for us is a large negative number here.
ScriptedEvaluator matesForUs() {
  final root = positionOf(_kingAndPawn);
  return ScriptedEvaluator(
    scores: {
      afterUci(root, 'e2e4').fen: -9800,
      afterUci(root, 'e2e3').fen: -9700,
    },
  );
}

const _foolsMate =
    'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  test('keeps the moves within the limit and drops the rest', () async {
    final result = await searchFrom(
      _kingAndPawn,
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
      _kingAndPawn,
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
      _kingAndPawn,
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
        _foolsMate,
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
      _foolsMate,
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

  test('shares out a policy that does not sum to one', () async {
    final root = positionOf(_afterE4);
    final result = await searchFrom(
      _afterE4,
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

  test('stops when the model has nothing to say', () async {
    final result = await searchFrom(
      _afterE4,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      policy: const AbsentPolicy(),
    );
    expect(
      result,
      isA<PolicyMissing>()
          .having((r) => r.fen.value, 'fen', _afterE4)
          .having((r) => r.reason, 'reason', contains('not loaded')),
    );
  });

  test('a model that fails deeper down keeps the tree so far', () async {
    // Six of our moves are answered and paid for before the model is asked
    // anything; a build that has run for hours must not lose them.
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 2),
      policy: const AbsentPolicy(),
    );
    final failure = result as PolicyMissing;
    final tree = failure.tree! as OurNode;
    expect(tree.candidates, hasLength(6));
    expect(
      tree.candidates.map((c) => c.child),
      everyElement(isA<FrontierNode>()),
    );
  });

  test('an engine that fails deeper down keeps the tree so far', () async {
    final root = positionOf(_kingAndPawn);
    final afterE4 = afterUci(root, 'e2e4');
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 2),
      evaluator: ScriptedEvaluator(failAt: afterUci(afterE4, 'e8d8').fen),
    );
    final failure = result as EvaluationFailed;
    expect((failure.tree! as OurNode).candidates, hasLength(6));
  });

  test('an engine that fails on the root leaves no tree at all', () async {
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 2),
      evaluator: ScriptedEvaluator(failAt: _kingAndPawn),
    );
    expect((result as EvaluationFailed).tree, isNull);
  });

  test('stops when no legal reply has any weight', () async {
    final result = await searchFrom(
      _afterE4,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      policy: const ScriptedPolicy({'e2e4': 1}),
    );
    expect(result, isA<PolicyMissing>());
  });

  test('a cancel part-way leaves the node it was expanding alone', () async {
    // The engine has answered for all six of our moves by the time the
    // cancel lands: the answers are thrown away and the root is left the
    // frontier node it was, not half an enumeration.
    final evaluator = ScriptedEvaluator();
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 2),
      evaluator: evaluator,
      isCancelled: () => evaluator.asked.length > 6,
    );
    expect(result, isA<SearchIncomplete>());
    expect((result as SearchIncomplete).reason, StopReason.cancelled);
    final tree = treeOf(result);
    expect(tree, isA<FrontierNode>());
    expect(tree.valuation.lower, 0);
    expect(tree.valuation.upper, 1);
  });

  test('a budget too small for the first expansion attaches nothing', () async {
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 2,
        nodeBudget: 3,
      ),
    );
    expect(result, isA<SearchIncomplete>());
    expect((result as SearchIncomplete).reason, StopReason.nodeBudget);
    expect(treeOf(result), isA<FrontierNode>());
  });

  test('a budget stops before the next expansion, not inside it', () async {
    // The root and its six moves: enough for the whole first expansion and
    // not one node more.
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 2,
        nodeBudget: 7,
      ),
    );
    final tree = treeOf(result) as OurNode;
    expect(tree.candidates, hasLength(6));
    expect(
      tree.candidates.map((c) => c.child),
      everyElement(isA<FrontierNode>()),
    );
    expect(tree.valuation.lower, 0);
    expect(tree.valuation.upper, 1);
    expect(nodesIn(tree), 7);
    expect((result as SearchIncomplete).reason, StopReason.nodeBudget);
  });

  test('the budget counts the root, so six moves need seven nodes', () async {
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 2,
        nodeBudget: 6,
      ),
    );
    expect(treeOf(result), isA<FrontierNode>());
    expect((result as SearchIncomplete).reason, StopReason.nodeBudget);
  });

  test('the budget is taken on the legal moves, not the survivors', () async {
    // Six legal moves of which the window keeps two: the budget has to hold
    // all six before the engine is asked about any of them, and only the two
    // that are attached are charged.
    final tooTight = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 1,
        nodeBudget: 6,
      ),
      evaluator: matesForUs(),
    );
    expect(treeOf(tooTight), isA<FrontierNode>());

    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 1,
        nodeBudget: 7,
      ),
      evaluator: matesForUs(),
    );
    final tree = treeOf(result) as OurNode;
    expect(tree.candidates, hasLength(2));
    expect(nodesIn(tree), 3);
  });

  test('answers every move at the root before any reply to them', () async {
    // The root, its six moves and one reply to each: thirteen nodes buy the
    // root's whole choice and the answers to it, and nothing below that.
    // Depth-first would have spent the same budget on one line and left five
    // of our moves unanswered.
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 3,
        nodeBudget: 13,
      ),
    );
    expect((result as SearchIncomplete).reason, StopReason.nodeBudget);
    final tree = treeOf(result) as OurNode;
    expect(tree.candidates, hasLength(6));
    for (final candidate in tree.candidates) {
      final reply = (candidate.child as OpponentNode).replies.single;
      expect(reply.move.uci, 'e8d8');
      expect(reply.child, isA<FrontierNode>());
    }
  });

  test('one node\'s moves are evaluated together', () async {
    // The engine is the slow part of a build, and the six positions after
    // our six moves do not depend on each other.
    final evaluator = CountingEvaluator();
    await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: evaluator,
    );
    expect(evaluator.peakInFlight, 6);
  });

  test('an engine that gives up stops the search', () async {
    final root = positionOf(_kingAndPawn);
    final result = await searchFrom(
      _kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: ScriptedEvaluator(failAt: afterUci(root, 'e2e4').fen),
    );
    expect(
      result,
      isA<EvaluationFailed>().having(
        (r) => r.fen.value,
        'fen',
        afterUci(root, 'e2e4').fen,
      ),
    );
  });
}
