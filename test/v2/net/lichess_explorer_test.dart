import 'dart:convert';

import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _answer = {
  'white': 200,
  'draws': 100,
  'black': 50,
  'moves': [
    {'uci': 'd2d4', 'san': 'd4', 'white': 50, 'draws': 30, 'black': 20},
    {'uci': 'e2e4', 'san': 'e4', 'white': 150, 'draws': 70, 'black': 30},
  ],
  'topGames': [
    {
      'id': 'abcd1234',
      'winner': 'white',
      'white': {'name': 'Carlsen', 'rating': 2830},
      'black': {'name': 'Nakamura', 'rating': 2780},
      'year': 2024,
    },
  ],
  'recentGames': [
    {
      'id': 'abcd1234',
      'winner': 'white',
      'white': {'name': 'Carlsen', 'rating': 2830},
      'black': {'name': 'Nakamura', 'rating': 2780},
      'year': 2024,
    },
    {
      'id': 'efgh5678',
      'winner': null,
      'white': {'name': 'Ding'},
      'black': {'name': 'Giri'},
    },
  ],
};

/// A client with a scripted answer, a clock the test turns and a wait the
/// test records instead of sleeping through.
final class _Stub {
  _Stub(http.Response Function(http.Request) answer, {String? token}) {
    api = LichessExplorerApi(
      MockClient((request) async {
        asked.add(request);
        return answer(request);
      }),
      token: () async => token,
      now: () => now,
      wait: (d) async => waited.add(d),
    );
  }

  late final LichessExplorerApi api;
  final asked = <http.Request>[];
  final waited = <Duration>[];
  DateTime now = DateTime(2026, 9, 22, 12);
}

const _masters = ExplorerQuery(Fen.initial, ExplorerChoice.defaults);
const _lichess = ExplorerQuery(
  Fen.initial,
  ExplorerChoice(source: ExplorerSource.lichess),
);

void main() {
  test('asks the masters database for the position and 15 games', () async {
    final stub = _Stub((_) => http.Response(jsonEncode(_answer), 200));
    await stub.api.fetch(_masters);
    final url = stub.asked.single.url;
    expect(url.host, 'explorer.lichess.ovh');
    expect(url.path, '/masters');
    expect(url.queryParameters['fen'], Fen.initial.value);
    expect(url.queryParameters['topGames'], '15');
    expect(url.queryParameters.containsKey('speeds'), isFalse);
  });

  test('asks the Lichess database with its chips and the token', () async {
    final stub = _Stub(
      (_) => http.Response(jsonEncode(_answer), 200),
      token: 'lip_secret',
    );
    await stub.api.fetch(_lichess);
    final request = stub.asked.single;
    expect(request.url.path, '/lichess');
    expect(request.url.queryParameters['speeds'], 'blitz,rapid,classical');
    expect(request.url.queryParameters['ratings'], '2000,2200,2500');
    expect(request.url.queryParameters['topGames'], '4');
    expect(request.url.queryParameters['recentGames'], '4');
    expect(request.headers['Authorization'], 'Bearer lip_secret');
  });

  test('reads the answer: moves most played first, games once each, '
      'results from the winner', () async {
    final stub = _Stub((_) => http.Response(jsonEncode(_answer), 200));
    final fetched = await stub.api.fetch(_masters) as ExplorerFetched;
    final answer = fetched.answer;
    expect(answer.moves.map((m) => m.san), ['e4', 'd4']);
    expect(answer.moves.first.games, 250);
    expect(answer.whiteTotal, 200);
    expect(answer.games.map((g) => g.id), ['abcd1234', 'efgh5678']);
    expect(answer.games.first.result, '1-0');
    expect(answer.games.first.whiteElo, 2830);
    expect(answer.games.last.result, '1/2-1/2');
    expect(answer.games.last.year, isNull);
  });

  test(
    'an answer that is not the API\'s shape is a failure, not a crash',
    () async {
      final stub = _Stub((_) => http.Response('<html>', 200));
      final fetch = await stub.api.fetch(_masters);
      expect((fetch as ExplorerNotFetched).problem, ExplorerProblem.http);
    },
  );

  test(
    'a request that throws is tried three times, then is unreachable',
    () async {
      final stub = _Stub((_) => throw http.ClientException('no route'));
      final fetch = await stub.api.fetch(_masters);
      expect(
        (fetch as ExplorerNotFetched).problem,
        ExplorerProblem.unreachable,
      );
      expect(stub.asked, hasLength(3));
    },
  );

  test('a 500 names the status; a 401 asks for the token', () async {
    final failing = _Stub((_) => http.Response('', 500));
    final fetch = await failing.api.fetch(_masters) as ExplorerNotFetched;
    expect(fetch.problem, ExplorerProblem.http);
    expect(fetch.sentence, 'Lichess could not answer. It answered HTTP 500.');
    final refused = _Stub((_) => http.Response('', 401));
    final refusal = await refused.api.fetch(_masters) as ExplorerNotFetched;
    expect(refusal.problem, ExplorerProblem.rejected);
  });

  test('a 429 shuts the door for a minute, then two: the next position is '
      'answered as rate-limited without a request', () async {
    final stub = _Stub((_) => http.Response('', 429));
    final first = await stub.api.fetch(_masters) as ExplorerNotFetched;
    expect(first.problem, ExplorerProblem.rateLimited);
    expect(stub.asked, hasLength(1));
    final second = await stub.api.fetch(_lichess) as ExplorerNotFetched;
    expect(second.problem, ExplorerProblem.rateLimited);
    expect(stub.asked, hasLength(1), reason: 'not asked');
    expect(await stub.api.gamePgn('abcd1234', masters: true), isNull);
    stub.now = stub.now.add(const Duration(seconds: 61));
    await stub.api.fetch(_masters);
    expect(stub.asked, hasLength(2), reason: 'the door opened');
    // The second 429 shuts it for two minutes.
    stub.now = stub.now.add(const Duration(seconds: 61));
    await stub.api.fetch(_masters);
    expect(stub.asked, hasLength(2));
    stub.now = stub.now.add(const Duration(seconds: 60));
    await stub.api.fetch(_masters);
    expect(stub.asked, hasLength(3));
  });

  test('two requests are at least 100 ms apart', () async {
    final stub = _Stub((_) => http.Response(jsonEncode(_answer), 200));
    await stub.api.fetch(_masters);
    stub.now = stub.now.add(const Duration(milliseconds: 40));
    await stub.api.fetch(_lichess);
    expect(stub.waited, [const Duration(milliseconds: 60)]);
  });

  test('fetches a game as PGN from the right place', () async {
    final stub = _Stub((_) => http.Response('[Event "x"]\n\n1. e4 *\n', 200));
    expect(
      await stub.api.gamePgn('abcd1234', masters: true),
      '[Event "x"]\n\n1. e4 *',
    );
    final masters = stub.asked.single;
    expect(
      masters.url.toString(),
      'https://explorer.lichess.ovh/masters/pgn/abcd1234',
    );
    expect(masters.headers['Accept'], 'application/x-chess-pgn');
    await stub.api.gamePgn('efgh5678', masters: false);
    final lichess = stub.asked.last.url;
    expect(lichess.host, 'lichess.org');
    expect(lichess.path, '/game/export/efgh5678');
    expect(lichess.queryParameters['clocks'], '0');
  });
}
