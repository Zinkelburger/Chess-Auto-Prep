import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an edit that left every game where it was keeps their places', () {
    final written = GamesWritten(rewritten: {1}, appended: 2);
    expect(GamesArranged.of(written, before: 3).keepsPlaces, isTrue);
  });

  test('a game taken out, or two the other way round, moves the rest', () {
    expect(GamesArranged(order: [0, 2], before: 3).keepsPlaces, isFalse);
    expect(GamesArranged(order: [0, 2, 1], before: 3).keepsPlaces, isFalse);
    expect(GamesArranged(order: [null, 0, 1], before: 2).keepsPlaces, isFalse);
  });
}
