import 'package:chess_auto_prep/chess/tournament/positions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'previews mainlines only and does not show an illegal prefix as final',
    () {
      final positions = tournamentPositions(
        '[Event "First"]\n\n1. e4 (1. d4 d5) e5 *\n\n[Event "Bad"]\n\n1. e4 e6 2. Qa8 *',
      );
      expect(positions, [
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        null,
      ]);
    },
  );
}
