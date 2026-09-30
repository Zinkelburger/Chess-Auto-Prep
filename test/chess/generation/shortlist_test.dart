import 'package:chess_auto_prep/chess/generation/search.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/search_result.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_sources.dart';

class Shortlist implements CandidateSource {
  int calls = 0;
  @override
  Future<List<String>?> candidates(Position position, int count) async {
    calls++;
    return ['e2e4', 'e2e3', 'e1d1', 'e1f1'];
  }
}

void main() {
  const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
  test(
    'the root evaluates only its shortlist; without one it stays broad',
    () async {
      final evaluator = ScriptedEvaluator();
      final candidates = Shortlist();
      final result = await buildSearchTree(
        root: positionOf(fen),
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          maxOurMoves: 4,
          rootMoves: 4,
        ),
        evaluator: evaluator,
        candidates: candidates,
        policy: const ScriptedPolicy({}),
      );
      expect(result, isA<SearchComplete>());
      expect(((result as SearchComplete).tree as OurNode).candidates.length, 4);
      expect(
        evaluator.asked.length,
        5,
        reason: 'root plus four children, not all legal moves',
      );
      expect(candidates.calls, 1);
      final broad = await buildSearchTree(
        root: positionOf(fen),
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          maxOurMoves: 4,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: candidates,
        policy: const ScriptedPolicy({}),
      );
      expect(
        ((broad as SearchComplete).tree as OurNode).candidates.length,
        greaterThan(4),
      );
      expect(candidates.calls, 1, reason: 'no shortlist at broad root');
    },
  );
  test('a root asked for more moves evaluates the missing ones only', () async {
    final root = positionOf(fen);
    final narrow = await buildSearchTree(
      root: root,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 1,
        maxOurMoves: 4,
        rootMoves: 4,
      ),
      evaluator: ScriptedEvaluator(),
      candidates: Shortlist(),
      policy: const ScriptedPolicy({}),
    );
    final seed = (narrow as SearchComplete).tree as OurNode;
    final evaluator = ScriptedEvaluator();
    final progress = <SearchProgress>[];
    final broad = await buildSearchTree(
      root: root,
      seed: seed,
      config: const SearchConfig(
        side: Side.white,
        horizonPlies: 1,
        maxOurMoves: 4,
        rootMoves: 6,
      ),
      evaluator: evaluator,
      candidates: Shortlist(),
      policy: const ScriptedPolicy({}),
      onProgress: progress.add,
    );
    final tree = (broad as SearchComplete).tree as OurNode;
    final moves = tree.candidates;
    expect(moves.length, greaterThan(seed.candidates.length));
    expect(evaluator.asked.length, moves.length - seed.candidates.length);
    for (final move in seed.candidates) {
      expect(evaluator.asked, isNot(contains(move.child.fen.value)));
    }
    expect(progress.last.nodes, nodesIn(tree), reason: 'counted once');
  });
  test(
    'a stop during the top-up keeps the saved moves and their replies',
    () async {
      final root = positionOf(fen);
      const replies = ScriptedPolicy({'e8d8': 0.5, 'e8f8': 0.5});
      final narrow = await buildSearchTree(
        root: root,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 2,
          maxOurMoves: 4,
          rootMoves: 4,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Shortlist(),
        policy: replies,
      );
      final seed = (narrow as SearchComplete).tree as OurNode;
      final evaluator = ScriptedEvaluator();
      final stopped = await buildSearchTree(
        root: root,
        seed: seed,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 2,
          maxOurMoves: 4,
          rootMoves: 6,
        ),
        evaluator: evaluator,
        candidates: Shortlist(),
        policy: replies,
        isCancelled: () => evaluator.asked.isNotEmpty,
      );
      expect(stopped, isA<SearchIncomplete>());
      expect((stopped as SearchIncomplete).reason, StopReason.cancelled);
      final tree = stopped.tree;
      expect(tree, isA<OurNode>());
      expect([
        for (final c in (tree as OurNode).candidates) c.move.uci,
      ], containsAll([for (final c in seed.candidates) c.move.uci]));
      expect(nodesIn(tree), greaterThanOrEqualTo(nodesIn(seed)));
    },
  );
  test(
    'a level cut before the top-up keeps every saved reply subtree',
    () async {
      const blackToMove = '4k3/8/8/8/8/8/4P3/4K3 b - - 0 1';
      final root = positionOf(blackToMove);
      const policy = ScriptedPolicy({
        'e8d8': 0.5,
        'e8f8': 0.5,
        'd8e8': 1,
        'f8e8': 1,
      });
      final narrow = await buildSearchTree(
        root: root,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          maxOurMoves: 4,
          rootMoves: 4,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Shortlist(),
        policy: policy,
      );
      final seed = (narrow as SearchComplete).tree as OpponentNode;
      final cut = await buildSearchTree(
        root: root,
        seed: seed,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          maxOurMoves: 4,
          rootMoves: 6,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Shortlist(),
        policy: policy,
        lastPly: () => 1,
      );
      expect(cut, isA<SearchIncomplete>());
      expect((cut as SearchIncomplete).reason, StopReason.levelDone);
      final tree = cut.tree as OpponentNode;
      expect(tree.replies, hasLength(seed.replies.length));
      for (final (index, reply) in tree.replies.indexed) {
        final saved = seed.replies[index].child as OurNode;
        expect(reply.child, isA<OurNode>());
        expect(
          [for (final c in (reply.child as OurNode).candidates) c.move.uci],
          [for (final c in saved.candidates) c.move.uci],
        );
      }
      expect(nodesIn(tree), greaterThanOrEqualTo(nodesIn(seed)));
    },
  );
  test(
    'a completed top-up under an opponent root counts each node once',
    () async {
      const blackToMove = '4k3/8/8/8/8/8/4P3/4K3 b - - 0 1';
      final root = positionOf(blackToMove);
      const policy = ScriptedPolicy({
        'e8d8': 0.5,
        'e8f8': 0.5,
        'd8e8': 1,
        'f8e8': 1,
      });
      final narrow = await buildSearchTree(
        root: root,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          maxOurMoves: 4,
          rootMoves: 4,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Shortlist(),
        policy: policy,
      );
      final seed = (narrow as SearchComplete).tree as OpponentNode;
      final progress = <SearchProgress>[];
      final broad = await buildSearchTree(
        root: root,
        seed: seed,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          maxOurMoves: 4,
          rootMoves: 6,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Shortlist(),
        policy: policy,
        onProgress: progress.add,
      );
      final tree = (broad as SearchComplete).tree as OpponentNode;
      for (final (index, reply) in tree.replies.indexed) {
        final saved = seed.replies[index].child as OurNode;
        expect(
          (reply.child as OurNode).candidates.length,
          greaterThan(saved.candidates.length),
        );
      }
      expect(progress.last.nodes, nodesIn(tree), reason: 'counted once');
    },
  );
}
