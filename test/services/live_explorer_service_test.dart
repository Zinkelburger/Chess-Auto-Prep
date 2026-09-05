import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';

/// Fake client that records lookups and returns scripted responses without
/// touching the network.
class _FakeClient extends LichessApiClient {
  _FakeClient() : super.fresh();

  final List<String> requested = [];
  ExplorerResponse? Function(String fen) responder = (fen) =>
      ExplorerResponse(fen: fen, moves: const [], totalGames: 1);
  bool backingOff = false;
  bool authRequired = false;

  @override
  bool get isBackingOff => backingOff;

  @override
  bool get explorerAuthRequired => authRequired;

  @override
  Future<ExplorerResponse?> fetchExplorer(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '2000,2200,2500',
    bool useMasters = false,
  }) async {
    requested.add(fen);
    return responder(fen);
  }
}

const _query = ExplorerQuery(database: LichessDatabase.lichess);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  setUp(LiveExplorerService.clearCacheForTest);

  test('a lone request fetches on the leading edge, without waiting', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(seconds: 5),
    );

    service.request('fen-A', _query);
    await Future<void>.delayed(Duration.zero);

    expect(client.requested, [
      'fen-A',
    ], reason: 'one click after a pause must not pay the debounce');
    service.dispose();
  });

  test('a burst coalesces onto the last requested FEN', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-A', _query); // leading edge — fires at once
    service.request('fen-B', _query); // inside the window — waits
    service.request('fen-C', _query); // supersedes B before it fires
    await _settle();

    expect(client.requested, ['fen-A', 'fen-C']); // B never hit the network
    expect(service.state.value.status, ExplorerStatus.data);
    expect(service.state.value.fen, 'fen-C');
    service.dispose();
  });

  test('keeps the previous response on screen while the next loads', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-A', _query);
    await _settle();
    expect(service.state.value.data?.fen, 'fen-A');

    service.request('fen-B', _query);
    final loading = service.state.value;
    expect(loading.status, ExplorerStatus.loading);
    expect(loading.fen, 'fen-B');
    expect(
      loading.data?.fen,
      'fen-A',
      reason: 'the old table stays up instead of blanking to a spinner',
    );
    expect(loading.isStale, isTrue);

    await _settle();
    expect(service.state.value.isStale, isFalse);
    expect(service.state.value.data?.fen, 'fen-B');
    service.dispose();
  });

  test('ignores the move counters when caching a position', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );

    const early = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    const later = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 4 9';

    service.request(early, _query);
    await _settle();
    expect(client.requested.length, 1);

    service.request(later, _query); // same position, later move numbers
    expect(service.state.value.status, ExplorerStatus.data);
    await _settle();
    expect(client.requested.length, 1, reason: 'transposition is a cache hit');
    service.dispose();
  });

  test('serves a cache hit without a second network call', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-A', _query);
    await _settle();
    expect(client.requested.length, 1);

    service.request('fen-A', _query); // cached
    expect(service.state.value.status, ExplorerStatus.data); // synchronous
    await _settle();
    expect(client.requested.length, 1, reason: 'no second fetch for cache hit');
    service.dispose();
  });

  test('reports rateLimited when the client is backing off', () async {
    final client = _FakeClient();
    client.responder = (_) => null;
    client.backingOff = true;
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-X', _query);
    await _settle();
    expect(service.state.value.status, ExplorerStatus.rateLimited);
    service.dispose();
  });

  test('reports error on a null response without backoff', () async {
    final client = _FakeClient();
    client.responder = (_) => null;
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-Y', _query);
    await _settle();
    expect(service.state.value.status, ExplorerStatus.error);
    service.dispose();
  });

  test('asks for a login instead of fetching when logged out', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => false,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-Z', _query);
    expect(
      service.state.value.status,
      ExplorerStatus.authRequired,
      reason: 'synchronous — no round trip needed to learn we are anonymous',
    );
    await _settle();
    expect(client.requested, isEmpty);
    service.dispose();
  });

  test('serves the cache even when logged out', () async {
    final client = _FakeClient();
    final warm = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );
    warm.request('fen-C', _query);
    await _settle();
    warm.dispose();

    final anonymous = LiveExplorerService(
      client: client,
      isLoggedIn: () => false,
      debounce: const Duration(milliseconds: 15),
    );
    anonymous.request('fen-C', _query);
    expect(anonymous.state.value.status, ExplorerStatus.data);
    anonymous.dispose();
  });

  test(
    'reports authRequired when Lichess rejects the call as anonymous',
    () async {
      // Logged in with a stale/invalid token: the 401 only shows up in the
      // response, so the client's flag is what distinguishes it from an outage.
      final client = _FakeClient();
      client.responder = (_) => null;
      client.authRequired = true;
      final service = LiveExplorerService(
        client: client,
        isLoggedIn: () => true,
        debounce: const Duration(milliseconds: 15),
      );

      service.request('fen-W', _query);
      await _settle();
      expect(service.state.value.status, ExplorerStatus.authRequired);
      service.dispose();
    },
  );

  test('authRequired outranks a concurrent backoff window', () async {
    final client = _FakeClient();
    client.responder = (_) => null;
    client.authRequired = true;
    client.backingOff = true;
    final service = LiveExplorerService(
      client: client,
      isLoggedIn: () => true,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-V', _query);
    await _settle();
    expect(service.state.value.status, ExplorerStatus.authRequired);
    service.dispose();
  });

  group('the local TWIC database', () {
    const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    late Directory tmp;
    late MasterGamesDb db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('live_explorer_twic');
      final path = '${tmp.path}/master_games.db';
      importPgnIntoMasterGames(
        MasterGamesImportRequest(
          dbPath: path,
          pgnText: '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.21"]
[White "Carlsen,Magnus"]
[Black "Nakamura,Hikaru"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2790"]

1. e4 c5 2. Nf3 1-0

[Event "Titled Tue"]
[Site "chess.com INT"]
[Date "2026.02.03"]
[White "Blitzer,A"]
[Black "Blitzer,B"]
[Result "0-1"]
[WhiteElo "2900"]
[BlackElo "2850"]

1. d4 d5 0-1
''',
          twicIssue: 1660,
        ),
      );
      db = MasterGamesDb.open(path, readOnly: true);
    });

    tearDown(() async {
      db.close();
      await tmp.delete(recursive: true);
    });

    test('answers at once, from disk, without a login', () {
      final client = _FakeClient();
      final service = LiveExplorerService(
        client: client,
        isLoggedIn: () => false,
        localDb: () => db,
      );
      service.request(
        start,
        const ExplorerQuery(database: LichessDatabase.twic),
      );

      final state = service.state.value;
      expect(state.status, ExplorerStatus.data);
      expect(client.requested, isEmpty);
      final data = state.data!;
      expect(data.totalGames, 2);
      // Most played first, then strongest: one game each, the blitz d4 is
      // the higher rated.
      expect(data.moves.map((m) => m.san), ['d4', 'e4']);
      expect(data.whiteTotal, 1);
      expect(data.blackTotal, 1);
      // Strongest first: the blitz game is higher rated.
      expect(data.topGames.map((g) => g.white), [
        'Blitzer,A',
        'Carlsen,Magnus',
      ]);
      expect(data.topGames.first.source, ExplorerGameSource.twic);
      expect(data.topGames.first.san, 'd4');
      expect(data.topGames.last.event, 'Tata Steel');
      expect(data.topGames.last.when, '2026-01');
      service.dispose();
    });

    test('classical only drops the online games and their moves', () {
      final service = LiveExplorerService(
        client: _FakeClient(),
        isLoggedIn: () => false,
        localDb: () => db,
      );
      service.request(
        start,
        const ExplorerQuery(
          database: LichessDatabase.twic,
          classicalOnly: true,
        ),
      );
      final data = service.state.value.data!;
      expect(data.totalGames, 1);
      expect(data.moves.map((m) => m.san), ['e4']);
      expect(data.topGames.map((g) => g.white), ['Carlsen,Magnus']);
      service.dispose();
    });

    test('with no database it is an empty position, not an error', () {
      final service = LiveExplorerService(
        client: _FakeClient(),
        isLoggedIn: () => false,
        localDb: () => null,
      );
      service.request(
        start,
        const ExplorerQuery(database: LichessDatabase.twic),
      );
      expect(service.state.value.status, ExplorerStatus.data);
      expect(service.state.value.data!.moves, isEmpty);
      service.dispose();
    });
  });
}
