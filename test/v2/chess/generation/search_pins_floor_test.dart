import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import 'search_harness.dart';

void main() {
  final rootPosition = Fen(kingAndPawn).position;

  group('pins', () {
    test('at a pinned position only the pinned moves are enumerated', () async {
      final evaluator = ScriptedEvaluator();
      final result = await searchFrom(
        kingAndPawn,
        config: SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          pins: {
            rootPosition: {'e2e4', 'e2e3'},
          },
        ),
        evaluator: evaluator,
      );
      final root = treeOf(result) as OurNode;
      expect(root.candidates.map((c) => c.move.uci).toSet(), {'e2e4', 'e2e3'});
      // The king moves were never scored: they were never played.
      expect(evaluator.asked, hasLength(3), reason: 'the root and two moves');
    });

    test('a pin naming no legal move is ignored', () async {
      final result = await searchFrom(
        kingAndPawn,
        config: SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          pins: {
            rootPosition: {'a1a2'},
          },
        ),
      );
      expect((treeOf(result) as OurNode).candidates, hasLength(6));
    });

    test('a pin is matched in either spelling of a castling move', () async {
      const castling = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';
      final result = await searchFrom(
        castling,
        config: SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          pins: {
            Fen(castling).position: {'e1h1'},
          },
        ),
      );
      final root = treeOf(result) as OurNode;
      expect(root.candidates.single.move.uci, 'e1g1');
    });
  });

  group('the reply floor', () {
    test('a reply reached less often than the floor is valued where it '
        'stands and never expanded', () async {
      final root = positionOf(kingAndPawn);
      final afterE4 = afterUci(root, 'e2e4');
      final policy = TabulatedPolicy({
        afterE4.fen: {'e8d8': 0.9, 'e8f8': 0.1},
        afterUci(afterE4, 'e8d8').fen: {},
      });
      final result = await searchFrom(
        kingAndPawn,
        config: SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          lossLimitCp: 0,
          replyFloor: 0.5,
          pins: {
            rootPosition: {'e2e4'},
          },
        ),
        evaluator: matesForUs(),
        policy: policy,
      );
      final chosen = (treeOf(result) as OurNode).chosen.child as OpponentNode;
      final byMove = {for (final r in chosen.replies) r.move.uci: r.child};
      expect(byMove['e8d8'], isA<OurNode>(), reason: 'reached 90%: answered');
      expect(byMove['e8f8'], isA<HorizonNode>(), reason: 'reached 10%: not');
      // Both still count in the average: the distribution is whole.
      expect(
        chosen.replies.map((r) => r.probability).reduce((a, b) => a + b),
        closeTo(1, 1e-9),
      );
    });
  });

  group('progress', () {
    test('is told after every expansion, nodes and depth growing', () async {
      final progress = <SearchProgress>[];
      await buildSearchTree(
        root: positionOf(kingAndPawn),
        config: const SearchConfig(side: Side.white, horizonPlies: 2),
        evaluator: ScriptedEvaluator(),
        policy: oneReply,
        onProgress: progress.add,
      );
      expect(progress, isNotEmpty);
      expect(progress.first.depth, 1);
      expect(progress.last.depth, 2);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].nodes, greaterThanOrEqualTo(progress[i - 1].nodes));
      }
    });
  });
}
