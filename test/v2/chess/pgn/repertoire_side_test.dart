import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/repertoire_side.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

GameTree line(String moves) =>
    readGame('[Event "x"]\n[Result "*"]\n\n$moves *\n').tree!;

void main() {
  test('the side that branches is the opponent', () {
    final whiteBook = [
      for (final reply in ['e5', 'c5', 'e6', 'c6', 'd5', 'd6', 'Nf6', 'g6'])
        line('1. e4 $reply 2. Nf3'),
    ];
    expect(inferredRepertoireSide(whiteBook), Side.white);
    final blackBook = [
      for (final first in ['e4', 'd4', 'c4', 'Nf3', 'g3', 'b3', 'f4', 'Nc3'])
        line('1. $first c5'),
    ];
    expect(inferredRepertoireSide(blackBook), Side.black);
  });

  test('too few lines to branch are read by the move they end on', () {
    final endsOnWhite = [
      for (final reply in ['e5', 'c5', 'e6', 'c6']) line('1. e4 $reply 2. Nf3'),
    ];
    expect(inferredRepertoireSide(endsOnWhite), Side.white);
  });

  test('a handful of lines, or a thin margin, says nothing', () {
    expect(
      inferredRepertoireSide([line('1. e4 e5'), line('1. d4 d5')]),
      isNull,
    );
    final mixed = [
      line('1. e4 e5'),
      line('1. e4 c5 2. Nf3'),
      line('1. d4 d5'),
      line('1. d4 Nf6 2. c4'),
    ];
    expect(inferredRepertoireSide(mixed), isNull);
  });
}
