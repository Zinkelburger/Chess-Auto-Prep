import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
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
    'deeper nodes evaluate only the shortlist; root can stay broad',
    () async {
      final evaluator = ScriptedEvaluator();
      final candidates = Shortlist();
      final result = await buildSearchTree(
        root: positionOf(fen),
        config: const SearchConfig(
          side: Side.white,
          horizonPlies: 1,
          maxOurMoves: 4,
          narrowAfterPly: 0,
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
}
