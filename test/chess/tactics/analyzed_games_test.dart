import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a prefixed id names its game exactly', () {
    expect(isAnalyzed({'lichess_AbCd1234'}, 'lichess_AbCd1234'), isTrue);
    expect(isAnalyzed({'lichess_AbCd1234'}, 'lichess_Other123'), isFalse);
  });

  test('the analysed-games line names the game at its address', () {
    final done = analyzedIn(withAnalyzed('', {'lichess_AbCd1234'}));
    const game = '[Site "https://lichess.org/AbCd1234"]\n\n1. e4 *\n';
    expect(isAnalyzed(done, gameIdIn(game)), isTrue);
  });

  test('a bare id is not a game id', () {
    expect(isAnalyzed({'AbCd1234'}, 'lichess_AbCd1234'), isFalse);
  });

  test('a game with no id is never analysed', () {
    expect(isAnalyzed({}, ''), isFalse);
    expect(isAnalyzed({''}, ''), isFalse);
  });
}
