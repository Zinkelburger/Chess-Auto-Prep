import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/tree_wire_v4.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'search_harness.dart';

void main() {
  test(
    'resuming a budget stop equals a fresh complete search without rescoring',
    () async {
      const full = SearchConfig(
        side: Side.white,
        horizonPlies: 2,
        lossLimitCp: null,
      );
      final first = treeOf(
        await searchFrom(
          kingAndPawn,
          config: const SearchConfig(
            side: Side.white,
            horizonPlies: 2,
            lossLimitCp: null,
            nodeBudget: 7,
          ),
        ),
      );
      final evaluator = ScriptedEvaluator();
      final resumed = treeOf(
        await buildSearchTree(
          root: positionOf(kingAndPawn),
          config: full,
          evaluator: evaluator,
          policy: oneReply,
          seed: first,
        ),
      );
      final fresh = treeOf(await searchFrom(kingAndPawn, config: full));
      expect(
        encodeTreeV4(resumed, full, complete: true),
        encodeTreeV4(fresh, full, complete: true),
      );
      final kept = {
        first.fen.value,
        for (final c in (first as OurNode).candidates) c.child.fen.value,
      };
      expect(evaluator.asked.where(kept.contains), isEmpty);
    },
  );

  test('a deeper resume expands old horizons', () async {
    final first = treeOf(
      await searchFrom(
        kingAndPawn,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          lossLimitCp: null,
        ),
      ),
    );
    const deeper = SearchConfig(
      side: Side.white,
      horizonPlies: 2,
      lossLimitCp: null,
    );
    final resumed = treeOf(
      await buildSearchTree(
        root: positionOf(kingAndPawn),
        config: deeper,
        evaluator: ScriptedEvaluator(),
        policy: oneReply,
        seed: first,
      ),
    );
    expect(
      (resumed as OurNode).candidates.every((c) => c.child is OpponentNode),
      isTrue,
    );
  });
}
