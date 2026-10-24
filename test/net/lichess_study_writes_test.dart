import 'package:chess_auto_prep/net/lichess_study_writes.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The writer with scripted answers, remembering the requests it made.
({LichessStudyWriterApi api, List<http.Request> asked}) writer(
  http.Response Function(http.Request request) answer, {
  String? token = 'lip_token',
}) {
  final asked = <http.Request>[];
  final stub = MockClient((request) async {
    asked.add(request);
    return answer(request);
  });
  return (
    api: LichessStudyWriterApi(stub, token: () async => token),
    asked: asked,
  );
}

void main() {
  test('making a study: a private one, named, with the token', () async {
    final w = writer((_) => http.Response('{"id":"wxyz9876"}', 200));
    final made = await w.api.create('Plane games');
    expect(made, isA<LichessWritten>());
    expect((made as LichessWritten).id, 'wxyz9876');
    final request = w.asked.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), 'https://lichess.org/api/study');
    expect(request.headers['Authorization'], 'Bearer lip_token');
    expect(request.bodyFields['name'], 'Plane games');
    expect(request.bodyFields['visibility'], 'private');
  });

  test('adding a chapter: its name, side and moves; the new id', () async {
    final w = writer(
      (_) => http.Response(
        '{"chapters":[{"id":"aaaa1111","name":"Morphy - Duke"}],"error":null}',
        200,
      ),
    );
    final added = await w.api.addChapter(
      'wxyz9876',
      pgn: '1. e4 *',
      name: 'Morphy - Duke',
      orientation: Side.black,
      initial: true,
    );
    expect((added as LichessWritten).id, 'aaaa1111');
    final request = w.asked.single;
    expect(request.url.path, '/api/study/wxyz9876/import-pgn');
    expect(request.bodyFields, {
      'pgn': '1. e4 *',
      'name': 'Morphy - Duke',
      'orientation': 'black',
      'initial': 'true',
    });
  });

  test('replacing a chapter: its moves, then the tags Lichess keeps', () async {
    final w = writer((_) => http.Response('', 204));
    final done = await w.api.replaceChapter(
      'wxyz9876',
      'aaaa1111',
      pgn: '1. e4 *',
      tags: {'White': 'Morphy, "Paul"', 'Result': '1-0'},
    );
    expect(done, isA<LichessWritten>());
    expect(w.asked.map((r) => r.url.path), [
      '/api/study/wxyz9876/aaaa1111/moves',
      '/api/study/wxyz9876/aaaa1111/tags',
    ]);
    expect(w.asked.first.bodyFields['pgn'], '1. e4 *');
    expect(
      w.asked.last.bodyFields['pgn'],
      '[White "Morphy, \\"Paul\\""]\n[Result "1-0"]',
    );
  });

  test('without a token nothing is asked', () async {
    final w = writer((_) => http.Response('', 200), token: null);
    final made = await w.api.create('Plane games');
    expect((made as LichessNotWritten).problem, LichessWriteProblem.signedOut);
    expect(made.problem.needsLogin, isTrue);
    expect(w.asked, isEmpty);
  });

  test('what Lichess answers becomes a reason the user can act on', () async {
    Future<LichessWriteProblem> problem(int status, [String body = '']) async {
      final w = writer((_) => http.Response(body, status));
      final result = await w.api.replaceChapter(
        'wxyz9876',
        'aaaa1111',
        pgn: '1. e4 *',
        tags: const {},
      );
      return (result as LichessNotWritten).problem;
    }

    expect(await problem(401), LichessWriteProblem.permission);
    expect(await problem(403), LichessWriteProblem.permission);
    expect(await problem(404), LichessWriteProblem.notFound);
    expect(await problem(429), LichessWriteProblem.limited);
    expect(
      await problem(400, '{"error":"Invalid or forbidden chapter x/y"}'),
      LichessWriteProblem.notFound,
    );
    expect(
      await problem(400, '{"error":"Illegal move e5"}'),
      LichessWriteProblem.rejected,
    );
    expect(await problem(500), LichessWriteProblem.http);
  });

  test('a chapter Lichess could not read says what Lichess said', () async {
    final w = writer(
      (_) => http.Response('{"chapters":[],"error":"Invalid PGN"}', 200),
    );
    final added = await w.api.addChapter(
      'wxyz9876',
      pgn: 'nonsense',
      name: 'Bad',
      orientation: Side.white,
    );
    expect((added as LichessNotWritten).problem, LichessWriteProblem.rejected);
    expect(added.sentence, contains('Invalid PGN'));
  });

  test(
    'a study the account may not add to is said so, whatever the status',
    () async {
      final w = writer(
        (_) => http.Response(
          '{"chapters":[],"error":"No permission to add chapter"}',
          200,
        ),
      );
      final added = await w.api.addChapter(
        'theirs01',
        pgn: '1. e4 *',
        name: 'Mine',
        orientation: Side.white,
      );
      expect(
        (added as LichessNotWritten).problem,
        LichessWriteProblem.notFound,
      );
      final silent = writer((_) => http.Response('{"chapters":[]}', 200));
      final nothing = await silent.api.addChapter(
        'theirs01',
        pgn: '1. e4 *',
        name: 'Mine',
        orientation: Side.white,
      );
      expect(
        (nothing as LichessNotWritten).problem,
        LichessWriteProblem.notFound,
      );
    },
  );

  test('no answer at all is the connection', () async {
    final stub = MockClient((_) async => throw const SocketLike());
    final api = LichessStudyWriterApi(stub, token: () async => 'lip_token');
    final made = await api.create('Plane games');
    expect(
      (made as LichessNotWritten).problem,
      LichessWriteProblem.unreachable,
    );
  });
}

final class SocketLike implements Exception {
  const SocketLike();
}
