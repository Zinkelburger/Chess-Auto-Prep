import 'package:chess_auto_prep/chess/generation/search.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4_reader.dart';
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

  test(
    'a saved root with an en passant square nobody can use still resumes',
    () async {
      // After 1...d5 no white pawn can take on d6: this app writes '-', the
      // C builder writes the square after every double push.
      const root = '4k3/8/8/3p4/8/8/4P3/4K3 w - - 0 2';
      const builder = '4k3/8/8/3p4/8/8/4P3/4K3 w - d6 0 2';
      const shallow = SearchConfig(
        side: Side.white,
        horizonPlies: 1,
        lossLimitCp: null,
      );
      final saved = encodeTreeV4(
        treeOf(await searchFrom(root, config: shallow)),
        shallow,
        complete: true,
      );
      expect(saved, contains(root));
      final read = decodeTreeV4(saved.replaceAll(root, builder));
      if (read is! TreeDecoded) fail('expected a tree, got $read');
      expect(read.root.fen.value, builder);
      const deeper = SearchConfig(
        side: Side.white,
        horizonPlies: 2,
        lossLimitCp: null,
      );
      final resumed = await buildSearchTree(
        root: positionOf(root),
        config: deeper,
        evaluator: ScriptedEvaluator(),
        policy: oneReply,
        seed: read.root,
      );
      final fresh = treeOf(await searchFrom(root, config: deeper));
      expect(
        encodeTreeV4(treeOf(resumed), deeper, complete: true),
        encodeTreeV4(fresh, deeper, complete: true),
      );
    },
  );
}
