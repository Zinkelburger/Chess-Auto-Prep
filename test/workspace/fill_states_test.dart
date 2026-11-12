import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/evaluation_source.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/workspace/search/fill_states.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a saved tree names its engine and rating; the mainline book names '
      'ChessDB and no rating', () {
    const search = FillRequest(elo: 1700);
    expect(search.treeSource, EvaluationSource.stockfish.name);
    expect(search.treeRating, 1700);
    const book = FillRequest(elo: 1700, method: SearchMethod.mainline);
    expect(book.treeSource, 'chessDbMainline');
    expect(book.treeRating, 0);
  });

  test('a search adds at most 25,000 positions to the ones it resumes, and '
      'keeps the likeliest replies to 90%, five at most', () {
    const request = FillRequest(elo: 1700);
    final fresh = request.expectimaxFor(Side.white);
    expect(fresh.nodeBudget, 25000);
    expect(fresh.maxReplies, 5);
    expect(fresh.replyMass, 0.9);
    expect(request.expectimaxFor(Side.white, seeded: 300).nodeBudget, 25300);
  });

  test('the other side starts from the seed only once the engine scored it, '
      'with the score turned round', () {
    const fen = Fen.initial;
    expect(mirrorStart(null), isNull);
    expect(mirrorStart(const FrontierNode(fen: fen, evalForUs: null)), isNull);
    final start = mirrorStart(
      const HorizonNode(fen: fen, evalForUs: Eval(40)),
    )!;
    expect(start, isA<FrontierNode>());
    expect(start.fen, fen);
    expect(start.evalForUs.cp, -40);
  });
}
