/// The final position each game card shows.
library;

import 'package:chess_auto_prep/features/games/services/game_preview.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replays the mainline to the final position', () {
    final fen = finalFen(const ['e4', 'c5', 'Nf3']);
    expect(
      fen,
      startsWith('rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R'),
    );
  });

  test('a game with no moves previews the starting position', () {
    expect(finalFen(const []), Chess.initial.fen);
  });

  test('an illegal move stops the replay at the last real position', () {
    // Truncated is fine — a position from the game beats no board at all.
    final fen = finalFen(const ['e4', 'e5', 'Qxf7']);
    expect(fen, isNotNull);
    expect(fen, contains('pppp1ppp'), reason: 'stopped after 1...e5');
  });

  test('a first move that cannot be played means no preview', () {
    expect(finalFen(const ['Nf6']), isNull);
  });

  test('ChessBase Z0 passes so later White moves still replay', () {
    final fen = finalFen(const ['d4', 'Z0', 'Nf3']);
    expect(fen, startsWith('rnbqkbnr/pppppppp/8/8/3P4/5N2/PPP1PPPP/RNBQKB1R'));
  });

  test('the batch form keeps one entry per game, in order', () {
    final fens = finalFensBatch(const [
      ['e4'],
      ['Nf6'],
      [],
    ]);
    expect(fens, hasLength(3));
    expect(fens[0], isNotNull);
    expect(fens[1], isNull);
    expect(fens[2], Chess.initial.fen);
  });
}
