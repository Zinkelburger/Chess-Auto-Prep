import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The client with a scripted answer and the token the user is signed in
/// with, remembering the request it made.
({LichessStudyApi api, List<http.Request> asked}) client(
  http.Response Function(http.Request request) answer, {
  String? token,
}) {
  final asked = <http.Request>[];
  final stub = MockClient((request) async {
    asked.add(request);
    return answer(request);
  });
  return (
    api: LichessStudyApi(stub, token: () async => token),
    asked: asked,
  );
}

const _link = LichessStudyLink(studyId: 'abcd1234');

void main() {
  test('recognising a link: a study link, with or without a scheme or a slug', () {
    expect(parseStudyLink('https://lichess.org/study/abcd1234'), _link);
    expect(parseStudyLink('lichess.org/study/abcd1234'), _link);
    expect(parseStudyLink('  lichess.org/study/abcd1234/slug?x=1  '), _link);
  });

  test('recognising a link: a chapter link keeps the chapter', () {
    expect(
      parseStudyLink('lichess.org/study/abcd1234/efgh5678'),
      const LichessStudyLink(studyId: 'abcd1234', chapterId: 'efgh5678'),
    );
  });

  test('recognising a link: anything else is not one', () {
    expect(parseStudyLink(''), isNull);
    expect(parseStudyLink('lichess.org/study/by/thibault'), isNull);
    expect(parseStudyLink('chessgames.com/perl/chesscollection?cid=1'),
        isNull);
    expect(parseStudyLink('lichess.org/study/short'), isNull);
    expect(parseStudyLink('example.com/study/abcd1234'), isNull);
  });

  test('recognising a link: says what it recognised', () {
    expect(_link.describe, 'Lichess study · abcd1234');
    expect(
      const LichessStudyLink(studyId: 'a', chapterId: 'b').describe,
      'Lichess study chapter · a/b',
    );
  });

  test('downloading: asks for comments and variations, and no clocks', () async {
    final stub = client((_) => http.Response('[Event "S: C"]\n\n*\n', 200));
    await stub.api.fetch(_link);
    final url = stub.asked.single.url;
    expect(url.host, 'lichess.org');
    expect(url.path, '/api/study/abcd1234.pgn');
    expect(url.queryParameters['clocks'], 'false');
    expect(url.queryParameters['comments'], 'true');
    expect(url.queryParameters['variations'], 'true');
  });

  test('downloading: a chapter link asks for that chapter alone', () async {
    final stub = client((_) => http.Response('[Event "S: C"]\n\n*\n', 200));
    await stub.api.fetch(
      const LichessStudyLink(studyId: 'abcd1234', chapterId: 'efgh5678'),
    );
    expect(stub.asked.single.url.path, '/api/study/abcd1234/efgh5678.pgn');
  });

  test('downloading: brings the PGN back as UTF-8', () async {
    final stub = client(
      (_) => http.Response.bytes(
        [0x7b, 0xc3, 0xa9, 0x7d], // {é}
        200,
      ),
    );
    expect(await stub.api.fetch(_link), isA<StudyFetched>());
    expect((await stub.api.fetch(_link) as StudyFetched).pgn, '{é}');
  });

  test('downloading: signs the request when the user has a token', () async {
    final stub = client(
      (_) => http.Response('x', 200),
      token: 'secret-token',
    );
    await stub.api.fetch(_link);
    expect(stub.asked.single.headers['Authorization'], 'Bearer secret-token');
  });

  test('downloading: sends no header when the user is not signed in', () async {
    final stub = client((_) => http.Response('x', 200));
    await stub.api.fetch(_link);
    expect(stub.asked.single.headers.containsKey('Authorization'), isFalse);
  });

  Future<StudyNotFetched> failing(http.Response answer) async =>
      await client((_) => answer).api.fetch(_link) as StudyNotFetched;

  test('when it does not arrive: a request that throws is unreachable, not empty', () async {
    final stub = MockClient((_) async => throw http.ClientException(
          'no route to host',
        ));
    final result = await LichessStudyApi(
      stub,
      token: () async => null,
    ).fetch(_link);
    expect(
      (result as StudyNotFetched).problem,
      StudyFetchProblem.unreachable,
    );
  });

  test('when it does not arrive: 404 says where to look for a private study', () async {
    final result = await failing(http.Response('', 404));
    expect(result.problem, StudyFetchProblem.notFound);
    expect(result.sentence, contains('private or unlisted'));
  });

  test('when it does not arrive: 401 and 403 say the account was rejected', () async {
    expect(
      (await failing(http.Response('', 401))).problem,
      StudyFetchProblem.rejected,
    );
    expect(
      (await failing(http.Response('', 403))).problem,
      StudyFetchProblem.rejected,
    );
  });

  test('when it does not arrive: 429 and 500 name the status', () async {
    expect(
      (await failing(http.Response('', 429))).sentence,
      contains('HTTP 429'),
    );
    expect(
      (await failing(http.Response('', 500))).sentence,
      contains('HTTP 500'),
    );
  });

  test('when it does not arrive: an answer with nothing in it is empty, not a study', () async {
    expect(
      (await failing(http.Response('   \n', 200))).problem,
      StudyFetchProblem.empty,
    );
  });
}
