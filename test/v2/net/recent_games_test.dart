import 'dart:convert';

import 'package:chess_auto_prep/v2/net/recent_games.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/my_games_fixture.dart';

final _asked = <http.Request>[];
final _waited = <Duration>[];

/// A Lichess client answering [answers] in turn, the last one repeated,
/// that records its requests and its waits instead of sleeping.
LichessGamesApi _lichess(
  List<http.Response Function()> answers, {
  String? token,
}) {
  _asked.clear();
  _waited.clear();
  return LichessGamesApi(
    MockClient((request) async {
      _asked.add(request);
      final answer = answers.length > 1 ? answers.removeAt(0) : answers.single;
      return answer();
    }),
    token: () async => token,
    wait: (d) async => _waited.add(d),
  );
}

http.Response _pgn(String body) => http.Response.bytes(utf8.encode(body), 200);

const _archives = 'https://api.chess.com/pub/player/me/games';

/// A Chess.com client answering the pages it is given by address, and 404
/// for any other.
ChesscomGamesApi _chesscom(Map<String, http.Response Function()> pages) =>
    ChesscomGamesApi(
      MockClient((request) async {
        final page = pages['${request.url}'];
        if (page == null) return http.Response('', 404);
        expect(request.headers['User-Agent'], gamesUserAgent);
        return page();
      }),
      wait: (_) async {},
    );

http.Response _archiveList(List<String> months) => http.Response(
  jsonEncode({
    'archives': [for (final m in months) '$_archives/$m'],
  }),
  200,
);

void main() {
  group('Lichess', () {
    test('asks for the newest games of standard chess, with the token as a '
        'bearer, and answers each game', () async {
      final fetched = await _lichess([
        () => _pgn('$scholarsMate\n\n$quietChesscomGame\n'),
      ], token: 'tok').recent('Me', max: 20);

      expect((fetched as GamesFetched).games, [
        scholarsMate,
        quietChesscomGame,
      ]);
      final request = _asked.single;
      expect(request.url.path, '/api/games/user/Me');
      expect(request.url.queryParameters['max'], '20');
      expect(request.url.queryParameters['perfType'], contains('blitz'));
      expect(request.headers['Authorization'], 'Bearer tok');
      expect(request.headers['Accept'], 'application/x-chess-pgn');
      expect(request.headers['User-Agent'], gamesUserAgent);
    });

    test('no token, no Authorization header', () async {
      await _lichess([() => _pgn('')]).recent('me', max: 1);
      expect(_asked.single.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('Lichess when it will not answer', () {
    test(
      'a 429 waits a minute, then two, then four, and then gives up',
      () async {
        final fetched = await _lichess([
          () => http.Response('', 429),
        ]).recent('me', max: 20);

        expect(_waited, const [
          Duration(seconds: 60),
          Duration(seconds: 120),
          Duration(seconds: 240),
        ]);
        expect(_asked, hasLength(4));
        expect((fetched as GamesNotFetched).problem, GamesProblem.rateLimited);
      },
    );

    test('a 429 that clears gives the games', () async {
      final fetched = await _lichess([
        () => http.Response('', 429),
        () => _pgn(scholarsMate),
      ]).recent('me', max: 20);

      expect(_waited, const [Duration(seconds: 60)]);
      expect((fetched as GamesFetched).games, [scholarsMate]);
    });

    test('no connection is tried again after two seconds, then is '
        'unreachable', () async {
      final fetched = await _lichess([
        () => throw http.ClientException('offline'),
      ]).recent('me', max: 20);

      expect(_waited, List.filled(3, const Duration(seconds: 2)));
      expect((fetched as GamesNotFetched).problem, GamesProblem.unreachable);
    });

    test('an unknown player is said so', () async {
      final fetched = await _lichess([
        () => http.Response('', 404),
      ]).recent('nobody', max: 20);
      expect((fetched as GamesNotFetched).problem, GamesProblem.noSuchPlayer);
    });
  });

  group('Chess.com', () {
    test('walks the months from the newest, each month newest first, and '
        'stops at enough games', () async {
      final older = scholarsMate.replaceFirst('AbCd1234', 'Older123');
      final fetched = await _chesscom({
        '$_archives/archives': () => _archiveList(['2026/07', '2026/08']),
        '$_archives/2026/08/pgn': () =>
            http.Response([scholarsMate, quietChesscomGame].join('\n\n'), 200),
        '$_archives/2026/07/pgn': () => http.Response(older, 200),
      }).recent('Me', max: 2);

      expect((fetched as GamesFetched).games, [
        quietChesscomGame,
        scholarsMate,
      ]);
    });

    test('an unknown player is said so', () async {
      final fetched = await _chesscom({}).recent('Me', max: 2);
      expect((fetched as GamesNotFetched).problem, GamesProblem.noSuchPlayer);
    });

    test('a month that cannot be fetched fails the download', () async {
      final fetched = await _chesscom({
        '$_archives/archives': () => _archiveList(['2026/08']),
        '$_archives/2026/08/pgn': () => throw http.ClientException('offline'),
      }).recent('me', max: 2);
      expect((fetched as GamesNotFetched).problem, GamesProblem.unreachable);
    });

    test('an archive list that is not one reads as no months', () {
      expect(archivesNewestFirst('nonsense'), isEmpty);
      expect(archivesNewestFirst('{"archives": ["a", 3, "b"]}'), ['b', 'a']);
    });
  });
}
