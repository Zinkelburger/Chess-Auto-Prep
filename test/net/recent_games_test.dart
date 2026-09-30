import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:chess_auto_prep/net/lichess_http.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:fake_async/fake_async.dart';
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

/// A Lichess client whose export streams as [answer] gives it, on the fake
/// clock of the test, waiting for real (fake) time between attempts.
LichessGamesApi _streaming(
  Future<http.StreamedResponse> Function(http.BaseRequest) answer,
) => LichessGamesApi(
  MockClient.streaming((request, _) => answer(request)),
  token: () async => null,
);

/// Six months of [api]'s games on [clock], with [cancelled] as the cancel
/// check; the answer lands in the returned list once it arrives.
List<GamesFetch> _sixMonths(
  FakeAsync clock,
  LichessGamesApi api, {
  bool Function()? cancelled,
  void Function(String)? progress,
}) {
  final fetched = <GamesFetch>[];
  clock.run(
    (_) => unawaited(
      api
          .range(
            'me',
            const PlayerDownloadRange(months: 6),
            cancelled: cancelled ?? () => false,
            progress: progress ?? (_) {},
          )
          .then(fetched.add),
    ),
  );
  return fetched;
}

/// Moves [clock] on by [time] a second at a time, letting the real event
/// queue run between steps: a stream's cancel and done complete through
/// it, outside the fake zone.
Future<void> _elapse(FakeAsync clock, Duration time) async {
  const step = Duration(seconds: 1);
  for (var gone = Duration.zero; gone < time; gone += step) {
    clock.elapse(step);
    await Future<void>.delayed(Duration.zero);
  }
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
        expect(request.headers['User-Agent'], appUserAgent);
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
      expect(request.headers['User-Agent'], appUserAgent);
    });

    test('no token, no Authorization header', () async {
      await _lichess([() => _pgn('')]).recent('me', max: 1);
      expect(_asked.single.headers.containsKey('Authorization'), isFalse);
    });

    test('a refused token is dropped and the export asked for again', () async {
      final fetched = await _lichess([
        () => http.Response('{"error":"No such token"}', 401),
        () => _pgn(scholarsMate),
      ], token: 'stale').recent('me', max: 20);

      expect((fetched as GamesFetched).games, [scholarsMate]);
      expect(_asked, hasLength(2));
      expect(_asked.first.headers['Authorization'], 'Bearer stale');
      expect(_asked.last.headers.containsKey('Authorization'), isFalse);
      expect(_waited, isEmpty);
    });

    test('a token refused after a 429 wait is dropped too', () async {
      final fetched = await _lichess([
        () => http.Response('', 429),
        () => http.Response('', 401),
        () => _pgn(scholarsMate),
      ], token: 'stale').recent('me', max: 20);

      expect((fetched as GamesFetched).games, [scholarsMate]);
      expect(_asked, hasLength(3));
      expect(_waited, const [Duration(seconds: 60)]);
      expect(_asked[1].headers['Authorization'], 'Bearer stale');
      expect(_asked.last.headers.containsKey('Authorization'), isFalse);
    });

    test('a 401 without the token too fails after one retry', () async {
      final fetched = await _lichess([
        () => http.Response('', 401),
      ], token: 'stale').recent('me', max: 20);

      expect((fetched as GamesNotFetched).problem, GamesProblem.http);
      expect(fetched.status, 401);
      expect(_asked, hasLength(2));
      expect(_waited, isEmpty);
    });

    test('a 401 with no token is not retried', () async {
      final fetched = await _lichess([
        () => http.Response('', 401),
      ]).recent('me', max: 20);

      expect((fetched as GamesNotFetched).status, 401);
      expect(_asked, hasLength(1));
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

  group('Lichess streaming its export', () {
    test('a long throttled export is read to the end', () async {
      final clock = FakeAsync();
      Stream<List<int>> throttled() async* {
        for (var i = 0; i < 900; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          yield utf8.encode('$scholarsMate\n\n');
        }
      }

      final fetched = _sixMonths(
        clock,
        _streaming((_) async => http.StreamedResponse(throttled(), 200)),
      );
      await _elapse(clock, const Duration(seconds: 91));

      expect((fetched.single as GamesFetched).games, hasLength(900));
    });

    test('games are counted even when a chunk splits a tag', () async {
      final clock = FakeAsync();
      final said = <String>[];
      final text = utf8.encode('$scholarsMate\n\n$scholarsMate\n\n');
      final split = utf8.encode('$scholarsMate\n\n[Ev').length;
      final fetched = _sixMonths(
        clock,
        _streaming(
          (_) async => http.StreamedResponse(
            Stream.fromIterable([text.sublist(0, split), text.sublist(split)]),
            200,
          ),
        ),
        progress: said.add,
      );
      await _elapse(clock, const Duration(seconds: 2));

      expect((fetched.single as GamesFetched).games, hasLength(2));
      expect(said.last, '2 games downloaded');
    });

    test('cancel while the export is quiet aborts it promptly', () async {
      final clock = FakeAsync();
      var cancel = false, asked = 0, aborted = false;
      final fetched = _sixMonths(
        clock,
        _streaming((request) async {
          asked++;
          // One game, then silence; an abort ends the body as IOClient does.
          final body = StreamController<List<int>>()
            ..add(utf8.encode('$scholarsMate\n\n'));
          unawaited(
            (request as http.Abortable).abortTrigger!.whenComplete(() {
              aborted = true;
              body.addError(http.RequestAbortedException(request.url));
              unawaited(body.close());
            }),
          );
          return http.StreamedResponse(body.stream, 200);
        }),
        cancelled: () => cancel,
      );
      await _elapse(clock, const Duration(seconds: 5));
      expect(fetched, isEmpty);

      cancel = true;
      await _elapse(clock, const Duration(seconds: 2));
      expect(aborted, isTrue);
      expect((fetched.single as GamesFetched).games, isEmpty);

      await _elapse(clock, const Duration(minutes: 2));
      expect(asked, 1);
    });

    test('a stalled export is aborted before it is tried again', () async {
      final clock = FakeAsync();
      final aborted = <bool>[];
      final abortedBeforeNext = <bool>[];
      var open = 0, most = 0;
      final fetched = _sixMonths(
        clock,
        _streaming((request) async {
          abortedBeforeNext.add(aborted.every((a) => a));
          final at = aborted.length;
          aborted.add(false);
          most = ++open > most ? open : most;
          final trigger = request is http.Abortable
              ? request.abortTrigger
              : null;
          if (trigger != null) {
            unawaited(
              trigger.whenComplete(() {
                aborted[at] = true;
                open--;
              }),
            );
          }
          // One game, then silence: the body is never finished.
          final body = StreamController<List<int>>()
            ..add(utf8.encode('$scholarsMate\n\n'));
          addTearDown(() => body.close());
          return http.StreamedResponse(body.stream, 200);
        }),
      );
      await _elapse(clock, const Duration(minutes: 10));

      expect(aborted, hasLength(4));
      expect(abortedBeforeNext, everyElement(isTrue));
      expect(most, 1);
      expect(
        (fetched.single as GamesNotFetched).problem,
        GamesProblem.unreachable,
      );
    });

    test('cancel during a 429 backoff returns promptly', () async {
      final clock = FakeAsync();
      var cancel = false, asked = 0;
      final fetched = _sixMonths(
        clock,
        _streaming((_) async {
          asked++;
          return http.StreamedResponse(const Stream.empty(), 429);
        }),
        cancelled: () => cancel,
      );
      await _elapse(clock, const Duration(seconds: 10));
      expect(fetched, isEmpty);

      cancel = true;
      await _elapse(clock, const Duration(seconds: 1));
      expect((fetched.single as GamesFetched).games, isEmpty);

      await _elapse(clock, const Duration(minutes: 10));
      expect(asked, 1);
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

    test('an archive list that is not one is unreadable, not empty', () {
      expect(archivesNewestFirst('nonsense'), isNull);
      expect(archivesNewestFirst('{"code":0}'), isNull);
      expect(archivesNewestFirst('{"archives": []}'), isEmpty);
      expect(archivesNewestFirst('{"archives": ["a", 3, "b"]}'), ['b', 'a']);
    });

    test('an unreadable archive list fails the download', () async {
      final fetched = await _chesscom({
        '$_archives/archives': () => http.Response('<html>', 200),
      }).recent('me', max: 2);
      expect((fetched as GamesNotFetched).problem, GamesProblem.http);
      expect(fetched.status, 200);
    });
  });
}
