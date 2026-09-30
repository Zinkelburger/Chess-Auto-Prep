import 'dart:convert';

import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:chess_auto_prep/net/player_ratings.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _game(String control, int day) =>
    '[Event "Rated game"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.$day"]\n[TimeControl "$control"]\n\n1. e4 e5 *';
void main() {
  test('a download classes a game by its header, whatever its moves', () {
    final illegal = _game('60+0', 20).replaceFirst('1. e4 e5', '1. e5 Ke7');
    final now = DateTime(2026, 9, 28);
    expect(
      const PlayerDownloadRange(speeds: {'rapid'}).keeps(illegal, now),
      isFalse,
    );
    expect(
      const PlayerDownloadRange(speeds: {'bullet'}).keeps(illegal, now),
      isTrue,
    );
  });
  test(
    'Lichess date downloads have a cutoff and speeds, no arbitrary cap',
    () async {
      late Uri url;
      final api = LichessGamesApi(
        MockClient((request) async {
          url = request.url;
          return http.Response(_game('600+0', 20), 200);
        }),
        token: () async => null,
      );
      await api.range(
        'alex',
        const PlayerDownloadRange(months: 6, speeds: {'rapid'}),
        cancelled: () => false,
        progress: (_) {},
      );
      expect(url.queryParameters['max'], isNull);
      expect(url.queryParameters['since'], isNotNull);
      expect(url.queryParameters['perfType'], 'rapid');
    },
  );
  test('counted Chess.com exports continue past excluded fast games', () async {
    final asked = <String>[];
    final api = ChesscomGamesApi(
      MockClient((request) async {
        asked.add(request.url.path);
        if (request.url.path.endsWith('archives'))
          return http.Response(
            jsonEncode({
              'archives': [
                'https://api.chess.com/pub/player/alex/games/2026/08',
                'https://api.chess.com/pub/player/alex/games/2026/09',
              ],
            }),
            200,
          );
        return http.Response(
          request.url.path.contains('/09/')
              ? _game('60+0', 20)
              : _game('600+0', 19),
          200,
        );
      }),
    );
    final result = await api.range(
      'alex',
      const PlayerDownloadRange(max: 1, speeds: {'rapid'}),
      cancelled: () => false,
      progress: (_) {},
    );
    expect((result as GamesFetched).games, hasLength(1));
    expect(result.games.single, contains('600+0'));
    expect(asked, hasLength(3));
  });
  test(
    'Lichess rate limits report a wait and cancellation stops retries',
    () async {
      var stopped = false, calls = 0;
      final messages = <String>[];
      final api = LichessGamesApi(
        MockClient((_) async {
          calls++;
          return http.Response('', 429);
        }),
        token: () async => null,
        wait: (_) async {
          stopped = true;
        },
      );
      await api.range(
        'alex',
        const PlayerDownloadRange(),
        cancelled: () => stopped,
        progress: messages.add,
      );
      expect(calls, 1);
      expect(messages.single, contains('Retrying in 60 seconds'));
    },
  );
  test('US Chess handles regular ratings and reports a missing ID', () async {
    final client = MockClient(
      (request) async => request.url.path.endsWith('12345678')
          ? http.Response(
              jsonEncode({
                'firstName': 'Alex',
                'lastName': 'Rivera',
                'ratings': [
                  {'ratingSystem': 'R', 'rating': 1910},
                ],
              }),
              200,
            )
          : http.Response('', 404),
    );
    final found = await PlayerRatings(client).lookup('12345678');
    expect(found.name, 'Alex Rivera');
    expect(found.rating, 1910);
    await expectLater(
      PlayerRatings(client).lookup('87654321'),
      throwsFormatException,
    );
    await expectLater(
      PlayerRatings(client).lookup('alex'),
      throwsFormatException,
    );
  });
}
