/// The live explorer stops asking where the database stops answering, and
/// shares its store with every other explorer consumer.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/services/explorer_cache_service.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';

class _FakeClient extends LichessApiClient {
  _FakeClient() : super.fresh();

  final List<String> requested = [];
  ExplorerResponse? Function(String fen) responder = (fen) =>
      ExplorerResponse(fen: fen, moves: const [], totalGames: 0);

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

/// A FEN at [fullmove] with White to move.  The board differs per move —
/// the cache is keyed by position, so two FENs that differ only in their
/// counters would be one lookup.
String _fenAtMove(int fullmove) => '$fullmove/8/8/8/8/8/8/8 w - - 0 $fullmove';

/// A move path [plies] long that is unique to line [tag] from its first move,
/// so two tags never share a prefix.
List<String> _line(String tag, int plies) => [
  for (var i = 0; i < plies; i++) '$tag$i',
];

ExplorerMove _move(String san) => ExplorerMove(
  san: san,
  uci: 'a1a2',
  white: 1,
  draws: 0,
  black: 0,
  playRate: 1,
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  late ExplorerCacheService store;
  late _FakeClient client;

  setUp(() {
    client = _FakeClient();
    store = ExplorerCacheService.forTesting(client);
  });

  LiveExplorerService service({int emptyStreakLimit = 3}) =>
      LiveExplorerService(
        client: client,
        cache: store,
        isLoggedIn: () => true,
        debounce: const Duration(milliseconds: 5),
        emptyStreakLimit: emptyStreakLimit,
      );

  test('past maxPly nothing is asked and the panel reads empty', () async {
    final s = service();
    s.request(_fenAtMove(40), _query); // ply 78
    await _settle();
    expect(client.requested, isEmpty);
    expect(s.state.value.status, ExplorerStatus.data);
    expect(s.state.value.data!.moves, isEmpty);
    s.dispose();
  });

  test('after a run of empty answers deeper positions are not asked', () async {
    final s = service();
    for (final move in [10, 11, 12]) {
      s.request(_fenAtMove(move), _query);
      await _settle();
    }
    expect(client.requested.length, 3);

    s.request(_fenAtMove(13), _query);
    await _settle();
    expect(client.requested.length, 3, reason: 'deeper: answered empty');
    expect(s.state.value.data!.moves, isEmpty);

    // Back up the line the database is asked again, and a hit resets the run.
    client.responder = (fen) =>
        ExplorerResponse(fen: fen, moves: [_move('e4')], totalGames: 1);
    s.request(_fenAtMove(5), _query);
    await _settle();
    expect(client.requested.length, 4);
    s.request(_fenAtMove(14), _query);
    await _settle();
    expect(client.requested.length, 5, reason: 'the empty run was reset');
    s.dispose();
  });

  test('an empty run only silences the line it was seen on', () async {
    final s = service();
    // Three dead answers down one obscure line.
    for (final move in [10, 11, 12]) {
      s.request(_fenAtMove(move), _query, movePath: _line('a', move));
      await _settle();
    }
    expect(client.requested.length, 3);

    // Deeper on that same line: not asked, as before.
    s.request(_fenAtMove(13), _query, movePath: _line('a', 13));
    await _settle();
    expect(client.requested.length, 3, reason: 'same line, deeper');

    // A different line at a deeper ply is a different question, and the run
    // down the first line says nothing about it.
    s.request(_fenAtMove(14), _query, movePath: _line('b', 14));
    await _settle();
    expect(
      client.requested.length,
      4,
      reason: 'another line must still be asked',
    );
    s.dispose();
  });

  test('the run resets once a different line answers', () async {
    final s = service();
    for (final move in [10, 11, 12]) {
      s.request(_fenAtMove(move), _query, movePath: _line('a', move));
      await _settle();
    }
    client.responder = (fen) =>
        ExplorerResponse(fen: fen, moves: [_move('e4')], totalGames: 1);
    s.request(_fenAtMove(20), _query, movePath: _line('b', 20));
    await _settle();
    expect(client.requested.length, 4);

    // Back on the first line, deeper than the run: the run is gone, so ask.
    client.responder = (fen) =>
        ExplorerResponse(fen: fen, moves: const [], totalGames: 0);
    s.request(_fenAtMove(13), _query, movePath: _line('a', 13));
    await _settle();
    expect(client.requested.length, 5);
    s.dispose();
  });

  test('a position another consumer fetched is a hit here', () async {
    final response = ExplorerResponse(
      fen: _fenAtMove(3),
      moves: [_move('Nf3')],
      totalGames: 9,
    );
    store.put(_fenAtMove(3), _query.source, response);

    final s = service();
    s.request(_fenAtMove(3), _query);
    expect(s.state.value.status, ExplorerStatus.data);
    expect(identical(s.state.value.data, response), isTrue);
    expect(client.requested, isEmpty);
    s.dispose();
  });

  test('what the panel fetches lands in the shared store', () async {
    client.responder = (fen) =>
        ExplorerResponse(fen: fen, moves: [_move('d4')], totalGames: 2);
    final s = service();
    s.request(_fenAtMove(2), _query);
    await _settle();
    expect(store.peek(_fenAtMove(2), _query.source)?.moves.single.san, 'd4');
    s.dispose();
  });
}
