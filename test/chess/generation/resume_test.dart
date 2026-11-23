import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/search.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/search_result.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4_reader.dart';
import 'package:dartchess/dartchess.dart' show Side;
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
    'a shallower resume can pause between unscored builder replies',
    () async {
      final root = afterUci(positionOf(kingAndPawn), 'e2e4');
      ReplyMove reply(String uci, String san) {
        final after = afterUci(root, uci);
        return ReplyMove(
          move: MoveRef(uci: uci, san: san),
          probability: 0.5,
          child: OurNode.over(
            fen: fenOf(after),
            evalForUs: null,
            candidates: [
              CandidateMove(
                move: const MoveRef(uci: 'e4e5', san: 'e5'),
                child: HorizonNode(
                  fen: fenOf(afterUci(after, 'e4e5')),
                  evalForUs: const Eval(0),
                ),
              ),
            ],
          ),
        );
      }

      final seed = OpponentNode.over(
        fen: fenOf(root),
        evalForUs: null,
        replies: [reply('e8d8', 'Kd8'), reply('e8f8', 'Kf8')],
      );
      final evaluator = ScriptedEvaluator();
      final deep = await buildSearchTree(
        root: root,
        config: const SearchConfig(side: Side.white, horizonPlies: 2),
        evaluator: evaluator,
        policy: oneReply,
        seed: seed,
      );
      final restored = (deep as SearchComplete).tree as OpponentNode;
      expect(evaluator.asked, isEmpty);
      expect(restored.evaluated, isFalse);
      for (final reply in restored.replies) {
        expect(reply.child, isA<OurNode>());
        expect(reply.child.evaluated, isFalse);
      }

      const shallow = SearchConfig(side: Side.white, horizonPlies: 1);
      final paused = await buildSearchTree(
        root: root,
        config: shallow,
        evaluator: evaluator,
        policy: oneReply,
        seed: restored,
        isCancelled: () => evaluator.asked.isNotEmpty,
      );
      final stopped = paused as SearchIncomplete;
      expect(stopped.reason, StopReason.cancelled);
      final tree = stopped.tree as OpponentNode;
      final first = tree.replies.first.child;
      final pending = tree.replies.last.child;
      expect(evaluator.asked, [seed.replies.first.child.fen.value]);
      expect(first, isA<HorizonNode>());
      expect(first.evaluated, isTrue);
      expect(pending, isA<FrontierNode>());
      expect(pending.evaluated, isFalse);
      expect(searchedTo(tree, 1), isFalse);

      final resumed = await buildSearchTree(
        root: root,
        config: shallow,
        evaluator: evaluator,
        policy: oneReply,
        seed: tree,
      );
      expect(evaluator.asked, seed.replies.map((r) => r.child.fen.value));
      expect(searchedTo((resumed as SearchComplete).tree, 1), isTrue);
    },
  );

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
