import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Old app builds filed a Lichess game under its bare id, as Lichess's own
  // GameId header writes it; both apps still count those games as done.
  final bare = analyzedIn(withAnalyzed('', {'AbCd1234'}));

  test('a bare Lichess id names the game at its address', () {
    const game = '[Site "https://lichess.org/AbCd1234"]\n\n1. e4 *\n';
    expect(isAnalyzed(bare, gameIdIn(game)), isTrue);
  });

  test('a bare Lichess id names the game with that bare GameId', () {
    const game = '[GameId "AbCd1234"]\n\n1. e4 *\n';
    expect(isAnalyzed(bare, gameIdIn(game)), isTrue);
  });

  test('a prefixed id still names its game exactly', () {
    expect(isAnalyzed({'lichess_AbCd1234'}, 'lichess_AbCd1234'), isTrue);
    expect(isAnalyzed({'lichess_AbCd1234'}, 'lichess_Other123'), isFalse);
  });

  test('a bare id never names another site\'s game', () {
    expect(isAnalyzed({'AbCd1234'}, 'chesscom_AbCd1234'), isFalse);
  });

  test('a game with no id is never analysed', () {
    expect(isAnalyzed({}, ''), isFalse);
    expect(isAnalyzed({''}, ''), isFalse);
  });
}
