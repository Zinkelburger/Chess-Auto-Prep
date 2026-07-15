import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/build_by_playing/build_by_playing_config.dart';
import 'package:chess_auto_prep/services/build_by_playing/build_by_playing_controller.dart';
import 'package:chess_auto_prep/services/explorer_cache_service.dart';
import 'package:chess_auto_prep/services/lichess_api_client.dart';

/// Serves canned Explorer responses keyed by the board field of the FEN;
/// unknown positions get an empty response (0 games → line cutoff).
class _FakeLichessClient extends LichessApiClient {
  _FakeLichessClient(this.responsesByBoard) : super.fresh();

  final Map<String, ExplorerResponse> responsesByBoard;

  @override
  Future<ExplorerResponse?> fetchExplorer(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '2000,2200,2500',
    bool useMasters = false,
  }) async {
    return responsesByBoard[fen.split(' ').first] ??
        ExplorerResponse.fromJson(const {'moves': []}, fen: fen);
  }
}

/// Build an ExplorerResponse where each entry is (san, games); play rates
/// derive from the game counts.
ExplorerResponse _response(List<(String, int)> entries) {
  return ExplorerResponse.fromJson({
    'moves': [
      for (final (san, games) in entries)
        {
          'san': san,
          'uci': san.toLowerCase(),
          'white': games,
          'draws': 0,
          'black': 0,
        },
    ],
  }, fen: 'test-fen');
}

void main() {
  group('selectOpponentReplies', () {
    test('takes most popular replies until the mass target is covered', () {
      // 50% / 30% / 15% / 5%: mass target 0.75 is crossed by the second
      // reply, so the third is only included if forced by coverMinProb.
      final resp = _response([('e4', 50), ('d4', 30), ('c4', 15), ('b3', 5)]);
      final selected = BuildByPlayingController.selectOpponentReplies(
        resp.moves,
        coverMinProb: 1.0, // nothing forced
        oppMassTarget: 0.75,
        oppMaxChildren: 10,
      );
      expect(selected.map((m) => m.san), ['e4', 'd4']);
    });

    test('coverMinProb forces popular replies past the caps', () {
      final resp = _response([('e4', 50), ('d4', 30), ('c4', 15), ('b3', 5)]);
      final selected = BuildByPlayingController.selectOpponentReplies(
        resp.moves,
        coverMinProb: 0.10, // c4 at 15% is forced, b3 at 5% is not
        oppMassTarget: 0.50,
        oppMaxChildren: 1,
      );
      expect(selected.map((m) => m.san), ['e4', 'd4', 'c4']);
    });

    test('oppMaxChildren caps unforced replies', () {
      final resp = _response(
          [('a3', 25), ('b3', 25), ('c3', 25), ('d3', 25)]);
      final selected = BuildByPlayingController.selectOpponentReplies(
        resp.moves,
        coverMinProb: 0.90,
        oppMassTarget: 1.0,
        oppMaxChildren: 2,
      );
      expect(selected.length, 2);
    });

    test('skips zero-game and empty-SAN entries', () {
      final resp = ExplorerResponse.fromJson({
        'moves': [
          {'san': 'e4', 'uci': 'e2e4', 'white': 10, 'draws': 0, 'black': 0},
          {'san': '', 'uci': '', 'white': 5, 'draws': 0, 'black': 0},
        ],
      }, fen: 'test-fen');
      final selected = BuildByPlayingController.selectOpponentReplies(
        resp.moves,
        coverMinProb: 0.05,
        oppMassTarget: 1.0,
        oppMaxChildren: 10,
      );
      expect(selected.map((m) => m.san), ['e4']);
    });

    test('empty input yields empty selection', () {
      final selected = BuildByPlayingController.selectOpponentReplies(
        const [],
        coverMinProb: 0.05,
        oppMassTarget: 0.8,
        oppMaxChildren: 4,
      );
      expect(selected, isEmpty);
    });
  });

  group('ExplorerSourceConfig', () {
    test('cache key separates masters from lichess filters', () {
      const masters = ExplorerSourceConfig(useMasters: true);
      const lichess = ExplorerSourceConfig(
          speeds: 'blitz', ratings: '2000');
      expect(masters.cacheKeyPrefix, 'masters');
      expect(lichess.cacheKeyPrefix, 'lichess|blitz|2000');
      expect(masters.cacheKeyPrefix == lichess.cacheKeyPrefix, isFalse);
    });

    test('equality follows field values', () {
      const a = ExplorerSourceConfig(speeds: 'blitz', ratings: '2000');
      const b = ExplorerSourceConfig(speeds: 'blitz', ratings: '2000');
      const c = ExplorerSourceConfig(speeds: 'rapid', ratings: '2000');
      expect(a, b);
      expect(a == c, isFalse);
    });
  });

  group('BuildByPlayingConfig', () {
    test('source reflects the database selection', () {
      const config = BuildByPlayingConfig(
          useMasters: true, speeds: 'blitz', ratings: '1600');
      expect(config.source.useMasters, isTrue);
      const lichess = BuildByPlayingConfig(speeds: 'blitz', ratings: '1600');
      expect(lichess.source.cacheKeyPrefix, 'lichess|blitz|1600');
    });

    test('copyWith preserves unset fields', () {
      const config = BuildByPlayingConfig(maxPly: 30, minGames: 25);
      final copy = config.copyWith(oppMaxChildren: 6);
      expect(copy.maxPly, 30);
      expect(copy.minGames, 25);
      expect(copy.oppMaxChildren, 6);
      expect(copy.coverMinProb, config.coverMinProb);
    });
  });

  group('BuildByPlayingController session flow', () {
    const startBoard = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';
    const afterE4Board = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR';
    const afterE4E5Board = 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR';

    late Directory tempDir;
    late RepertoireController repertoire;
    late BuildByPlayingController session;

    /// Black repertoire with no lines: the opponent (White) moves first.
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('build_by_playing_test');
      final filePath = '${tempDir.path}/test.pgn';
      await File(filePath).writeAsString('// Color: Black\n');
      repertoire = RepertoireController();
      await repertoire.setRepertoire(RepertoireMetadata(
        name: 'Test',
        filePath: filePath,
        lastModified: DateTime(2026, 1, 1),
      ));
      final explorer = ExplorerCacheService.forTesting(_FakeLichessClient({
        startBoard: _response([('e4', 900), ('d4', 100)]),
        afterE4Board: _response([('e5', 60), ('c5', 40)]),
        afterE4E5Board: _response([('Nf3', 100)]),
      }));
      session = BuildByPlayingController(
        repertoire: repertoire,
        explorer: explorer,
      );
    });

    tearDown(() async {
      session.dispose();
      repertoire.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('opponent plays the first move for a black repertoire', () async {
      await session.start(const BuildByPlayingConfig());

      expect(session.phase, BuildByPlayingPhase.awaitingUserMove);
      expect(session.lastOpponentSan, 'e4');
      expect(repertoire.currentMoveSequence, ['e4']);
      expect(session.boardFen, startsWith(afterE4Board));
      // d4 (10%) is above the 5% coverMinProb default → queued as a branch.
      expect(session.pendingBranchCount, 1);
    });

    test('commit writes the move and the opponent replies again', () async {
      await session.start(const BuildByPlayingConfig());
      await session.commitMove('e5');

      expect(session.commitCount, 1);
      expect(session.phase, BuildByPlayingPhase.awaitingUserMove);
      expect(session.lastOpponentSan, 'Nf3');
      expect(repertoire.currentMoveSequence, ['e4', 'e5', 'Nf3']);
      final saved = await File('${tempDir.path}/test.pgn').readAsString();
      expect(saved, contains('e5'));
    });
  });
}
