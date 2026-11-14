// A search the chess-prep MCP server ran on a chapter is written by the C
// builder and continued by this app's Search tab (`expectimax_run {chapter}`,
// `tools/mcp/chess_prep/expectimax_chapters.py`). The fixture is one such
// tree as the server published it: 1.e4 g6 2.d4 c6 3.Nc3 d5 for Black, one
// ply, rated 2200, so its root is White's move.
import 'dart:io';

import 'package:chess_auto_prep/chess/generation/search.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/search_result.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4_reader.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';

const _afterD5 =
    'rnbqkbnr/pp2pp1p/2p3p1/3p4/3PP3/2N5/PPP2PPP/R1BQKBNR w KQkq - 0 4';

String _fixture() => File(
  'test/fixtures/generation/builder_chapter_tree.json',
).readAsStringSync();

Future<Object> _seed(int rating, Side side) => readSearchSeed(
  _fixture(),
  opponentRating: rating,
  side: side,
  evaluationSource: 'stockfish',
  evalDepth: 14,
);

void main() {
  test('Resume accepts a chapter search the builder wrote', () async {
    final seed = await _seed(2200, Side.black);
    expect(seed, isA<OpponentNode>());
    final root = seed as OpponentNode;
    expect(root.fen.value, _afterD5);
    expect(root.replies, isNotEmpty);
    expect(root.valuation.value, inInclusiveRange(0, 1));
  });

  test('Resume still asks for the rating and side it was built with', () async {
    expect(await _seed(1800, Side.black), isA<String>());
    expect(await _seed(2200, Side.white), isA<String>());
  });

  test('Resume searches on from a chapter search the builder wrote, though '
      'it never scored its root', () async {
    final seed = await _seed(2200, Side.black) as SearchNode;
    expect(seed.evaluated, isFalse);
    final evaluator = ScriptedEvaluator();
    final result = await buildSearchTree(
      root: positionOf(_afterD5),
      config: const SearchConfig(
        side: Side.black,
        horizonPlies: 2,
        lossLimitCp: 50,
      ),
      evaluator: evaluator,
      policy: const ScriptedPolicy({}),
      seed: seed,
    );
    expect(result, isA<SearchComplete>());
    final tree = (result as SearchComplete).tree as OpponentNode;
    expect(tree.replies.length, seed is OpponentNode ? seed.replies.length : 0);
    expect(tree.replies.first.child, isA<OurNode>());
    // Its moves came back with it, so its own score is not asked for.
    expect(evaluator.asked, isNot(contains(_afterD5)));
  });

  test('an unscored builder node valued where it stands is scored on resume, '
      'and an engine that cannot score it ends the run cleanly', () async {
    final seed = await _seed(2200, Side.black) as SearchNode;
    const atRoot = SearchConfig(
      side: Side.black,
      horizonPlies: 0,
      lossLimitCp: 50,
    );
    final evaluator = ScriptedEvaluator();
    final result = await buildSearchTree(
      root: positionOf(_afterD5),
      config: atRoot,
      evaluator: evaluator,
      policy: const ScriptedPolicy({}),
      seed: seed,
    );
    expect(evaluator.asked, contains(_afterD5));
    expect((result as SearchComplete).tree.evaluated, isTrue);
    final failed = await buildSearchTree(
      root: positionOf(_afterD5),
      config: atRoot,
      evaluator: ScriptedEvaluator(failAt: _afterD5),
      policy: const ScriptedPolicy({}),
      seed: seed,
    );
    expect(failed, isA<EvaluationFailed>());
  });
}
