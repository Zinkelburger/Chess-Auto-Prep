import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/mainline_book.dart';
import 'package:chess_auto_prep/net/chessdb_moves.dart';
import 'package:chess_auto_prep/net/remote_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const afterE4 = Fen(
  'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
);
const afterD4 = Fen(
  'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
);

void main() {
  test('queryall answers are moves best first, mates packed as the search '
      'packs them, unscored moves left out', () {
    expect(
      chessDbMoves(
        'move:d2d4,score:25,rank:2,note:! (26-00),winrate:52.1|'
        'move:e2e4,score:32,rank:2,note:!|move:a2a3,score:??,rank:0|'
        'move:g1f3,score:29998,rank:2',
      ),
      [(uci: 'g1f3', cp: 9998), (uci: 'e2e4', cp: 32), (uci: 'd2d4', cp: 25)],
    );
    expect(chessDbMoves('unknown'), isEmpty);
    expect(chessDbMoves('checkmate'), isEmpty);
  });

  test('a position is asked once per run; a refusal drops the run', () async {
    var calls = 0;
    final moves = ChessDbMoves(
      RemoteQueue(
        MockClient((request) async {
          calls++;
          expect(request.url.queryParameters['action'], 'queryall');
          expect(request.url.queryParameters['learn'], '0');
          return calls == 1
              ? http.Response('move:e2e4,score:30', 200)
              : http.Response('', 429);
        }),
      ).run(),
    );
    addTearDown(moves.close);
    expect(await moves.movesAt(Fen.initial), [(uci: 'e2e4', cp: 30)]);
    expect(await moves.movesAt(Fen.initial), [(uci: 'e2e4', cp: 30)]);
    expect(calls, 1);
    expect(await moves.movesAt(afterE4), isNull);
    expect(moves.dropped, isTrue, reason: 'what the run found is incomplete');
    expect(await moves.movesAt(afterD4), isNull);
    expect(calls, 2, reason: 'nothing is asked after a refusal');
  });

  test('one miss is not an outage and is not remembered; three in a row '
      'drop the run', () async {
    var calls = 0;
    final moves = ChessDbMoves(
      RemoteQueue(
        MockClient((request) async {
          calls++;
          if (calls == 2) return http.Response('move:e7e5,score:-30', 200);
          throw http.ClientException('no network');
        }),
      ).run(),
    );
    addTearDown(moves.close);
    expect(await moves.movesAt(afterE4), isNull);
    expect(moves.dropped, isFalse);
    expect(await moves.movesAt(afterE4), [
      (uci: 'e7e5', cp: -30),
    ], reason: 'a position that could not be asked is asked again');
    for (var i = 0; i < RemoteRun.missesToDrop; i++) {
      expect(await moves.movesAt(afterD4), isNull);
    }
    expect(moves.dropped, isTrue);
  });

  test('every run goes through one queue, one request at a time', () async {
    var inFlight = 0;
    var most = 0;
    final queue = RemoteQueue(
      MockClient((request) async {
        most = ++inFlight > most ? inFlight : most;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return http.Response('unknown', 200);
      }),
    );
    final one = ChessDbMoves(queue.run());
    final two = ChessDbMoves(queue.run());
    await Future.wait([
      one.movesAt(afterE4),
      two.movesAt(afterD4),
      one.movesAt(Fen.initial),
    ]);
    expect(most, 1);
  });

  test('for the book, one miss is a miss, a refusal is the end, and a spent '
      'run is its budget', () async {
    var calls = 0;
    final moves = ChessDbMoves(
      RemoteQueue(
        MockClient((request) async {
          calls++;
          return switch (calls) {
            1 => http.Response('', 404),
            2 => http.Response('move:e2e4,score:30', 200),
            _ => http.Response('', 503),
          };
        }),
      ).run(limit: 3),
    );
    addTearDown(moves.close);
    expect(await moves.bookAt(Fen.initial), isA<BookMissed>());
    expect(await moves.bookAt(Fen.initial), isA<BookMoves>());
    expect(await moves.bookAt(afterE4), isA<BookLost>());

    final spent = ChessDbMoves(
      RemoteQueue(
        MockClient((_) async => http.Response('unknown', 200)),
      ).run(limit: 1),
    );
    addTearDown(spent.close);
    expect(await spent.bookAt(Fen.initial), isA<BookMoves>());
    expect(await spent.bookAt(afterE4), isA<BookSpent>());
  });
}
