import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a small search by default: four half-moves, moves within two pawns',
    () {
      const config = SearchConfig(side: Side.white);
      expect(config.horizonPlies, 4);
      expect(config.lossLimitCp, 200);
    },
  );

  test('the first-move shortlist covers our first move, whoever moves first, '
      'and the later one every move after', () {
    const config = SearchConfig(side: Side.white, maxOurMoves: 1, rootMoves: 4);
    expect(config.ourMovesAt(0), 4, reason: 'we move first');
    expect(config.ourMovesAt(1), 4, reason: 'after the opponent\'s first move');
    expect(config.ourMovesAt(2), 1);
    expect(config.ourMovesAt(5), 1);
  });

  test('with no shortlist every legal move is kept', () {
    expect(const SearchConfig(side: Side.white).ourMovesAt(0), isNull);
    expect(
      const SearchConfig(side: Side.white, rootMoves: 4).ourMovesAt(0),
      isNull,
    );
  });
}
