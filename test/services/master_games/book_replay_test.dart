import 'package:chess_auto_prep/services/master_games/book_replay.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('movetextSans', () {
    test('drops move numbers and stops at the result', () {
      expect(movetextSans('1. e4 c5 2. Nf3 d6 1-0'), ['e4', 'c5', 'Nf3', 'd6']);
    });

    test('caps at maxPlies', () {
      expect(movetextSans('1. e4 c5 2. Nf3 d6 *', maxPlies: 3), [
        'e4',
        'c5',
        'Nf3',
      ]);
    });

    test('a moveless game is empty', () {
      expect(movetextSans('*'), isEmpty);
      expect(movetextSans(''), isEmpty);
    });
  });

  group('replayBookMoves', () {
    test('keys each ply by the position it was played in', () {
      final refs = replayBookMoves(['e4', 'c5', 'Nf3']);
      expect(refs, hasLength(3));
      expect(refs[0].positionKey, positionKey(Chess.initial.fen));
      expect(refs[0].uci, 'e2e4');
      expect(refs[0].ply, 0);
      final afterE4 = Chess.initial.play(
        Chess.initial.parseSan('e4') as NormalMove,
      );
      expect(refs[1].positionKey, positionKey(afterE4.fen));
      expect(refs[1].uci, 'c7c5');
      expect(refs[2].ply, 2);
    });

    test('stops at the first unplayable move and keeps the rest', () {
      final refs = replayBookMoves(['e4', 'e5', 'Qa8', 'Nf3']);
      expect(refs.map((r) => r.uci), ['e2e4', 'e7e5']);
    });

    test('replays no deeper than maxPly', () {
      final sans = movetextSans(
        '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 *',
      );
      expect(replayBookMoves(sans, maxPly: 4), hasLength(4));
      expect(replayBookMoves(sans), hasLength(sans.length));
      expect(kBookMaxPly, greaterThan(sans.length));
    });
  });

  test('resultTally counts one column per decided result', () {
    expect(resultTally('1-0'), (whiteWins: 1, draws: 0, blackWins: 0));
    expect(resultTally('1/2-1/2'), (whiteWins: 0, draws: 1, blackWins: 0));
    expect(resultTally('0-1'), (whiteWins: 0, draws: 0, blackWins: 1));
    expect(resultTally('*'), (whiteWins: 0, draws: 0, blackWins: 0));
  });

  test('strongerElo treats a missing rating as 0', () {
    expect(strongerElo(2500, 2450), 2500);
    expect(strongerElo(null, 2450), 2450);
    expect(strongerElo(null, null), 0);
  });
}
