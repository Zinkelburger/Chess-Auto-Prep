import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a saved game with no seats is game 0, engine 0 against engine 1', () {
    final game = TournamentGame(const {});
    expect((game.index, game.white, game.black), (0, 0, 1));
    expect(game.result, '*');
  });

  test('a score is a point a win and half a point a draw', () {
    expect(const TournamentScore('A', 3, 2, 1).points, 4);
    expect(const TournamentScore('B', 0, 1, 0).points, 0.5);
  });
}
