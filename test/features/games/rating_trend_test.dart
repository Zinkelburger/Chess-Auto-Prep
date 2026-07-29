/// Rating-trend math for the welcome header: grouping by (platform, speed),
/// newest-minus-oldest deltas, and most-played-first ordering.
library;

import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/rating_trend.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:flutter_test/flutter_test.dart';

RecentGame _game({
  required GamesPlatform platform,
  required String timeControl,
  required String myElo,
  bool meWhite = true,
  String date = '2026.07.20',
}) {
  final pgn =
      '[White "${meWhite ? 'me' : 'them'}"]\n'
      '[Black "${meWhite ? 'them' : 'me'}"]\n'
      '[WhiteElo "${meWhite ? myElo : '1500'}"]\n'
      '[BlackElo "${meWhite ? '1500' : myElo}"]\n'
      '[TimeControl "$timeControl"]\n'
      '[UTCDate "$date"]\n'
      '[Result "1-0"]\n'
      '\n'
      '1. e4 1-0\n';
  return RecentGame(
    record: GameRecord.parse(pgn),
    platform: platform,
    cachePath: '/tmp/cache.pgn',
    myUsername: 'me',
    meWhite: meWhite,
    sans: const ['e4'],
  );
}

void main() {
  test('delta is newest minus oldest within one (platform, speed) group', () {
    // Newest-first, as the controller delivers them.
    final games = [
      _game(
        platform: GamesPlatform.chesscom,
        timeControl: '180+2',
        myElo: '1543',
      ),
      _game(
        platform: GamesPlatform.chesscom,
        timeControl: '180+2',
        myElo: '1520',
      ),
      _game(
        platform: GamesPlatform.chesscom,
        timeControl: '180+2',
        myElo: '1513',
      ),
    ];
    final trends = computeRatingTrends(games);
    expect(trends, hasLength(1));
    final t = trends.single;
    expect(t.speed, GameSpeed.blitz);
    expect(t.latestElo, 1543);
    expect(t.delta, 30);
    expect(t.gameCount, 3);
    expect(t.hasTrend, isTrue);
  });

  test('groups are ordered most-played first and kept per platform', () {
    final games = [
      _game(platform: GamesPlatform.lichess, timeControl: '600', myElo: '1800'),
      _game(
        platform: GamesPlatform.chesscom,
        timeControl: '180',
        myElo: '1550',
      ),
      _game(
        platform: GamesPlatform.chesscom,
        timeControl: '180',
        myElo: '1600',
      ),
      _game(platform: GamesPlatform.lichess, timeControl: '600', myElo: '1850'),
      _game(platform: GamesPlatform.lichess, timeControl: '600', myElo: '1900'),
    ];
    final trends = computeRatingTrends(games);
    expect(trends, hasLength(2));
    expect(trends.first.platform, GamesPlatform.lichess);
    expect(trends.first.gameCount, 3);
    expect(trends.first.delta, 1800 - 1900);
    expect(trends.last.platform, GamesPlatform.chesscom);
    expect(trends.last.delta, -50);
  });

  test('a single game has no trend; unrated games are skipped', () {
    final rated = _game(
      platform: GamesPlatform.lichess,
      timeControl: '60',
      myElo: '2000',
    );
    final unrated = _game(
      platform: GamesPlatform.lichess,
      timeControl: '60',
      myElo: '?',
    );
    final trends = computeRatingTrends([rated, unrated]);
    expect(trends, hasLength(1));
    expect(trends.single.gameCount, 1);
    expect(trends.single.hasTrend, isFalse);
  });

  test('myElo reads the side I played and tolerates provisional marks', () {
    final asBlack = _game(
      platform: GamesPlatform.lichess,
      timeControl: '180',
      myElo: '1700?',
      meWhite: false,
    );
    expect(asBlack.myElo, 1700);
  });
}
