/// What the tactics import asks the two game APIs for, and what it does with
/// the answer: the Lichess query it builds for each window mode, how it walks
/// Chess.com's monthly archives backwards, where it stops, and how it fails.
///
/// `flutter test` answers every socket with an empty 400, so a test that
/// "downloads" silently gets nothing. Every request here goes through an
/// explicit [HttpOverrides] stub that records the URL and replies with
/// scripted bodies; nothing leaves the process.
///
/// As in tactics_import_pipeline_test.dart the engine is never started: runs
/// pass `maxCores: 0`, so a game that actually reaches the analysis stage
/// throws "requires Stockfish". Games the fetch is expected to *keep* are
/// pre-marked analyzed instead, which makes `gamesSkipped` an exact count of
/// how many games the fetch decided to hand on.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/tactics/services/tactics_database.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_service.dart';
import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/generation/engine_fakes.dart' show FakeMaiaEvaluator;

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

// ── HTTP stub ──────────────────────────────────────────────────────────────

/// One scripted reply.
typedef _Reply = ({int status, String body});

_Reply _ok(String body) => (status: 200, body: body);

/// Answers every request from [routes] (exact URL match after the origin) and
/// records what was asked for. A URL with no route replies 404, so a test can
/// never pass on a request it did not intend.
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

String lichessGame(String id, {String date = '2025.06.01'}) =>
    '''
[Event "Rated blitz game"]
[Site "https://lichess.org/$id"]
[UTCDate "$date"]
[UTCTime "12:00:00"]
[White "userA"]
[Black "userB"]
[Result "1-0"]
[TimeControl "180+2"]

1. e4 e5 2. Nf3 Nc6 1-0''';

String chesscomGame(String id, {String date = '2025.06.02'}) =>
    '''
[Event "Live Chess"]
[Link "https://www.chess.com/game/live/$id"]
[Date "$date"]
[UTCTime "09:00:00"]
[White "userA"]
[Black "userB"]
[Result "0-1"]
[TimeControl "600"]

1. d4 d5 0-1''';

String archivesJson(List<String> urls) => json.encode({'archives': urls});

const _chesscomBase = 'https://api.chess.com/pub/player/usera/games';
const _archivesUrl = '$_chesscomBase/archives';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final stub = _StubHttp();
  late Directory tempDir;

  setUpAll(() {
    // Installed once: LichessApiClient is a singleton that builds its
    // http.Client (and therefore its HttpClient) the first time it is
    // touched, so the override has to be in place before any test runs.
    HttpOverrides.global = stub;
  });

  setUp(() async {
    HttpOverrides.global = stub;
    stub.requests.clear();
    stub.routes = {};
    tempDir = await Directory.systemTemp.createTemp('tactics_import_fetch');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    GameStoreService.setTestInstance(GameStoreService());
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
  });

  tearDown(() async {
    MaiaFactory.testOverride = null;
    GameStoreService.instance.close();
    await tempDir.delete(recursive: true);
  });

  Future<TacticsImportService> serviceWithAnalyzed(
    List<String> analyzed,
  ) async {
    await StorageFactory.instance.saveAnalyzedGameIds(analyzed);
    final db = TacticsDatabase();
    await db.loadPositions();
    return TacticsImportService(database: db);
  }

  Uri lichessRequest() =>
      stub.requests.firstWhere((u) => u.host == 'lichess.org');

  // ────────────────────────────────────────────────────────────────────────
  group('the Lichess request', () {
    test('a countless window asks for the default 20 latest games', () async {
      stub.routes = {
        'https://lichess.org/api/games/user/userA': _ok(
          lichessGame('aaaaaaaa'),
        ),
      };
      final service = await serviceWithAnalyzed(['lichess_aaaaaaaa']);

      await service.importGamesFromLichess('userA', depth: 8, maxCores: 0);

      expect(lichessRequest().queryParameters['max'], '20');
      expect(lichessRequest().queryParameters['since'], isNull);
    });

    test('an explicit count is sent as max', () async {
      stub.routes = {
        'https://lichess.org/api/games/user/userA': _ok(
          lichessGame('aaaaaaaa'),
        ),
      };
      final service = await serviceWithAnalyzed(['lichess_aaaaaaaa']);

      await service.importGamesFromLichess(
        'userA',
        maxGames: 7,
        depth: 8,
        maxCores: 0,
      );

      expect(lichessRequest().queryParameters['max'], '7');
    });

    test('a date window is sent without a game cap', () async {
      // The since window is the limit the user asked for; capping it as well
      // would silently drop games inside the window they chose.
      stub.routes = {
        'https://lichess.org/api/games/user/userA': _ok(
          lichessGame('aaaaaaaa'),
        ),
      };
      final service = await serviceWithAnalyzed(['lichess_aaaaaaaa']);
      final since = DateTime.utc(2025, 5, 1);

      await service.importGamesFromLichess(
        'userA',
        since: since,
        depth: 8,
        maxCores: 0,
      );

      expect(
        lichessRequest().queryParameters['since'],
        '${since.millisecondsSinceEpoch}',
      );
      expect(lichessRequest().queryParameters['max'], isNull);
    });

    test('a date window with an explicit count sends both', () async {
      stub.routes = {
        'https://lichess.org/api/games/user/userA': _ok(
          lichessGame('aaaaaaaa'),
        ),
      };
      final service = await serviceWithAnalyzed(['lichess_aaaaaaaa']);

      await service.importGamesFromLichess(
        'userA',
        since: DateTime.utc(2025, 5, 1),
        maxGames: 5,
        depth: 8,
        maxCores: 0,
      );

      expect(lichessRequest().queryParameters['max'], '5');
      expect(lichessRequest().queryParameters['since'], isNotNull);
    });

    test('clocks are requested and evals are not', () async {
      // Clock comments feed the tempo flaw tags; Lichess evals are not used
      // (this pass computes its own at our depth).
      stub.routes = {
        'https://lichess.org/api/games/user/userA': _ok(
          lichessGame('aaaaaaaa'),
        ),
      };
      final service = await serviceWithAnalyzed(['lichess_aaaaaaaa']);

      await service.importGamesFromLichess('userA', depth: 8, maxCores: 0);

      expect(lichessRequest().queryParameters['clocks'], 'true');
      expect(lichessRequest().queryParameters['evals'], 'false');
      expect(lichessRequest().queryParameters['moves'], 'true');
    });

    test('the username is a single path segment, never a path', () async {
      stub.routes = {};
      final service = await serviceWithAnalyzed(const []);

      await expectLater(
        service.importGamesFromLichess('a/../admin', depth: 8, maxCores: 0),
        throwsA(isA<Exception>()),
      );
      expect(lichessRequest().pathSegments, [
        'api',
        'games',
        'user',
        'a/../admin',
      ]);
    });

    test('a non-200 fails loudly with the status code', () async {
      stub.routes = {
        'https://lichess.org/api/games/user/userA': (status: 503, body: ''),
      };
      final service = await serviceWithAnalyzed(const []);

      await expectLater(
        service.importGamesFromLichess('userA', depth: 8, maxCores: 0),
        throwsA(
          isA<Exception>().having((e) => '$e', 'message', contains('503')),
        ),
      );
    });

    test(
      'downloaded games reach the archive before they are analyzed',
      () async {
        // The stored copy is what the resume queue and the tactic's "show the
        // whole game" tab read, so it has to be written even for a run whose
        // games all turn out to be already analyzed.
        stub.routes = {
          'https://lichess.org/api/games/user/userA': _ok(
            [lichessGame('aaaaaaaa'), lichessGame('bbbbbbbb')].join('\n\n'),
          ),
        };
        final service = await serviceWithAnalyzed([
          'lichess_aaaaaaaa',
          'lichess_bbbbbbbb',
        ]);

        final result = await service.importGamesFromLichess(
          'userA',
          depth: 8,
          maxCores: 0,
        );

        expect(result.gamesSkipped, 2);
        final store = await GameStoreService.instance.open();
        expect(store.count(GameCollections.tactics), 2);
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────────
  group('the Chess.com archive walk', () {
    test(
      'a player with no archives fails rather than reporting zero games',
      () async {
        stub.routes = {_archivesUrl: _ok(archivesJson([]))};
        final service = await serviceWithAnalyzed(const []);

        await expectLater(
          service.importGamesFromChessCom('userA', depth: 8, maxCores: 0),
          throwsA(
            isA<Exception>().having(
              (e) => '$e',
              'message',
              contains('No game archives'),
            ),
          ),
        );
      },
    );

    test('an unreachable archives endpoint is the same failure', () async {
      stub.routes = {_archivesUrl: (status: 500, body: '')};
      final service = await serviceWithAnalyzed(const []);

      await expectLater(
        service.importGamesFromChessCom('userA', depth: 8, maxCores: 0),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('No game archives'),
          ),
        ),
      );
    });

    test(
      'archives with no games at all fail rather than return empty',
      () async {
        stub.routes = {
          _archivesUrl: _ok(archivesJson(['$_chesscomBase/2025/06'])),
          '$_chesscomBase/2025/06/pgn': _ok(''),
        };
        final service = await serviceWithAnalyzed(const []);

        await expectLater(
          service.importGamesFromChessCom('userA', depth: 8, maxCores: 0),
          throwsA(
            isA<Exception>().having(
              (e) => '$e',
              'message',
              contains('No games found'),
            ),
          ),
        );
      },
    );

    test(
      'it walks months backwards and stops once the count is reached',
      () async {
        // Two games per month, three months, asking for three games: the walk
        // must stop after the second month — the oldest archive is never even
        // requested — and hand exactly three games on.
        stub.routes = {
          _archivesUrl: _ok(
            archivesJson([
              '$_chesscomBase/2025/04',
              '$_chesscomBase/2025/05',
              '$_chesscomBase/2025/06',
            ]),
          ),
          '$_chesscomBase/2025/06/pgn': _ok(
            [chesscomGame('61'), chesscomGame('62')].join('\n\n'),
          ),
          '$_chesscomBase/2025/05/pgn': _ok(
            [chesscomGame('51'), chesscomGame('52')].join('\n\n'),
          ),
          '$_chesscomBase/2025/04/pgn': _ok(
            [chesscomGame('41'), chesscomGame('42')].join('\n\n'),
          ),
        };
        final service = await serviceWithAnalyzed([
          'chesscom_61',
          'chesscom_62',
          'chesscom_51',
          'chesscom_52',
        ]);

        final result = await service.importGamesFromChessCom(
          'userA',
          maxGames: 3,
          depth: 8,
          maxCores: 0,
        );

        expect(result.gamesSkipped, 3, reason: 'the cap is applied to games');
        expect(stub.requests.map((u) => u.path).toList(), [
          '/pub/player/usera/games/archives',
          '/pub/player/usera/games/2025/06/pgn',
          '/pub/player/usera/games/2025/05/pgn',
        ], reason: 'the 2025/04 archive is never fetched');
      },
    );

    test('a countless window defaults to the latest ten games', () async {
      stub.routes = {
        _archivesUrl: _ok(archivesJson(['$_chesscomBase/2025/06'])),
        '$_chesscomBase/2025/06/pgn': _ok(
          [for (var i = 1; i <= 12; i++) chesscomGame('$i')].join('\n\n'),
        ),
      };
      final service = await serviceWithAnalyzed([
        for (var i = 1; i <= 12; i++) 'chesscom_$i',
      ]);

      final result = await service.importGamesFromChessCom(
        'userA',
        depth: 8,
        maxCores: 0,
      );

      expect(result.gamesSkipped, 10);
    });

    test('a date window skips archive months before it', () async {
      stub.routes = {
        _archivesUrl: _ok(
          archivesJson([
            '$_chesscomBase/2024/12',
            '$_chesscomBase/2025/04',
            '$_chesscomBase/2025/05',
            '$_chesscomBase/2025/06',
          ]),
        ),
        '$_chesscomBase/2025/06/pgn': _ok(
          chesscomGame('61', date: '2025.06.02'),
        ),
        '$_chesscomBase/2025/05/pgn': _ok(
          chesscomGame('51', date: '2025.05.02'),
        ),
      };
      final service = await serviceWithAnalyzed(['chesscom_61', 'chesscom_51']);

      final result = await service.importGamesFromChessCom(
        'userA',
        since: DateTime(2025, 5, 1),
        depth: 8,
        maxCores: 0,
      );

      expect(result.gamesSkipped, 2);
      expect(stub.requests.map((u) => u.path).toList(), [
        '/pub/player/usera/games/archives',
        '/pub/player/usera/games/2025/06/pgn',
        '/pub/player/usera/games/2025/05/pgn',
      ], reason: '2025/04 and 2024/12 are outside the window');
    });

    test(
      'a date window drops games older than it inside the boundary month',
      () async {
        // The month survives the archive filter, but individual games in it
        // still have to be checked against the day.
        stub.routes = {
          _archivesUrl: _ok(archivesJson(['$_chesscomBase/2025/05'])),
          '$_chesscomBase/2025/05/pgn': _ok(
            [
              chesscomGame('kept', date: '2025.05.20'),
              chesscomGame('edge', date: '2025.05.15'),
              chesscomGame('old', date: '2025.05.14'),
            ].join('\n\n'),
          ),
        };
        final service = await serviceWithAnalyzed([
          'chesscom_kept',
          'chesscom_edge',
          'chesscom_old',
        ]);

        final result = await service.importGamesFromChessCom(
          'userA',
          since: DateTime(2025, 5, 15),
          depth: 8,
          maxCores: 0,
        );

        // The game played *on* the cutoff day is inside the window; the one the
        // day before is not.
        expect(result.gamesSkipped, 2);
      },
    );

    test('a date window has no game cap of its own', () async {
      stub.routes = {
        _archivesUrl: _ok(archivesJson(['$_chesscomBase/2025/05'])),
        '$_chesscomBase/2025/05/pgn': _ok(
          [for (var i = 1; i <= 12; i++) chesscomGame('$i', date: '2025.05.20')]
              .join('\n\n'),
        ),
      };
      final service = await serviceWithAnalyzed([
        for (var i = 1; i <= 12; i++) 'chesscom_$i',
      ]);

      final result = await service.importGamesFromChessCom(
        'userA',
        since: DateTime(2025, 5, 1),
        depth: 8,
        maxCores: 0,
      );

      expect(result.gamesSkipped, 12, reason: 'no ten-game default applies');
    });

    test('one unreadable month does not abort the walk', () async {
      stub.routes = {
        _archivesUrl: _ok(
          archivesJson(['$_chesscomBase/2025/05', '$_chesscomBase/2025/06']),
        ),
        '$_chesscomBase/2025/06/pgn': (status: 500, body: ''),
        '$_chesscomBase/2025/05/pgn': _ok(chesscomGame('51')),
      };
      final service = await serviceWithAnalyzed(['chesscom_51']);

      final result = await service.importGamesFromChessCom(
        'userA',
        maxGames: 5,
        depth: 8,
        maxCores: 0,
      );

      expect(result.gamesSkipped, 1);
    });
  });
}
