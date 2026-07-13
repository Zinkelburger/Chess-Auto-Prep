import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';

/// Fake client that records lookups and returns scripted responses without
/// touching the network.
class _FakeClient extends LichessApiClient {
  _FakeClient() : super.fresh();

  final List<String> requested = [];
  ExplorerResponse? Function(String fen) responder =
      (fen) => ExplorerResponse(fen: fen, moves: const [], totalGames: 1);
  bool backingOff = false;

  @override
  bool get isBackingOff => backingOff;

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

  test('debounces and coalesces to the latest requested FEN', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-A', _query);
    service.request('fen-B', _query); // supersedes A before it fires
    await _settle();

    expect(client.requested, ['fen-B']); // A never hit the network
    expect(service.state.value.status, ExplorerStatus.data);
    expect(service.state.value.fen, 'fen-B');
    service.dispose();
  });

  test('serves a cache hit without a second network call', () async {
    final client = _FakeClient();
    final service = LiveExplorerService(
      client: client,
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
      debounce: const Duration(milliseconds: 15),
    );

    service.request('fen-Y', _query);
    await _settle();
    expect(service.state.value.status, ExplorerStatus.error);
    service.dispose();
  });
}
