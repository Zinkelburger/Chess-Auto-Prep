import 'dart:convert';

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

  test('a chapter added to a study that has chapters says nothing of the '
      'first one', () async {
    final w = writer(
      (_) => http.Response('{"chapters":[{"id":"bbbb2222"}]}', 200),
    );
    await w.api.addChapter(
      'wxyz9876',
      pgn: '1. d4 *',
      name: 'Second',
      orientation: Side.white,
    );
    expect(w.asked.single.bodyFields.containsKey('initial'), isFalse);
  });

  test('signed in means a token that says something', () async {
    expect(await writer((_) => http.Response('', 200)).api.signedIn, isTrue);
    expect(
      await writer((_) => http.Response('', 200), token: null).api.signedIn,
      isFalse,
    );
    expect(
      await writer((_) => http.Response('', 200), token: '').api.signedIn,
      isFalse,
    );
  });

  test('tags follow only moves that were written, and only when there are '
      'tags', () async {
    final refused = writer((_) => http.Response('', 404));
    await refused.api.replaceChapter(
      'wxyz9876',
      'aaaa1111',
      pgn: '1. e4 *',
      tags: const {'White': 'Morphy'},
    );
    expect(refused.asked, hasLength(1), reason: 'no tags after a refusal');
    final bare = writer((_) => http.Response('{}', 200));
    await bare.api.replaceChapter(
      'wxyz9876',
      'aaaa1111',
      pgn: '1. e4 *',
      tags: const {},
    );
    expect(bare.asked, hasLength(1), reason: 'no tags to send');
  });

  test('only a 2xx answer is a write; a 300 is not', () async {
    final w = writer((_) => http.Response('{}', 300));
    final result = await w.api.replaceChapter(
      'wxyz9876',
      'aaaa1111',
      pgn: '1. e4 *',
      tags: const {},
    );
    expect((result as LichessNotWritten).problem, LichessWriteProblem.http);
    final ok = writer((_) => http.Response('{}', 299));
    expect(
      await ok.api.replaceChapter(
        'wxyz9876',
        'aaaa1111',
        pgn: '1. e4 *',
        tags: const {},
      ),
      isA<LichessWritten>(),
    );
  });

  test('Lichess\'s own words come only with a 400: a sentence, or the first '
      'field error there is', () async {
    Future<LichessNotWritten> answer(int status, String body) async {
      final w = writer((_) => http.Response(body, status));
      return await w.api.replaceChapter(
            'wxyz9876',
            'aaaa1111',
            pgn: '1. e4 *',
            tags: const {},
          )
          as LichessNotWritten;
    }

    expect(
      (await answer(400, '{"error":"Illegal move e5"}')).detail,
      'Illegal move e5',
    );
    expect(
      (await answer(400, '{"error":{"name":[],"pgn":["Bad PGN"]}}')).detail,
      'Bad PGN',
    );
    expect((await answer(500, '{"error":"Down"}')).detail, isNull);
    expect((await answer(401, '{"error":"No"}')).detail, isNull);
  });

  test('an answer with a byte that is not UTF-8 is still read', () async {
    final w = writer(
      (_) => http.Response.bytes([
        ...utf8.encode('{"error":"Caf'),
        0xE9,
        ...utf8.encode('"}'),
      ], 400),
    );
    final result = await w.api.replaceChapter(
      'wxyz9876',
      'aaaa1111',
      pgn: '1. e4 *',
      tags: const {},
    );
    expect((result as LichessNotWritten).detail, startsWith('Caf'));
  });
}

final class SocketLike implements Exception {
  const SocketLike();
}
