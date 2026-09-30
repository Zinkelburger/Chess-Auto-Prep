import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:flutter_test/flutter_test.dart';

/// A game played at [control]; no `TimeControl` when null.
String game(String? control) =>
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '${control == null ? '' : '[TimeControl "$control"]\n'}'
    '[Result "1-0"]\n\n1. e4 e5 1-0';

/// A game played on [site] at [control].
String onSite(String site, String control) => game(
  control,
).replaceFirst('[Event "Club"]', '[Event "Rated"]\n[Site "$site"]');

/// The one time-control classifier and what each of its callers does with a
/// game it cannot place.
void main() {
  test('classes a time control by base plus forty times the increment', () {
    expect(timeClassOf('60+0'), TimeClass.bullet);
    expect(timeClassOf('0+1'), TimeClass.bullet, reason: '40 seconds');
    expect(timeClassOf('180+2'), TimeClass.blitz);
    expect(timeClassOf('600'), TimeClass.rapid);
    expect(timeClassOf('1800+30'), TimeClass.classical);
    expect(timeClassOf('1/259200'), TimeClass.correspondence);
    expect(timeClassOf('-'), TimeClass.correspondence);
    for (final unreadable in [null, '', '?', '0', 'blitz', '1+2+3']) {
      expect(timeClassOf(unreadable), TimeClass.unknown, reason: unreadable);
    }
  });

  test('a Lichess game is classed by Lichess\'s own limits, 8 and 25 '
      'minutes, and any other site\'s by 10 and 30', () {
    TimeClass lichess(String control) =>
        timeClassIn(onSite('https://lichess.org/abcd1234', control));
    expect(lichess('480'), TimeClass.rapid);
    expect(lichess('300+5'), TimeClass.rapid);
    expect(lichess('1500'), TimeClass.classical);
    expect(lichess('900+15'), TimeClass.classical);
    expect(lichess('420'), TimeClass.blitz);
    expect(lichess('60+0'), TimeClass.bullet);
    expect(lichess('15+0'), TimeClass.bullet, reason: 'UltraBullet');
    expect(lichess('-'), TimeClass.correspondence);
    expect(lichess('?'), TimeClass.unknown);
    expect(timeClassIn(onSite('Chess.com', '480')), TimeClass.blitz);
    expect(timeClassIn(onSite('Chess.com', '600')), TimeClass.rapid);
    expect(
      timeClassOfTags({
        'Link': 'https://www.lichess.org/abcd1234',
        'TimeControl': '480',
      }),
      TimeClass.rapid,
    );
    final eight = onSite('https://lichess.org/abcd1234', '480');
    expect(speedIn(eight), GameSpeed.rapid);
    expect(keepsSpeed({GameSpeed.blitz}, eight), isFalse);
  });

  test('reads the class off the header lines alone', () {
    expect(timeClassIn(onSite('Chess.com', '180+2')), TimeClass.blitz);
    expect(timeClassIn(game('1/259200')), TimeClass.correspondence);
    expect(timeClassIn(game(null)), TimeClass.unknown);
  });

  test('My games counts correspondence as classical and lets an unknown '
      'time control through', () {
    expect(speedIn(game('-')), GameSpeed.classical);
    expect(speedIn(game(null)), isNull);
    expect(keepsSpeed({GameSpeed.blitz}, game(null)), isTrue);
    expect(keepsSpeed({GameSpeed.blitz}, game('60+0')), isFalse);
  });

  test('a download keeps what was chosen, Lichess\'s unlimited games as '
      'correspondence, and a game whose time control cannot be told', () {
    final now = DateTime(2026, 9, 28);
    const range = PlayerDownloadRange(speeds: {'blitz', 'correspondence'});
    expect(range.keeps(game('180+2'), now), isTrue);
    expect(range.keeps(game('-'), now), isTrue);
    expect(range.keeps(game(null), now), isTrue);
    expect(range.keeps(game('60+0'), now), isFalse);
    expect(
      const PlayerDownloadRange(speeds: {'blitz'}).keeps(game('-'), now),
      isFalse,
    );
    expect(
      const PlayerDownloadRange(
        speeds: {'rapid'},
      ).keeps(onSite('https://lichess.org/abcd1234', '480'), now),
      isTrue,
    );
  });
}
