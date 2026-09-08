/// [StudyImportController] end to end against a scripted HTTP stub and a
/// temp directory: what a run writes, what it caches, how it resumes, and
/// how a cancel or a refusal lands on the result and the job.
///
/// Pacing is real time. The request gap clamps to at least 5 s, so every
/// test either fetches one game (the first request is never delayed) or is
/// served from the cache; the two pacing tests cancel out of the wait after
/// its first one-second tick.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart'
    show extractHeaders, splitPgnIntoGames;
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/services/study_import/study_import_controller.dart';
import 'package:chess_auto_prep/services/study_import/study_import_exception.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// ── Platform stubs ─────────────────────────────────────────────────────────

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => p.join(root, 'docs');

  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'support');
}

/// Real files under the temp root; only what the controller calls.
class _FileStorage implements StorageService {
  _FileStorage(this.root);
  final String root;
  bool failWrites = false;

  @override
  Future<String> studyFilePath(String name) async =>
      p.join(root, 'studies', '$name.pgn');

  @override
  Future<bool> fileExists(String path) => File(path).exists();

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failWrites) throw const FileSystemException('disk full');
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

// ── HTTP stub ──────────────────────────────────────────────────────────────

typedef _Reply = ({int status, String body});

class _StubHttp extends HttpOverrides {
  final List<Uri> requests = [];
  Map<String, _Reply> routes = {};

  _Reply replyFor(Uri url) {
    requests.add(url);
    return routes[url.toString()] ??
        routes['${url.origin}${url.path}'] ??
        (status: 404, body: '');
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
  _StubResponse(this.statusCode, String body)
    : super(Stream.value(utf8.encode(body)));

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

String _pgnUrl(String gid) =>
    'https://www.chessgames.com/njs/api/game/viewPGN/$gid';

String _game({
  String event = 'World Championship',
  String white = 'Fischer, R',
  String black = 'Spassky, B',
  String date = '1972.07.11',
  String result = '1-0',
  String eol = '\n',
}) => [
  '[Event "$event"]',
  '[White "$white"]',
  '[Black "$black"]',
  '[Date "$date"]',
  '[Result "$result"]',
  '',
  '1. e4 e5 2. Nf3 Nc6 $result',
  '',
].join(eol);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final stub = _StubHttp();
  late Directory tempDir;
  late _FileStorage storage;

  setUpAll(() => HttpOverrides.global = stub);

  setUp(() async {
    HttpOverrides.global = stub;
    stub.requests.clear();
    stub.routes = {};
    tempDir = await Directory.systemTemp.createTemp('study_import_ctrl');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    storage = _FileStorage(tempDir.path);
    StorageFactory.instanceForTest = storage;
  });

  tearDown(() async {
    StorageFactory.instanceForTest = null;
    await tempDir.delete(recursive: true);
  });

  Future<File> cacheFile(String gid) async {
    final dir = await AppPaths.chessgamesCacheDirectory(create: true);
    return File(p.join(dir.path, '$gid.pgn'));
  }

  Future<void> seedCache(String gid, String pgn) async =>
      (await cacheFile(gid)).writeAsString(pgn);

  RepertoireJob newestJob() => JobManager.instance.jobs.first;

  Future<StudyImportResult> run(
    StudyImportController c,
    List<String> ids, {
    String name = 'Memorable',
  }) => c.startCollectionDownload(gameIds: ids, studyName: name);

  group('refusals', () {
    test('an empty id list is refused before anything starts', () async {
      final c = StudyImportController.fresh();
      await expectLater(run(c, const []), throwsA(isA<StudyImportException>()));
      expect(c.isRunning, isFalse);
      expect(c.lastResult, isNull);
    });

    test('a second run while one is going is refused', () async {
      await seedCache('1', _game());
      final c = StudyImportController.fresh();
      final first = run(c, const ['1']);
      expect(c.isRunning, isTrue);
      await expectLater(
        run(c, const ['1'], name: 'Other'),
        throwsA(isA<StudyImportException>()),
      );
      final result = await first;
      expect(result.chapters, 1, reason: 'the first run is unaffected');
      expect(c.isRunning, isFalse);
    });

    test('cancel with nothing running is a no-op', () {
      final c = StudyImportController.fresh();
      c.cancel();
      expect(c.message, '');
    });
  });

  group('a fetched game', () {
    test('is written as a renamed chapter and cached raw', () async {
      stub.routes[_pgnUrl('42')] = (status: 200, body: _game());
      final c = StudyImportController.fresh();

      final result = await run(c, const ['42']);

      expect(
        result.studyPath,
        p.join(tempDir.path, 'studies', 'Memorable.pgn'),
      );
      expect(result.chapters, 1);
      expect(result.failed, 0);
      expect(result.cancelled, isFalse);
      expect(result.error, isNull);
      expect(result.wroteAnything, isTrue);

      final written = await File(result.studyPath!).readAsString();
      final games = splitPgnIntoGames(written);
      expect(games, hasLength(1));
      expect(
        extractHeaders(games.single)['Event'],
        'Fischer, R - Spassky, B, World Championship 1972 (1-0)',
        reason: 'the tournament name is replaced by a per-game title',
      );
      expect(written, contains('1. e4 e5 2. Nf3 Nc6 1-0'));

      expect(
        await (await cacheFile('42')).readAsString(),
        _game().trim(),
        reason: 'the cache holds the server body, not the renamed chapter',
      );
      expect(stub.requests.map((u) => u.toString()), [_pgnUrl('42')]);

      expect(c.isRunning, isFalse);
      expect(c.message, '');
      expect(c.gamesDone, 1);
      expect(c.gamesTotal, 1);
      expect(c.resultGeneration, 1);
      expect(identical(c.lastResult, result), isTrue);
      expect(newestJob().status, JobStatus.completed);
      expect(newestJob().label, 'Import: Memorable');
    });

    test('keeps a single Event tag on a CRLF body', () async {
      stub.routes[_pgnUrl('7')] = (status: 200, body: _game(eol: '\r\n'));
      final result = await run(StudyImportController.fresh(), const ['7']);
      final written = await File(result.studyPath!).readAsString();
      expect(RegExp(r'^\[Event ', multiLine: true).allMatches(written), [
        anything,
      ]);
      expect(splitPgnIntoGames(written), hasLength(1));
      expect(
        extractHeaders(written)['Event'],
        'Fischer, R - Spassky, B, World Championship 1972 (1-0)',
      );
    });

    test('a 404 game is skipped, not fatal', () async {
      await seedCache('1', _game(white: 'A', black: 'B'));
      // gid 2 has no route → 404 → failed.
      final c = StudyImportController.fresh();
      final result = await run(c, const ['1', '2']);

      expect(result.chapters, 1);
      expect(result.failed, 1);
      expect(result.error, isNull);
      expect(result.cancelled, isFalse);
      expect(await (await cacheFile('2')).exists(), isFalse);
      expect(newestJob().status, JobStatus.completed);
      expect(c.gamesDone, 2, reason: 'skipped games still count as done');
    });

    test('a run where every game fails writes nothing', () async {
      final c = StudyImportController.fresh();
      final result = await run(c, const ['404']);
      expect(result.studyPath, isNull);
      expect(result.chapters, 0);
      expect(result.failed, 1);
      expect(result.wroteAnything, isFalse);
      expect(
        await Directory(p.join(tempDir.path, 'studies')).exists(),
        isFalse,
      );
    });
  });

  group('cache', () {
    test('cached games are served without a request, in id order', () async {
      await seedCache('3', _game(white: 'C', black: 'D', date: '2001'));
      await seedCache('1', _game(white: 'A', black: 'B', date: '1999'));
      await seedCache(
        '2',
        _game(white: '?', black: '?', event: '?', date: '?', result: '*'),
      );
      final c = StudyImportController.fresh();

      final result = await run(c, const ['3', '1', '2']);

      expect(stub.requests, isEmpty);
      expect(result.chapters, 3);
      final events = splitPgnIntoGames(
        await File(result.studyPath!).readAsString(),
      ).map((g) => extractHeaders(g)['Event']).toList();
      expect(events, [
        'C - D, World Championship 2001 (1-0)',
        'A - B, World Championship 1999 (1-0)',
        'Game 3',
      ]);
    });

    test('a blank cache file is a miss', () async {
      await seedCache('5', '  \n');
      stub.routes[_pgnUrl('5')] = (status: 200, body: _game());
      final result = await run(StudyImportController.fresh(), const ['5']);
      expect(stub.requests, hasLength(1));
      expect(result.chapters, 1);
      expect(await (await cacheFile('5')).readAsString(), _game().trim());
    });
  });

  group('study file', () {
    test('never overwrites an existing study of the same name', () async {
      final existing = File(p.join(tempDir.path, 'studies', 'Memorable.pgn'));
      await existing.create(recursive: true);
      await existing.writeAsString('precious');
      await seedCache('1', _game());

      final result = await run(StudyImportController.fresh(), const ['1']);

      expect(result.studyPath, endsWith('Memorable (2).pgn'));
      expect(await existing.readAsString(), 'precious');
    });

    test('a failed write is reported and fails the job', () async {
      await seedCache('1', _game());
      storage.failWrites = true;
      final c = StudyImportController.fresh();

      final result = await run(c, const ['1']);

      expect(result.studyPath, isNull);
      expect(result.chapters, 0);
      expect(result.wroteAnything, isFalse);
      expect(
        result.error,
        'Downloaded 1 games but could not save the study file.',
      );
      expect(newestJob().status, JobStatus.failed);
      expect(newestJob().error, result.error);
      expect(c.isRunning, isFalse);
    });
  });

  group('cancel', () {
    test(
      'during the gap before the next request keeps what was fetched',
      () async {
        stub.routes[_pgnUrl('1')] = (status: 200, body: _game());
        stub.routes[_pgnUrl('2')] = (status: 200, body: _game(white: 'X'));
        final c = StudyImportController.fresh();
        var cancelled = false;
        c.addListener(() {
          // Game 1 came back at once; game 2 is now waiting out the pace.
          if (!cancelled &&
              c.gamesDone == 1 &&
              c.message.startsWith('Game 2/2')) {
            cancelled = true;
            c.cancel();
          }
        });

        final result = await run(c, const [
          '1',
          '2',
        ]).timeout(const Duration(seconds: 10));

        expect(cancelled, isTrue);
        expect(result.cancelled, isTrue);
        expect(result.chapters, 1);
        expect(result.failed, 0, reason: 'an unfetched game is not a failure');
        expect(result.error, isNull);
        expect(stub.requests, hasLength(1));
        expect(await File(result.studyPath!).exists(), isTrue);
        expect(newestJob().status, JobStatus.cancelled);
        expect(c.isRunning, isFalse);
      },
    );

    test(
      'during a rate-limit backoff writes nothing and is not a failure',
      () async {
        stub.routes[_pgnUrl('9')] = (status: 429, body: '');
        final c = StudyImportController.fresh();
        var cancelled = false;
        c.addListener(() {
          if (!cancelled && c.message.startsWith('Rate-limited')) {
            cancelled = true;
            c.cancel();
          }
        });

        final result = await run(c, const [
          '9',
        ]).timeout(const Duration(seconds: 10));

        expect(cancelled, isTrue, reason: 'the backoff countdown was shown');
        expect(result.cancelled, isTrue);
        expect(result.chapters, 0);
        expect(result.studyPath, isNull);
        expect(result.error, isNull);
        expect(await (await cacheFile('9')).exists(), isFalse);
        expect(newestJob().status, JobStatus.cancelled);
        expect(stub.requests, hasLength(1), reason: 'no retry after cancel');
      },
    );

    test('a soft-ban HTML 200 is treated as a throttle', () async {
      stub.routes[_pgnUrl('9')] = (
        status: 200,
        body: '<html><body>Too many requests</body></html>',
      );
      final c = StudyImportController.fresh();
      var cancelled = false;
      c.addListener(() {
        if (!cancelled && c.message.startsWith('Rate-limited')) {
          cancelled = true;
          c.cancel();
        }
      });
      final result = await run(c, const [
        '9',
      ]).timeout(const Duration(seconds: 10));
      expect(cancelled, isTrue);
      expect(result.chapters, 0);
      expect(await (await cacheFile('9')).exists(), isFalse);
    });
  });

  group('runs in sequence', () {
    test('resultGeneration counts finished runs', () async {
      await seedCache('1', _game());
      final c = StudyImportController.fresh();
      await run(c, const ['1'], name: 'One');
      await run(c, const ['1'], name: 'Two');
      expect(c.resultGeneration, 2);
      expect(c.lastResult!.studyName, 'Two');
      expect(c.lastResult!.studyPath, endsWith('Two.pgn'));
    });
  });
}
