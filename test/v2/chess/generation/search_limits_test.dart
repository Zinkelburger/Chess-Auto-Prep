import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'search_harness.dart';

/// What a search does when it is stopped, refused or left without an answer:
/// the tree it hands back is always whole, and never less than it had.
void main() {
  test('stops when the model has nothing to say', () async {
    final result = await searchFrom(
      afterE4,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      policy: const AbsentPolicy(),
    );
    expect(
      result,
      isA<PolicyMissing>()
          .having((r) => r.fen.value, 'fen', afterE4)
          .having((r) => r.reason, 'reason', contains('not loaded')),
    );
  });

  test('stops when no legal reply has any weight', () async {
    final result = await searchFrom(
      afterE4,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      policy: const ScriptedPolicy({'e2e4': 1}),
    );
    expect(result, isA<PolicyMissing>());
  });

  test('an engine that breaks is reported, not thrown', () async {
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: const ThrowingEvaluator(),
    );
    expect(
      result,
      isA<EvaluationFailed>().having(
        (r) => r.reason,
        'reason',
        contains('the engine process is gone'),
      ),
    );
  });

  test('a model that breaks is reported, not thrown', () async {
    final result = await searchFrom(
      afterE4,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      policy: const ThrowingPolicy(),
    );
    expect(
      result,
      isA<PolicyMissing>().having(
        (r) => r.reason,
        'reason',
        contains('the model file is truncated'),
      ),
    );
  });

  test('a model that fails deeper down keeps the tree so far', () async {
    // Six of our moves are answered and paid for before the model is asked
    // anything; a build that has run for hours must not lose them.
    final result = await searchFrom(
      kingAndPawn,
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
    final root = positionOf(kingAndPawn);
    final afterE4 = afterUci(root, 'e2e4');
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 2),
      evaluator: ScriptedEvaluator(failAt: afterUci(afterE4, 'e8d8').fen),
    );
    final failure = result as EvaluationFailed;
    expect((failure.tree! as OurNode).candidates, hasLength(6));
  });

  test('an engine that fails on the root leaves no tree at all', () async {
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(side: Side.white, horizonPlies: 2),
      evaluator: ScriptedEvaluator(failAt: kingAndPawn),
    );
    expect((result as EvaluationFailed).tree, isNull);
  });

  test('an engine that gives up stops the search', () async {
    final root = positionOf(kingAndPawn);
    final result = await searchFrom(
      kingAndPawn,
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

  test('a cancel part-way leaves the node it was expanding alone', () async {
    // The engine has answered for all six of our moves by the time the
    // cancel lands: the answers are thrown away and the root is left the
    // frontier node it was, not half an enumeration.
    final evaluator = ScriptedEvaluator();
    final result = await searchFrom(
      kingAndPawn,
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
      kingAndPawn,
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
      kingAndPawn,
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
      kingAndPawn,
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
      kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 1,
        nodeBudget: 6,
      ),
      evaluator: matesForUs(),
    );
    expect(treeOf(tooTight), isA<FrontierNode>());

    final result = await searchFrom(
      kingAndPawn,
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
      kingAndPawn,
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

  test('with no loss limit every legal move of ours is kept', () async {
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 1,
        lossLimitCp: null,
      ),
    );
    // Four king moves and two pawn pushes, whatever the engine says.
    expect((treeOf(result) as OurNode).candidates, hasLength(6));
  });

  test('with no horizon a last ply stops it once that level is done', () async {
    final result = await searchFrom(
      kingAndPawn,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: null,
        lossLimitCp: null,
      ),
      lastPly: () => 1,
    );
    expect((result as SearchIncomplete).reason, StopReason.levelDone);
    final tree = treeOf(result) as OurNode;
    expect(tree.candidates, hasLength(6));
    expect(
      tree.candidates.map((c) => c.child),
      everyElement(isA<FrontierNode>()),
      reason: 'every move of the first level is scored, none expanded',
    );
  });
}
