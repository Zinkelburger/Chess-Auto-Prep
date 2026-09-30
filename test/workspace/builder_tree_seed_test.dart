// A search the chess-prep MCP server ran on a chapter is written by the C
// builder and continued by this app's Search tab (`expectimax_run {chapter}`,
// `tools/mcp/chess_prep/expectimax_chapters.py`). The fixture is one such
// tree as the server published it: 1.e4 g6 2.d4 c6 3.Nc3 d5 for Black, one
// ply, rated 2200, so its root is White's move.
import 'dart:io';

import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4_reader.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

const _afterD5 =
    'rnbqkbnr/pp2pp1p/2p3p1/3p4/3PP3/2N5/PPP2PPP/R1BQKBNR w KQkq - 0 4';

String _fixture() => File(
  'test/fixtures/v2_generation/builder_chapter_tree.json',
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
}
