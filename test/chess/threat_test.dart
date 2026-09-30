import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/threat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('passes the turn, drops en passant and moves the counters on', () {
    expect(
      threatFen(
        const Fen(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
        ),
      ),
      const Fen('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2'),
    );
  });

  test('there is no threat in check, at the end, or on an unread FEN', () {
    // White in check from the queen on e2.
    expect(threatFen(const Fen('4k3/8/8/8/8/8/4q3/4K3 w - - 0 1')), isNull);
    // Black is stalemated.
    expect(threatFen(const Fen('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1')), isNull);
    expect(threatFen(const Fen('not a fen')), isNull);
  });
}
