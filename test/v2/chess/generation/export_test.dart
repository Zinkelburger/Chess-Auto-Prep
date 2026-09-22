import 'package:chess_auto_prep/v2/chess/generation/export.dart';
import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_sources.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  test('writes one move of ours and every reply of theirs', () async {
    final result = await buildSearchTree(
      root: positionOf(_afterE4),
      config: const SearchConfig(side: Side.white, horizonPlies: 2),
      evaluator: ScriptedEvaluator(),
      policy: const ScriptedPolicy({'e7e5': 0.6, 'c7c5': 0.4}),
    );
    final tree = exportRepertoire((result as SearchComplete).tree);

    expect(tree.rootFen.value, _afterE4);
    expect(tree.children.map((node) => node.san), ['c5', 'e5']);
    // Our answer to each reply, and then the horizon, so the lines stop.
    for (final reply in tree.children) {
      expect(reply.children, hasLength(1));
      expect(reply.children.single.children, isEmpty);
    }
  });

  test('keeps a reply the model thinks is unlikely', () async {
    final result = await buildSearchTree(
      root: positionOf(_afterE4),
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: ScriptedEvaluator(),
      policy: const ScriptedPolicy({'e7e5': 0.999, 'a7a6': 0.001}),
    );
    final tree = exportRepertoire((result as SearchComplete).tree);
    expect(tree.children.map((node) => node.san), ['a6', 'e5']);
  });

  test('a finished game exports nothing after it', () async {
    final result = await buildSearchTree(
      root: positionOf('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1'),
      config: const SearchConfig(side: Side.white),
      evaluator: ScriptedEvaluator(),
      policy: const ScriptedPolicy({}),
    );
    expect(exportRepertoire((result as SearchComplete).tree).children, isEmpty);
  });

  test('a line records the position it reaches', () async {
    final root = positionOf(_afterE4);
    final result = await buildSearchTree(
      root: root,
      config: const SearchConfig(side: Side.white, horizonPlies: 1),
      evaluator: ScriptedEvaluator(),
      policy: const ScriptedPolicy({'e7e5': 1}),
    );
    final tree = exportRepertoire((result as SearchComplete).tree);
    final MoveNode reply = tree.children.single;
    expect(reply.uci, 'e7e5');
    expect(reply.fen.value, afterUci(root, 'e7e5').fen);
  });
}
