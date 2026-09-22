import 'package:chess_auto_prep/v2/chess/generation/legal_moves.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Position positionOf(String fen) => Chess.fromSetup(Setup.parseFen(fen));

List<String> namesOf(String fen) =>
    legalMovesOf(positionOf(fen)).map((named) => named.uci).toList();

void main() {
  test('writes out all four promotions', () {
    final names = namesOf('4k3/P7/8/8/8/8/8/4K3 w - - 0 1');
    expect(names, containsAll(['a7a8q', 'a7a8r', 'a7a8b', 'a7a8n']));
    expect(names.where((uci) => uci.startsWith('a7a8')), hasLength(4));
  });

  test('promotes on the first rank too', () {
    final names = namesOf('4k3/8/8/8/8/8/p7/4K3 b - - 0 1');
    expect(names, containsAll(['a2a1q', 'a2a1r', 'a2a1b', 'a2a1n']));
  });

  test('names castling by where the king lands, not by the rook', () {
    final names = namesOf('4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1');
    expect(names, containsAll(['e1g1', 'e1c1']));
    expect(names, isNot(contains('e1h1')));
    expect(names, isNot(contains('e1a1')));
  });

  test('enumerates the twenty opening moves, in a fixed order', () {
    final names = namesOf(Chess.initial.fen);
    expect(names, hasLength(20));
    expect(names.first, 'a2a3');
    expect(names, orderedEquals(List.of(names)..sort()));
  });

  test('hands back moves the board can play', () {
    final position = positionOf('4k3/P7/8/8/8/8/8/4K3 w - - 0 1');
    final promotion = legalMovesOf(
      position,
    ).firstWhere((named) => named.uci == 'a7a8n');
    expect(position.makeSan(promotion.move).$2, 'a8=N');
  });
}
