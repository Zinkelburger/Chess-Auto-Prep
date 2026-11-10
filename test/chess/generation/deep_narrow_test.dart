import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/search.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/search_result.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:dartchess/dartchess.dart' show NormalMove, Position, Side;
import 'package:flutter_test/flutter_test.dart';

import 'search_harness.dart';

/// An engine shortlist read off a fixed ranking: the first [count] of
/// [ranking] that are legal where it is asked.
final class Ranking implements CandidateSource {
  Ranking(this.ranking);

  final List<String> ranking;
  final asked = <String>[];

  @override
  Future<List<String>?> candidates(Position position, int count) async {
    asked.add(position.fen);
    return ranking
        .where((uci) => position.isLegal(NormalMove.fromUci(uci)))
        .take(count)
        .toList();
  }
}

/// The search as the Expectimax tab runs it: a shortlist of our moves, one
/// of them after the first, the chapter's own moves pinned, and the
/// likeliest positions of a level first.
void main() {
  final root = positionOf(kingAndPawn);
  final rootPosition = const Fen(kingAndPawn).position;

  group('pins beside a shortlist', () {
    test('at the first move the pin is searched beside the engine\'s best, '
        'and kept however the engine scores it', () async {
      final shortlist = Ranking(['e1d1', 'e1f1', 'e2e3', 'e2e4']);
      final result = await buildSearchTree(
        root: root,
        config: SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          lossLimitCp: null,
          maxOurMoves: 1,
          rootMoves: 2,
          pins: {
            rootPosition: {'e2e4'},
          },
        ),
        // The pinned move is the worst of the three for us.
        evaluator: ScriptedEvaluator(scores: {afterUci(root, 'e2e4').fen: 300}),
        candidates: shortlist,
        policy: oneReply,
      );
      final tree = treeOf(result) as OurNode;
      expect(tree.candidates.map((c) => c.move.uci).toSet(), {
        'e1d1',
        'e1f1',
        'e2e4',
      });
      expect(shortlist.asked, [kingAndPawn]);
    });

    test('after the first move a pinned position plays its pin alone and '
        'asks for no shortlist', () async {
      final afterReply = afterUci(afterUci(root, 'e2e4'), 'e8d8');
      final shortlist = Ranking(['e2e4', 'e1d1']);
      final result = await buildSearchTree(
        root: root,
        config: SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          lossLimitCp: null,
          maxOurMoves: 1,
          rootMoves: 1,
          pins: {
            Fen(afterReply.fen).position: {'e4e5'},
          },
        ),
        evaluator: ScriptedEvaluator(),
        candidates: shortlist,
        policy: oneReply,
      );
      final first = (treeOf(result) as OurNode).candidates.single;
      expect(first.move.uci, 'e2e4');
      final later = (first.child as OpponentNode).replies.single.child;
      expect((later as OurNode).candidates.single.move.uci, 'e4e5');
      expect(shortlist.asked, [kingAndPawn], reason: 'only the first move');
    });

    test('a resumed tree whose saved move a pin has since replaced makes '
        'that choice again', () async {
      final afterReply = afterUci(afterUci(root, 'e2e4'), 'e8d8');
      const config = SearchConfig(
        side: Side.white,
        horizonPlies: 3,
        lossLimitCp: null,
        maxOurMoves: 1,
        rootMoves: 1,
      );
      final unpinned = await buildSearchTree(
        root: root,
        config: config,
        evaluator: ScriptedEvaluator(),
        candidates: Ranking(['e2e4', 'e1d1']),
        policy: oneReply,
      );
      OurNode laterOf(SearchResult result) =>
          ((treeOf(result) as OurNode).candidates.single.child as OpponentNode)
                  .replies
                  .single
                  .child
              as OurNode;
      expect(laterOf(unpinned).candidates.single.move.uci, 'e1d1');

      final pinned = await buildSearchTree(
        root: root,
        seed: treeOf(unpinned),
        config: SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          lossLimitCp: null,
          maxOurMoves: 1,
          rootMoves: 1,
          pins: {
            Fen(afterReply.fen).position: {'e4e5'},
          },
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Ranking(['e2e4', 'e1d1']),
        policy: oneReply,
      );
      expect(laterOf(pinned).candidates.single.move.uci, 'e4e5');
    });
  });

  group('order within a level', () {
    /// After 1.e4 with the two replies weighted [e5] and [c5]: the reply
    /// whose position was answered when the budget allowed only one.
    Future<String> answeredFirst({
      required double e5,
      required double c5,
    }) async {
      final start = positionOf(afterE4);
      final result = await buildSearchTree(
        root: start,
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 3,
          lossLimitCp: null,
          maxOurMoves: 1,
          rootMoves: 1,
          // The board, its two replies and one answer: no room for both.
          nodeBudget: 4,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Ranking(['g1f3']),
        policy: ScriptedPolicy({'e7e5': e5, 'c7c5': c5}),
      );
      expect(result, isA<SearchIncomplete>());
      final replies = (treeOf(result) as OpponentNode).replies;
      return replies.singleWhere((r) => r.child is OurNode).move.uci;
    }

    test('the position games reach most often is answered first, whichever '
        'way the moves are listed', () async {
      expect(await answeredFirst(e5: 0.8, c5: 0.2), 'e7e5');
      expect(await answeredFirst(e5: 0.2, c5: 0.8), 'c7c5');
    });

    test('a level tells how much of it is done as it goes', () async {
      final told = <(int, int)>[];
      await buildSearchTree(
        root: positionOf(afterE4),
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 2,
          lossLimitCp: null,
          maxOurMoves: 1,
          rootMoves: 1,
        ),
        evaluator: ScriptedEvaluator(),
        candidates: Ranking(['g1f3']),
        policy: const ScriptedPolicy({'e7e5': 0.6, 'c7c5': 0.4}),
        onLevel: (done, of) => told.add((done, of)),
      );
      expect(told, [(0, 1), (0, 2), (1, 2)]);
    });
  });
}
