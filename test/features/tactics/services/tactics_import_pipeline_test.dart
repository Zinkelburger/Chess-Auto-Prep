/// What the tactics-import pipeline *decides* before (and instead of) running
/// the engine: which games are handed to Stockfish, which are skipped as
/// already reviewed, how a game's identity is recovered from its headers, what
/// survives pruning, and how the resume queue routes stored games back to the
/// right account.
///
/// The engine itself is never started. Every run here is made with
/// `maxCores: 0`, which leaves [StockfishPool.ensureWorkers] with a target of
/// zero workers, so `_processGames` throws its "requires Stockfish" error the
/// moment a game actually reaches the analysis stage. That exception is the
/// oracle: a game that reaches the engine throws, a game that is filtered out
/// returns cleanly. Both outcomes are asserted, so dropping a guard flips a
/// passing test into a failing one in either direction.
@TestOn('vm')
library;

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

/// The pipeline reached the engine stage.
final Matcher _reachesTheEngine = throwsA(
  isA<Exception>().having(
    (e) => '$e',
    'message',
    contains('requires Stockfish'),
  ),
);

// ── Fixtures ───────────────────────────────────────────────────────────────

/// A Lichess export: the game URL in [Site], plus Lichess's own *bare*
/// [GameId] (no platform prefix) when [bareGameId] is set.
String lichessGame(
  String id, {
  String date = '2025.06.01',
  String time = '12:00:00',
  bool site = true,
  bool bareGameId = false,
  String white = 'userA',
  String moves = '1. e4 e5 2. Nf3 Nc6 1-0',
}) =>
    '''
[Event "Rated blitz game"]
${site ? '[Site "https://lichess.org/$id"]\n' : ''}[UTCDate "$date"]
[UTCTime "$time"]
[White "$white"]
[Black "userB"]
[Result "1-0"]
[TimeControl "180+2"]
${bareGameId ? '[GameId "$id"]\n' : ''}
$moves''';

String chesscomGame(
  String numericId, {
  String date = '2025.06.02',
  String link = '',
  String moves = '1. d4 d5 0-1',
}) =>
    '''
[Event "Live Chess"]
[Link "${link.isEmpty ? 'https://www.chess.com/game/live/$numericId' : link}"]
[Date "$date"]
[UTCTime "09:00:00"]
[White "userA"]
[Black "userB"]
[Result "0-1"]
[TimeControl "600"]

$moves''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tactics_import_pipeline');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    GameStoreService.setTestInstance(GameStoreService());
    // Maia is "available" on every desktop build, and `_processGames`
    // initializes it before it ever looks at the engine pool. Stub it so no
    // ONNX model is loaded on the way to the assertions below.
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
  });

  tearDown(() async {
    MaiaFactory.testOverride = null;
    GameStoreService.instance.close();
    await tempDir.delete(recursive: true);
  });

  /// A service whose database already believes [analyzed] were reviewed.
  Future<TacticsImportService> serviceWithAnalyzed(
    List<String> analyzed,
  ) async {
    await StorageFactory.instance.saveAnalyzedGameIds(analyzed);
    final db = TacticsDatabase();
    await db.loadPositions();
    return TacticsImportService(database: db);
  }

  /// Review [pgn] with the engine pool deliberately sized to zero workers.
  Future<ImportResult> review(
    TacticsImportService service,
    String pgn, {
    String username = 'userA',
    Set<String> force = const {},
  }) => service.reviewFetchedGames(
    pgnContent: pgn,
    username: username,
    depth: 8,
    maxCores: 0,
    forceDedupKeys: force,
  );

  Future<List<String>> storedTacticsPgns() async {
    final store = await GameStoreService.instance.open();
    return [for (final g in store.list(GameCollections.tactics)) g.pgn];
  }

  // ────────────────────────────────────────────────────────────────────────
  group('the already-analyzed pre-filter', () {
    test('a reviewed game is skipped and never reaches the engine', () async {
      final service = await serviceWithAnalyzed(['lichess_abc12345']);
      final messages = <String>[];

      final result = await service.reviewFetchedGames(
        pgnContent: lichessGame('abc12345'),
        username: 'userA',
        depth: 8,
        maxCores: 0,
        progressCallback: messages.add,
      );

      expect(result.gamesAnalyzed, 0);
      expect(result.gamesSkipped, 1);
      expect(result.positions, isEmpty);
      expect(messages.last, contains('all caught up'));
    });

    test('an unreviewed game is handed to the engine', () async {
      final service = await serviceWithAnalyzed(const []);
      await expectLater(
        review(service, lichessGame('abc12345')),
        _reachesTheEngine,
      );
    });

    test('every game skipped is counted, none analyzed', () async {
      final service = await serviceWithAnalyzed([
        'lichess_aaaaaaaa',
        'lichess_bbbbbbbb',
        'chesscom_777',
      ]);

      final result = await review(
        service,
        [
          lichessGame('aaaaaaaa'),
          lichessGame('bbbbbbbb'),
          chesscomGame('777'),
        ].join('\n\n'),
      );

      expect(result.gamesSkipped, 3);
      expect(result.gamesAnalyzed, 0);
    });

    test('skipAnalyzedGames = false reviews a game again', () async {
      final service = await serviceWithAnalyzed(['lichess_abc12345']);
      service.skipAnalyzedGames = false;
      await expectLater(
        review(service, lichessGame('abc12345')),
        _reachesTheEngine,
      );
    });

    test('forceDedupKeys re-opens a game marked analyzed', () async {
      final service = await serviceWithAnalyzed(['lichess_abc12345']);
      await expectLater(
        review(
          service,
          lichessGame('abc12345'),
          // dedupKeyForHeaders prefers the game URL.
          force: {'https://lichess.org/abc12345'},
        ),
        _reachesTheEngine,
      );
    });

    test(
      'forceDedupKeys naming another game leaves this one skipped',
      () async {
        final service = await serviceWithAnalyzed(['lichess_abc12345']);
        final result = await review(
          service,
          lichessGame('abc12345'),
          force: {'https://lichess.org/somethingelse'},
        );
        expect(result.gamesSkipped, 1);
        expect(result.gamesAnalyzed, 0);
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────────
  group('recovering a game id from its headers', () {
    // Each case asserts the id the pipeline derived by seeding *that exact
    // string* as an analyzed game and checking the game is skipped. A
    // mis-derived id would send the game to the engine instead.

    test('a Lichess Site URL yields a lichess_-prefixed id', () async {
      final service = await serviceWithAnalyzed(['lichess_abc12345']);
      expect((await review(service, lichessGame('abc12345'))).gamesSkipped, 1);
    });

    test(
      'a Chess.com Link yields the numeric id, chesscom_-prefixed',
      () async {
        final service = await serviceWithAnalyzed(['chesscom_999']);
        expect((await review(service, chesscomGame('999'))).gamesSkipped, 1);
      },
    );

    test('a Chess.com Link with a query string still yields the id', () async {
      final service = await serviceWithAnalyzed(['chesscom_999']);
      final pgn = chesscomGame(
        '999',
        link: 'https://www.chess.com/game/live/999?move=12',
      );
      expect((await review(service, pgn)).gamesSkipped, 1);
    });

    test(
      'a bare Lichess GameId is prefixed when no Site attributes it',
      () async {
        final service = await serviceWithAnalyzed(['lichess_abc12345']);
        final pgn = lichessGame('abc12345', site: false, bareGameId: true);
        expect((await review(service, pgn)).gamesSkipped, 1);
      },
    );

    test('an unprefixed GameId header is never trusted as-is', () async {
      // A chess.com export can carry a bare [GameId "999"] beside its Link.
      // Taking that at face value would file the game under "999", which
      // resumeStoredPgns cannot route to any platform — the game would sit in
      // the archive forever. The Link has to win.
      final withBareId = chesscomGame('999').replaceFirst(
        '[TimeControl "600"]',
        '[TimeControl "600"]\n[GameId "999"]',
      );

      final trusting = await serviceWithAnalyzed(['999']);
      await expectLater(review(trusting, withBareId), _reachesTheEngine);

      final correct = await serviceWithAnalyzed(['chesscom_999']);
      expect((await review(correct, withBareId)).gamesSkipped, 1);
    });

    test('a Lichess id shorter than six characters is not an id', () async {
      // The `length >= 6` guard: `lichess.org/abc` is a profile or a page,
      // not a game, and inventing an id from it would mark real games
      // analyzed under a bogus key.
      final service = await serviceWithAnalyzed(['lichess_abc']);
      const pgn = '''
[Event "Rated blitz game"]
[Site "https://lichess.org/abc"]
[UTCDate "2025.06.01"]
[White "userA"]
[Black "userB"]
[Result "1-0"]

1. e4 e5 1-0''';
      await expectLater(review(service, pgn), _reachesTheEngine);
    });

    test('a game with no recognizable id is reviewed every time', () async {
      final service = await serviceWithAnalyzed(const ['']);
      const pgn = '''
[Event "Casual game"]
[White "userA"]
[Black "userB"]
[Result "1-0"]

1. e4 e5 1-0''';
      await expectLater(review(service, pgn), _reachesTheEngine);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('legacy analyzed records', () {
    test('a bare lichess id still matches the prefixed game', () async {
      // Builds before the prefix existed stored "abc12345"; the same game now
      // resolves to "lichess_abc12345". It must not be re-reviewed.
      final service = await serviceWithAnalyzed(['abc12345']);
      expect((await review(service, lichessGame('abc12345'))).gamesSkipped, 1);
    });

    test(
      'the fallback is lichess-only — a bare number is not a chess.com game',
      () async {
        // Stripping any prefix would make the numeric ids chess.com uses
        // collide with unrelated legacy records.
        final service = await serviceWithAnalyzed(['999']);
        await expectLater(
          review(service, chesscomGame('999')),
          _reachesTheEngine,
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────────
  group('storing games for the resume queue', () {
    test('a fetched game is stored with a prefixed GameId injected', () async {
      final service = await serviceWithAnalyzed(['lichess_abc12345']);
      await review(service, lichessGame('abc12345'));

      final stored = await storedTacticsPgns();
      expect(stored, hasLength(1));
      expect(stored.single, contains('[GameId "lichess_abc12345"]'));
    });

    test('a chess.com game is stored under its chesscom_ id', () async {
      final service = await serviceWithAnalyzed(['chesscom_999']);
      await review(service, chesscomGame('999'));

      final stored = await storedTacticsPgns();
      expect(stored.single, contains('[GameId "chesscom_999"]'));
    });

    test(
      'storing is append-only: a stored game keeps its annotations',
      () async {
        final store = await GameStoreService.instance.open();
        store.importPgn(
          lichessGame(
            'abc12345',
            bareGameId: true,
            moves: '1. e4 {[%eval 0.21]} e5 2. Nf3 Nc6 1-0',
          ),
          collection: GameCollections.tactics,
        );

        final service = await serviceWithAnalyzed(['lichess_abc12345']);
        // The same game arriving again, this time without the annotation.
        await review(service, lichessGame('abc12345', bareGameId: true));

        final stored = await storedTacticsPgns();
        expect(stored, hasLength(1), reason: 'the game must not be duplicated');
        expect(
          stored.single,
          contains('[%eval 0.21]'),
          reason: 'a re-import must not overwrite locally added analysis',
        );
      },
    );

    test(
      're-storing does not duplicate a game already in the archive',
      () async {
        final service = await serviceWithAnalyzed(['lichess_abc12345']);
        await review(service, lichessGame('abc12345'));
        await review(service, lichessGame('abc12345'));

        expect(await storedTacticsPgns(), hasLength(1));
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────────
  group('pruneStoredPgns', () {
    String day(DateTime d) =>
        '${d.year}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.day.toString().padLeft(2, '0')}';

    Future<void> storeGames(List<String> pgns) async {
      await StorageFactory.instance.saveImportedPgns(pgns.join('\n\n'));
    }

    Future<List<String>> storedIds() async {
      final store = await GameStoreService.instance.open();
      return [
        for (final s in store.summaries(GameCollections.tactics))
          s.headers['Site'] ?? s.headers['Link'] ?? '?',
      ];
    }

    test('an analyzed game cited by a saved tactic is kept', () async {
      // The stored PGN doubles as the source game the tactics PGN tab shows,
      // so "analyzed" is not enough to drop it.
      final setPath = await StorageFactory.instance.tacticsSetPath('Default');
      await StorageFactory.instance.writeFile(setPath, '''
[Event "Tactic"]
[GameId "lichess_cited111"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]

*
''');
      await storeGames([lichessGame('cited111'), lichessGame('orphan11')]);
      final service = await serviceWithAnalyzed([
        'lichess_cited111',
        'lichess_orphan11',
      ]);

      expect(await service.pruneStoredPgns(), 1);
      expect(await storedIds(), ['https://lichess.org/cited111']);
    });

    test('an analyzed game nothing cites is dropped', () async {
      await storeGames([lichessGame('orphan11')]);
      final service = await serviceWithAnalyzed(['lichess_orphan11']);

      expect(await service.pruneStoredPgns(), 1);
      expect(await storedIds(), isEmpty);
    });

    test('an unanalyzed game inside the window is kept', () async {
      await storeGames([lichessGame('pending1', date: day(DateTime.now()))]);
      final service = await serviceWithAnalyzed(const []);

      expect(
        await service.pruneStoredPgns(
          since: DateTime.now().subtract(const Duration(days: 7)),
        ),
        0,
      );
      expect(await storedIds(), hasLength(1));
    });

    test('a game played on the cutoff day is inside the window', () async {
      // Boundary: the cutoff is compared at day granularity, and the cutoff
      // day itself counts as inside.
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await storeGames([lichessGame('edge0001', date: day(cutoff))]);
      final service = await serviceWithAnalyzed(const []);

      expect(await service.pruneStoredPgns(since: cutoff), 0);
      expect(await storedIds(), hasLength(1));
    });

    test('a game played the day before the cutoff has expired', () async {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await storeGames([
        lichessGame(
          'edge0002',
          date: day(cutoff.subtract(const Duration(days: 1))),
        ),
      ]);
      final service = await serviceWithAnalyzed(const []);

      expect(await service.pruneStoredPgns(since: cutoff), 1);
      expect(await storedIds(), isEmpty);
    });

    test('a game with no parseable date is never expired', () async {
      const undated = '''
[Event "Live Chess"]
[Link "https://www.chess.com/game/live/424242"]
[White "userA"]
[Black "userB"]
[Result "0-1"]

1. d4 d5 0-1''';
      await storeGames([undated]);
      final service = await serviceWithAnalyzed(const []);

      expect(await service.pruneStoredPgns(since: DateTime.now()), 0);
      expect(await storedIds(), hasLength(1));
    });

    test('an empty archive is a no-op', () async {
      final service = await serviceWithAnalyzed(const []);
      expect(await service.pruneStoredPgns(since: DateTime.now()), 0);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('resumeStoredPgns', () {
    Future<void> storeGames(List<String> pgns) =>
        StorageFactory.instance.saveImportedPgns(pgns.join('\n\n'));

    Future<ImportResult> resume(
      TacticsImportService service, {
      String? lichess,
      String? chesscom,
      DateTime? since,
    }) => service.resumeStoredPgns(
      lichessUsername: lichess,
      chesscomUsername: chesscom,
      depth: 8,
      since: since,
      maxCores: 0,
    );

    test('an empty archive reports nothing to do', () async {
      final service = await serviceWithAnalyzed(const []);
      final result = await resume(service, lichess: 'userA');

      expect(result.gamesAnalyzed, 0);
      expect(result.gamesSkipped, 0);
      expect(result.positions, isEmpty);
    });

    test('a stored lichess game resumes under the lichess account', () async {
      await storeGames([lichessGame('resume01', bareGameId: true)]);
      final service = await serviceWithAnalyzed(const []);

      await expectLater(
        resume(service, lichess: 'userA', chesscom: 'other'),
        _reachesTheEngine,
      );
    });

    test(
      'a stored lichess game is left alone with no lichess account',
      () async {
        // Routing is by the id's platform prefix, so a chess.com username must
        // not pick up a lichess game (it would be reviewed as the wrong player).
        await storeGames([lichessGame('resume01', bareGameId: true)]);
        final service = await serviceWithAnalyzed(const []);

        final result = await resume(service, lichess: null, chesscom: 'userA');
        expect(result.gamesAnalyzed, 0);
        expect(result.gamesSkipped, 0);
      },
    );

    test(
      'a stored chess.com game resumes under the chess.com account',
      () async {
        await storeGames([chesscomGame('999')]);
        final service = await serviceWithAnalyzed(const []);

        await expectLater(
          resume(service, lichess: 'other', chesscom: 'userA'),
          _reachesTheEngine,
        );
      },
    );

    test('an empty username counts as no account', () async {
      await storeGames([lichessGame('resume01', bareGameId: true)]);
      final service = await serviceWithAnalyzed(const []);

      final result = await resume(service, lichess: '', chesscom: '');
      expect(result.gamesAnalyzed, 0);
    });

    test(
      'an already-analyzed stored game is counted skipped, not resumed',
      () async {
        await storeGames([lichessGame('resume01', bareGameId: true)]);
        final service = await serviceWithAnalyzed(['lichess_resume01']);

        final result = await resume(service, lichess: 'userA');
        expect(result.gamesSkipped, 1);
        expect(result.gamesAnalyzed, 0);
      },
    );

    test(
      'a stored game older than the window is dropped from the queue',
      () async {
        await storeGames([
          lichessGame('resume01', date: '2020.01.01', bareGameId: true),
        ]);
        final service = await serviceWithAnalyzed(const []);

        final result = await resume(
          service,
          lichess: 'userA',
          since: DateTime(2025, 1, 1),
        );
        expect(result.gamesAnalyzed, 0);
        // Expired, not "already done": it is silently dropped, not counted.
        expect(result.gamesSkipped, 0);
      },
    );

    test('a stored game played on the window start is still queued', () async {
      await storeGames([
        lichessGame('resume01', date: '2025.01.01', bareGameId: true),
      ]);
      final service = await serviceWithAnalyzed(const []);

      await expectLater(
        resume(service, lichess: 'userA', since: DateTime(2025, 1, 1)),
        _reachesTheEngine,
      );
    });

    test('a stored game with no platform prefix is unresumable', () async {
      // Nothing routes it, so it can never be analyzed — it just sits there.
      // Pinned because the id extractor is what guarantees a prefix; if it
      // ever returns a bare id again, this silently strands the game.
      const unattributable = '''
[Event "Casual game"]
[White "userA"]
[Black "userB"]
[Result "1-0"]
[UTCDate "2025.06.01"]

1. e4 e5 1-0''';
      await storeGames([unattributable]);
      final service = await serviceWithAnalyzed(const []);

      final result = await resume(service, lichess: 'userA', chesscom: 'userA');
      expect(result.gamesAnalyzed, 0);
      expect(result.gamesSkipped, 0);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('cancellation', () {
    test(
      'a cancel raised before a run starts is discarded by the entry point',
      () async {
        // BUG (reported): every public entry point opens with `_cancelled =
        // false`, so a cancel that lands after the caller decided to run but
        // before the entry point is reached is thrown away. The coordinator
        // awaits `initialize()` in between, which is exactly that window — see
        // tactics_import_coordinator_test.dart for the user-visible effect.
        // This pins today's behaviour so the fix has to update it deliberately.
        final service = await serviceWithAnalyzed(['lichess_abc12345']);

        service.cancel();
        expect(service.wasCancelled, isTrue);

        await review(service, lichessGame('abc12345'));

        expect(
          service.wasCancelled,
          isFalse,
          reason: 'the pending cancel was silently dropped',
        );
      },
    );

    test('wasCancelled stays false through a normal run', () async {
      final service = await serviceWithAnalyzed(['lichess_abc12345']);
      await review(service, lichessGame('abc12345'));
      expect(service.wasCancelled, isFalse);
    });
  });
}
