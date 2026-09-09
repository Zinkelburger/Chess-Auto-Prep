/// [fetchLichessStudy] against a scripted HTTP stub: each status code's
/// message, the UTF-8 body decode, and the chapter-name split on the way out.
///
/// `LichessApiClient.instance` builds its `http.Client` the first time it is
/// touched, so the [HttpOverrides] stub is installed before any test runs.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/pgn_parsing_service.dart'
    show extractHeaders, splitPgnIntoGames;
import 'package:chess_auto_prep/services/study_import/import_source.dart';
import 'package:chess_auto_prep/services/study_import/lichess_study_client.dart';
import 'package:chess_auto_prep/services/study_import/study_import_exception.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── HTTP stub ──────────────────────────────────────────────────────────────

typedef _Reply = ({int status, List<int> body});

class _StubHttp extends HttpOverrides {
  final List<Uri> requests = [];
  Map<String, _Reply> routes = {};

  _Reply replyFor(Uri url) {
    requests.add(url);
    return routes['${url.origin}${url.path}'] ?? (status: 404, body: []);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) => _StubClient(this);
}

class _StubClient implements HttpClient {
  _StubClient(this.overrides);
  final _StubHttp overrides;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _StubRequest(url, overrides);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubRequest implements HttpClientRequest {
  _StubRequest(this.url, this.overrides);
  final Uri url;
  final _StubHttp overrides;

  @override
  final HttpHeaders headers = _StubHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  Future<HttpClientResponse>? _response;

  @override
  Future<HttpClientResponse> close() {
    final pending = _response;
    if (pending != null) return pending;
    final reply = overrides.replyFor(url);
    return _response = Future.value(_StubResponse(reply.status, reply.body));
  }

  @override
  Future<HttpClientResponse> get done => close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = ['$value'];
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _StubResponse(this.statusCode, List<int> body) : super(Stream.value(body));

  @override
  final int statusCode;
  @override
  int get contentLength => -1;
  @override
  HttpHeaders get headers => _StubHeaders();
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── Fixtures ───────────────────────────────────────────────────────────────

const _studyUrl = 'https://lichess.org/api/study/WcJ8Iyaz.pgn';
const _userUrl = 'https://lichess.org/api/study/by/bob/export.pgn';
const _study = LichessStudySource(studyId: 'WcJ8Iyaz');

String _chapter(String event) =>
    '[Event "$event"]\n[Result "*"]\n\n1. e4 e5 *\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final stub = _StubHttp();

  setUpAll(() => HttpOverrides.global = stub);

  setUp(() {
    HttpOverrides.global = stub;
    stub.requests.clear();
    stub.routes = {};
    SharedPreferences.setMockInitialValues({});
  });

  Future<StudyImportException> failure(ImportSource source) async {
    try {
      await fetchLichessStudy(source);
    } on StudyImportException catch (e) {
      return e;
    }
    fail('expected a StudyImportException');
  }

  test('asks Lichess for the study with comments and variations on', () async {
    stub.routes[_studyUrl] = (status: 200, body: utf8.encode(_chapter('X')));
    await fetchLichessStudy(_study);
    final url = stub.requests.single;
    expect(url.path, '/api/study/WcJ8Iyaz.pgn');
    expect(url.queryParameters, {
      'clocks': 'false',
      'comments': 'true',
      'variations': 'true',
      'orientation': 'true',
    });
  });

  test('a chapter URL fetches only that chapter', () async {
    const chapterUrl = 'https://lichess.org/api/study/WcJ8Iyaz/mVfBcMlS.pgn';
    stub.routes[chapterUrl] = (status: 200, body: utf8.encode(_chapter('X')));
    await fetchLichessStudy(
      const LichessStudySource(studyId: 'WcJ8Iyaz', chapterId: 'mVfBcMlS'),
    );
    expect(stub.requests.single.path, '/api/study/WcJ8Iyaz/mVfBcMlS.pgn');
  });

  test('lifts the study name out of the chapter events', () async {
    stub.routes[_studyUrl] = (
      status: 200,
      body: utf8.encode(
        '${_chapter('My Study: Chapter 1')}\n${_chapter('My Study: Chapter 2')}',
      ),
    );
    final fetched = await fetchLichessStudy(_study);
    expect(fetched.name, 'My Study');
    final events = splitPgnIntoGames(
      fetched.pgn,
    ).map((g) => extractHeaders(g)['Event']).toList();
    expect(events, ['Chapter 1', 'Chapter 2']);
  });

  test('falls back to the study id when the events carry no prefix', () async {
    stub.routes[_studyUrl] = (
      status: 200,
      body: utf8.encode(_chapter('Just a chapter')),
    );
    final fetched = await fetchLichessStudy(_study);
    expect(fetched.name, 'Lichess study WcJ8Iyaz');
    expect(fetched.pgn, _chapter('Just a chapter'));
  });

  test('decodes the body as UTF-8 even without a charset', () async {
    stub.routes[_studyUrl] = (
      status: 200,
      body: utf8.encode(_chapter('Réti: Ideas')),
    );
    final fetched = await fetchLichessStudy(_study);
    expect(fetched.name, 'Réti');
  });

  test('an empty study is reported, not imported', () async {
    stub.routes[_studyUrl] = (status: 200, body: utf8.encode('  \n'));
    expect((await failure(_study)).message, contains('empty'));
  });

  test('404 on a study explains how to reach a private one', () async {
    final e = await failure(_study);
    expect(e.message, startsWith('Study not found.'));
    expect(e.message, contains('log into Lichess'));
  });

  test('404 on a user names the user', () async {
    final e = await failure(const LichessUserStudiesSource('bob'));
    expect(e.message, 'No public studies found for "bob".');
    expect(stub.requests.single.toString(), startsWith(_userUrl));
  });

  test('401 and 403 both point at the account settings', () async {
    for (final status in [401, 403]) {
      stub.routes[_studyUrl] = (status: status, body: []);
      expect((await failure(_study)).message, contains('Settings → Accounts'));
    }
  });

  test('any other status is reported with its code', () async {
    stub.routes[_studyUrl] = (status: 500, body: []);
    expect((await failure(_study)).message, 'Lichess returned HTTP 500.');
  });

  test('a chessgames source is a programming error, not a message', () {
    expect(
      () => fetchLichessStudy(const ChessgamesCollectionSource('1')),
      throwsArgumentError,
    );
  });
}
