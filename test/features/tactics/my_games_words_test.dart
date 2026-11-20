import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/features/tactics/my_games.dart';
import 'package:chess_auto_prep/features/tactics/my_games_words.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one line the Tactics column shows for where the review stands.
void main() {
  test('nothing to say before a review', () {
    expect(myGamesLine(const MyGamesIdle()), '');
  });

  test('downloading and reviewing say so, and Pausing… once Pause is '
      'pressed', () {
    expect(
      myGamesLine(const MyGamesDownloading()),
      'Getting your recent games…',
    );
    expect(myGamesLine(const MyGamesDownloading(pausing: true)), 'Pausing…');
    expect(
      myGamesLine(const MyGamesReviewing(done: 0, total: 3, pausing: true)),
      'Pausing…',
    );
  });

  test('the game being looked at is counted from one, and never past the '
      'last', () {
    expect(
      myGamesLine(const MyGamesReviewing(done: 0, total: 3)),
      'Looking for your mistakes… 1 of 3',
    );
    expect(
      myGamesLine(const MyGamesReviewing(done: 2, total: 3)),
      'Looking for your mistakes… 3 of 3',
    );
    expect(
      myGamesLine(const MyGamesReviewing(done: 3, total: 3)),
      'Looking for your mistakes… 3 of 3',
    );
    expect(
      myGamesLine(
        const MyGamesReviewing(
          done: 0,
          total: 2,
          notReached: {GameSite.chesscom},
        ),
      ),
      'Looking for your mistakes… 1 of 2 · Chess.com not reached, using '
      'saved games',
    );
  });

  test('counts take a plural except for one', () {
    expect(myGamesLine(const MyGamesPaused(left: 1)), 'Paused — 1 game left');
    expect(myGamesLine(const MyGamesPaused(left: 4)), 'Paused — 4 games left');
    expect(
      myGamesLine(const MyGamesDone(reviewed: 3)),
      'Review complete · 0 new puzzles',
    );
    expect(
      myGamesLine(const MyGamesDone(reviewed: 3, added: 2)),
      'Review complete · 2 new puzzles',
    );
  });

  test('each site that could not be reached says why', () {
    expect(
      myGamesLine(
        const MyGamesNotDownloaded({
          GameSite.lichess: GamesNotFetched(GamesProblem.rateLimited),
          GameSite.chesscom: GamesNotFetched(GamesProblem.http, status: 503),
        }),
      ),
      'Lichess is limiting requests; try again in a few minutes. '
      'Chess.com could not answer (HTTP 503).',
    );
    expect(
      myGamesLine(
        const MyGamesNotDownloaded({
          GameSite.chesscom: GamesNotFetched(GamesProblem.noSuchPlayer),
        }),
      ),
      'Chess.com has no player by that username.',
    );
  });

  test('a failed review says what stopped it', () {
    expect(
      myGamesLine(const MyGamesFailed(MyGamesProblem.noAccounts)),
      'Set a username first.',
    );
    expect(
      myGamesLine(const MyGamesFailed(MyGamesProblem.setUnreadable)),
      'Analysis failed: the tactics set could not be read.',
    );
    expect(
      myGamesLine(
        const MyGamesFailed(MyGamesProblem.notSaved, detail: 'disk full'),
      ),
      'Analysis failed: disk full.',
    );
  });
}
