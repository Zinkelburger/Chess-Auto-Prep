import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4_reader.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import 'search_harness.dart';

/// Every legal reply of the bare black king after 1.e4, the way Maia gives
/// each some weight.
const _spread = ScriptedPolicy({
  'e8d8': 0.5,
  'e8f8': 0.3,
  'e8d7': 0.1,
  'e8e7': 0.06,
  'e8f7': 0.04,
});

const _cut = SearchConfig(
  side: Side.white,
  horizonPlies: 2,
  lossLimitCp: null,
  replyMass: 0.9,
  maxReplies: 5,
  pins: {
    '4k3/8/8/8/8/8/4P3/4K3 w - -': {'e2e4'},
  },
);

Map<String, double> _sharesUnder(SearchNode tree) {
  final replies = ((tree as OurNode).chosen.child as OpponentNode).replies;
  return {for (final r in replies) r.move.uci: r.probability};
}

void main() {
  group('likeliestReplies', () {
    test('keeps the likeliest until the mass is covered, renormalised', () {
      final kept = likeliestReplies(_spread.weights, mass: 0.9);
      expect(kept.keys, ['e8d8', 'e8f8', 'e8d7']);
      expect(kept['e8d8'], closeTo(0.5 / 0.9, 1e-12));
      expect(kept.values.reduce((a, b) => a + b), closeTo(1, 1e-12));
    });

    test('stops at the cap before the mass is covered', () {
      final kept = likeliestReplies(_spread.weights, mass: 0.9, most: 2);
      expect(kept, {
        'e8d8': closeTo(0.625, 1e-12),
        'e8f8': closeTo(0.375, 1e-12),
      });
    });

    test('always keeps one reply, and keeps all with no cut', () {
      expect(likeliestReplies({'a': 0.95, 'b': 0.05}, mass: 0.1), {'a': 1.0});
      expect(likeliestReplies(_spread.weights), same(_spread.weights));
    });

    test('orders equal shares by move', () {
      expect(likeliestReplies({'b': 0.25, 'a': 0.25, 'c': 0.5}, most: 2).keys, [
        'c',
        'a',
      ]);
    });
  });

  test(
    'a search keeps only the likeliest replies, shares summing to one',
    () async {
      final evaluator = ScriptedEvaluator();
      final tree = treeOf(
        await searchFrom(
          kingAndPawn,
          config: _cut,
          evaluator: evaluator,
          policy: _spread,
        ),
      );
      final shares = _sharesUnder(tree);
      expect(shares.keys.toSet(), {'e8d8', 'e8f8', 'e8d7'});
      expect(shares.values.reduce((a, b) => a + b), closeTo(1, 1e-9));
      // The dropped replies were never played, so never scored: the root, e4
      // and the three kept replies.
      expect(evaluator.asked, hasLength(5));
    },
  );

  group('a tree saved before the cut', () {
    late SearchNode uncut;
    late SearchNode fresh;
    setUp(() async {
      uncut = treeOf(
        await searchFrom(
          kingAndPawn,
          config: const SearchConfig(
            side: Side.white,
            horizonPlies: 2,
            lossLimitCp: null,
            pins: {
              '4k3/8/8/8/8/8/4P3/4K3 w - -': {'e2e4'},
            },
          ),
          policy: _spread,
        ),
      );
      fresh = treeOf(
        await searchFrom(kingAndPawn, config: _cut, policy: _spread),
      );
    });

    test('is cut the way a fresh search would have cut it', () {
      expect(_sharesUnder(uncut), hasLength(5));
      final cut = cutReplies(uncut, mass: 0.9, most: 5);
      expect(_sharesUnder(cut), _sharesUnder(fresh));
      expect(cut.valuation.value, closeTo(fresh.valuation.value, 1e-12));
    });

    test('resumes cut, and a tree already cut resumes as saved', () async {
      Future<Object> resume(SearchNode tree, SearchConfig config) =>
          readSearchSeed(
            encodeTreeV4(
              tree,
              config,
              complete: true,
              evalDepth: 14,
              opponentRating: 2000,
            ),
            opponentRating: 2000,
            side: Side.white,
            evaluationSource: 'stockfish',
            evalDepth: 14,
            replyFloor: 0,
            replyMass: 0.9,
            maxReplies: 5,
          );
      const plain = SearchConfig(side: Side.white, lossLimitCp: null);
      const cutConfig = SearchConfig(
        side: Side.white,
        lossLimitCp: null,
        replyMass: 0.9,
        maxReplies: 5,
      );
      final fromUncut = await resume(uncut, plain);
      expect(_sharesUnder(fromUncut as SearchNode), _sharesUnder(fresh));
      final fromCut = await resume(fresh, cutConfig);
      expect(_sharesUnder(fromCut as SearchNode), _sharesUnder(fresh));
      const other = SearchConfig(
        side: Side.white,
        lossLimitCp: null,
        replyMass: 0.8,
        maxReplies: 5,
      );
      expect(await resume(fresh, other), isA<String>());
    });
  });

  test('a saved tree records its cut', () async {
    final tree = treeOf(
      await searchFrom(kingAndPawn, config: _cut, policy: _spread),
    );
    final decoded = decodeTreeV4(encodeTreeV4(tree, _cut, complete: true));
    expect(decoded, isA<TreeDecoded>());
    final config = (decoded as TreeDecoded).config;
    expect(config.replyMass, 0.9);
    expect(config.maxReplies, 5);
  });
}
