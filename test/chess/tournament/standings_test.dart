import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/chess/tournament/standings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a game Black wins is Black\'s', () {
    final rows = Tournament({
      'config': {
        'engines': [
          {'name': 'A'},
          {'name': 'B'},
        ],
      },
      'games': [_game(0, 1, 'blackWins')],
    }).standings;
    expect(rows.first.seat, 1);
    expect(rows.first.score.wins, 1);
    expect(rows.last.score.losses, 1);
  });

  test('the edges of the estimates: every game lost, a margin held inside '
      'the possible, and a lopsided record', () {
    expect(const MatchScore(0, 0, 3).elo, isNull);
    expect(const MatchScore(0, 1, 9).margin, closeTo(1644.45, 0.01));
    expect(const MatchScore(0, 0, 81).superiority, 0);
    expect(const MatchScore(81, 0, 0).superiority, 1);
  });

  test('seat identity, invalid results, head-to-head and SB standings', () {
    final tournament = Tournament({
      'config': {
        'engines': [
          for (var i = 0; i < 3; i++) {'name': 'Same engine'},
        ],
      },
      'games': [
        _game(0, 1, 'whiteWins'),
        _game(1, 0, 'draw'),
        _game(2, 0, 'whiteWins'),
        _game(1, 2, 'unfinished'),
        _game(0, 0, 'whiteWins'),
        _game(9, 1, 'whiteWins'),
      ],
    });
    final rows = tournament.standings;
    expect(rows.map((r) => r.seat), [0, 2, 1]);
    expect(rows.map((r) => r.score.points), [1.5, 1, .5]);
    expect(rows.first.opponents[1].label, '1.5/2');
    expect(rows.first.opponents[2].losses, 1);
    expect(rows.map((r) => r.sonnebornBerger), [.75, 1.5, .75]);
    expect(rows.map((r) => r.score.losses), [1, 0, 1]);
    expect(() => rows.clear(), throwsUnsupportedError);
  });
  test('rating estimates keep the recorded convention and edge semantics', () {
    const score = MatchScore(60, 20, 20);
    expect(score.elo, closeTo(147.190714, 1e-5));
    expect(score.margin, closeTo(66.0230, .02));
    expect(score.superiority, closeTo(.9999961279, 1e-7));
    expect(
      const MatchScore(20, 20, 60).superiority,
      closeTo(1 - score.superiority, 1e-10),
    );
    expect(const MatchScore(0, 0, 0).elo, isNull);
    expect(const MatchScore(2, 0, 0).elo, isNull);
    expect(const MatchScore(0, 8, 0).superiority, .5);
  });
}

Map<String, Object> _game(int white, int black, String result) => {
  'whiteIndex': white,
  'blackIndex': black,
  'result': result,
};
