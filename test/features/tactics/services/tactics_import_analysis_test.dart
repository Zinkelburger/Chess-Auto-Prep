/// The decisions the tactics-mining pass takes on one of my games — which
/// swings become puzzles and with which tag, which searches it declines to
/// run, what it writes onto the movetext, and which games it is allowed to
/// write off as reviewed.
///
/// Every run here drives the real `_processGames` through
/// [TacticsImportService.reviewFetchedGames] with [TacticsImportService.pool]
/// replaced by a [ScriptedPool]: a single-lane pool whose every search is
/// looked up by FEN. An unscripted FEN throws, which is the other half of the
/// oracle — a search the pass was supposed to *skip* fails loudly instead of
/// quietly succeeding, so the skips below are asserted from both sides.
///
/// Boundaries are asserted, never constants. Each classification threshold is
/// driven with the two adjacent centipawn scores that straddle it
/// ([straddleLoss]) — one centipawn moves a winning chance by well under a
/// thousandth, so a threshold that moved at all lands between the pair.
@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/tactics/services/tactics_database.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_service.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/services/games_library/game_review_store.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/generation/engine_fakes.dart' show FakeMaiaEvaluator;
import 'scripted_pool.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Search depth every run below asks for, and the depth every scripted result
/// comes back at — the shared eval cache's `minDepth` screen is keyed on it.
const int kDepth = 8;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ScriptedWorker worker;
  late ScriptedPool pool;
  late TacticsImportService service;
  late Map<String, ReviewCounts> reviewed;
  late Map<String, String> annotated;

  // ── Positions the fixtures below reach ───────────────────────────────────
  final start = fenAfter(const []);
  final afterE4 = fenAfter(const ['e4']);
  final afterE4e5 = fenAfter(const ['e4', 'e5']);
  final afterE4e5Nf3 = fenAfter(const ['e4', 'e5', 'Nf3']);

  /// A service reading the same on-disk analyzed-game list, over the scripted
  /// pool — what the coordinator builds for every run.
  Future<TacticsImportService> newService() async {
    final database = TacticsDatabase();
    await database.loadPositions();
    return TacticsImportService(database: database)..pool = pool;
  }

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tactics_import_analysis');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDownAll(() async {
    MaiaFactory.testOverride = null;
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GameStoreService.setTestInstance(GameStoreService());
    // Maia is "available" on every desktop build and the pass initializes it
    // before touching the pool. An empty policy makes
    // `TacticsEngine.buildTrainableLine` stop at the first PV move, so no
    // ONNX model loads and no extra search is issued.
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});

    // The shared eval cache is a process-wide singleton and the pass writes
    // to it; start every test from an empty one.
    await EvalCache.instance.clear();
    // Likewise the on-disk analyzed-game list, which outlives one service.
    await StorageFactory.instance.saveAnalyzedGameIds(const <String>[]);

    worker = ScriptedWorker();
    pool = ScriptedPool(worker);
    service = await newService();

    reviewed = {};
    annotated = {};
  });

  tearDown(() async {
    GameStoreService.instance.close();
  });

  // ── Fixtures ─────────────────────────────────────────────────────────────

  /// A game whose [Site] is its identity — [dedupKeyForHeaders] prefers the
  /// URL, and `_extractGameId` derives `lichess_<id>` from it, so a distinct
  /// [id] is a distinct game to both the review callbacks and the
  /// already-analyzed filter.
  ///
  /// Lichess ids are eight characters and `_extractGameId` will not call a
  /// shorter URL segment a game id at all, so the short names below are
  /// padded — a game with no id is one the pass cannot mark analyzed.
  // Exactly eight characters: a lichess game id is 8, and the identity
  // key only treats a lichess URL as identity-bearing at that length.
  String pad(String id) => id.padRight(8, 'z').substring(0, 8);

  String game(
    String id, {
    required String moves,
    String white = 'me',
    String black = 'opp',
    String result = '*',
  }) =>
      '''
[Event "Rated blitz game"]
[Site "https://lichess.org/${pad(id)}"]
[UTCDate "2025.06.01"]
[UTCTime "12:00:00"]
[White "$white"]
[Black "$black"]
[Result "$result"]
[TimeControl "600+0"]

$moves''';

  String key(String id) => 'https://lichess.org/${pad(id)}';

  /// `1. e4 e5` as White: exactly one of my moves, and it does not end the
  /// game — the smallest fixture that reaches every decision in the pass.
  String twoPly(String id, {String white = 'me', String black = 'opp'}) =>
      game(id, moves: '1. e4 e5 *', white: white, black: black);

  Future<ImportResult> review(String pgn, {String username = 'me'}) =>
      service.reviewFetchedGames(
        pgnContent: pgn,
        username: username,
        depth: kDepth,
        maxCores: 1,
        onGameReviewed: (dedupKey, counts) => reviewed[dedupKey] = counts,
        onGameAnnotated: (dedupKey, text) => annotated[dedupKey] = text,
      );

  /// Review [twoPly] with the position before my move scored dead level and
  /// the position after it worth [cpAfterFromUser] to me — so the swing the
  /// classifier sees is exactly `lostChances(cpAfterFromUser)`.
  ///
  /// The engine reports a position from the side to move, and after my move
  /// that is my opponent, hence the negation on the scripted score. `d2d4`
  /// is the engine's choice, so the played `e4` is never the best move and
  /// the confirming search always runs.
  Future<ImportResult> reviewOneMove(String id, int cpAfterFromUser) async {
    // Each half of a boundary test scores the same position differently, and
    // the pass files what it learns in the shared cache — where the other
    // half would find it and skip its own search.
    await EvalCache.instance.clear();
    worker.script[start] = cp(0, pv: const ['d2d4']);
    worker.script[afterE4] = cp(-cpAfterFromUser, pv: const ['e7e5']);
    return review(twoPly(id));
  }

  const clean = ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 0);

  // ── Boundaries ───────────────────────────────────────────────────────────
  group('what a swing is worth', () {
    test('a move is an inaccuracy from the exact centipawn that '
        'loses 0.10 winning chances', () async {
      final at = straddleLoss(0.10);

      final kept = await reviewOneMove('below10', at.keeps);
      expect(kept.positions, isEmpty, reason: 'below the bar: not a mistake');
      expect(reviewed[key('below10')], clean);

      final lost = await reviewOneMove('at10', at.loses);
      expect(lost.positions, hasLength(1));
      expect(lost.positions.single.mistakeType, '?!');
      expect(
        reviewed[key('at10')],
        const ReviewCounts(inaccuracies: 1, mistakes: 0, blunders: 0),
      );
    });

    test('a move is a mistake from the exact centipawn that '
        'loses 0.20 winning chances', () async {
      final at = straddleLoss(0.20);

      final kept = await reviewOneMove('below20', at.keeps);
      expect(kept.positions.single.mistakeType, '?!');
      expect(
        reviewed[key('below20')],
        const ReviewCounts(inaccuracies: 1, mistakes: 0, blunders: 0),
      );

      final lost = await reviewOneMove('at20', at.loses);
      expect(lost.positions.single.mistakeType, '?');
      expect(
        reviewed[key('at20')],
        const ReviewCounts(inaccuracies: 0, mistakes: 1, blunders: 0),
      );
    });

    test('a move is a blunder from the exact centipawn that '
        'loses 0.30 winning chances', () async {
      final at = straddleLoss(0.30);

      final kept = await reviewOneMove('below30', at.keeps);
      expect(kept.positions.single.mistakeType, '?');
      expect(
        reviewed[key('below30')],
        const ReviewCounts(inaccuracies: 0, mistakes: 1, blunders: 0),
      );

      final lost = await reviewOneMove('at30', at.loses);
      expect(lost.positions.single.mistakeType, '??');
      expect(
        reviewed[key('at30')],
        const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 1),
      );
    });

    test('a mined puzzle carries the position, the played move and the '
        'engine line it should have been', () async {
      final mined = (await reviewOneMove(
        'card',
        straddleLoss(0.30).loses,
      )).positions.single;

      expect(mined.fen, start);
      expect(mined.userMove, 'e4');
      expect(mined.solutionPv, ['d4']);
      expect(mined.correctLine, ['d4']);
      expect(mined.opponentBestResponse, 'e5');
      expect(mined.gameId, 'lichess_cardzzzz');
      expect(mined.sourceMovetext, '1. e4 e5');
      // The flashcard back: what I played, its eval arc, and the best move.
      expect(mined.mistakeAnalysis, startsWith('e4 +0.0 → '));
      expect(mined.mistakeAnalysis, contains('d4 +0.0'));
    });
  });

  // ── Searches the pass declines to run ────────────────────────────────────
  group('the best-move skip', () {
    test('playing the engine\'s own move issues no confirming search, and '
        'the score after it is the score before it', () async {
      // `e2e4` is the engine's first PV move and is what was played. The
      // position after it is deliberately left unscripted: a confirming
      // search would throw, the game would be dropped, and the review
      // callback below would never fire.
      worker.script[start] = cp(-500, pv: const ['e2e4', 'e7e5', 'g1f3']);

      final result = await review(twoPly('skip'));

      expect(worker.searched, [start]);
      expect(result.positions, isEmpty);
      // A move losing nothing is what "wcAfter := wcBefore" means: from a
      // position worth -5.00 to me, only an unchanged score leaves this clean.
      expect(reviewed[key('skip')], clean);
      // Both halves of the search are reused: the collapsed score is written
      // onto the played ply, and the rest of the same line becomes the next
      // ply's best line — without a second search for either.
      expect(
        annotated[key('skip')],
        '1. e4 { [%eval -5.00,$kDepth] [%pv e4,e5,Nf3] } e5 *',
      );
    });

    test('a played move that only looks like the engine\'s is still '
        'confirmed', () async {
      // Same shape as above, but the engine wanted d4. The confirming search
      // has to happen, so scripting it is what keeps the game alive.
      worker.script[start] = cp(-500, pv: const ['d2d4']);
      worker.script[afterE4] = cp(500, pv: const ['e7e5']);

      final result = await review(twoPly('noskip'));

      expect(worker.searched, [start, afterE4]);
      expect(result.positions, isEmpty, reason: 'still -5.00 to me, no swing');
      expect(reviewed[key('noskip')], clean);
    });
  });

  group('the shared eval cache screen-out', () {
    test('a cached score that says nothing was lost skips the confirming '
        'search', () async {
      final at = straddleLoss(0.10);
      worker.script[start] = cp(0, pv: const ['d2d4']);
      // White-normalized, and I am White. `afterE4` stays unscripted: the
      // whole point is that the engine is never asked about it.
      await EvalCache.instance.putEvalCpWhite(afterE4, at.keeps, kDepth);

      final result = await review(twoPly('cachehit'));

      expect(worker.searched, [start]);
      expect(result.positions, isEmpty);
      expect(reviewed[key('cachehit')], clean);
      // The cached number still reaches the movetext; it just brings no line
      // with it, so the next ply keeps none either.
      expect(
        annotated[key('cachehit')],
        '1. e4 { [%eval -0.54,$kDepth] [%pv d4] } e5 *',
      );
    });

    test('a cached score one centipawn worse sends the move to the engine '
        'after all', () async {
      final at = straddleLoss(0.10);
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(-at.loses, pv: const ['e7e5']);
      await EvalCache.instance.putEvalCpWhite(afterE4, at.loses, kDepth);

      final result = await review(twoPly('cachemiss'));

      expect(worker.searched, [start, afterE4]);
      expect(result.positions.single.mistakeType, '?!');
    });

    test('a cached score shallower than this run is not trusted', () async {
      final at = straddleLoss(0.10);
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(-at.keeps, pv: const ['e7e5']);
      await EvalCache.instance.putEvalCpWhite(afterE4, at.keeps, kDepth - 1);

      await review(twoPly('shallow'));

      expect(worker.searched, [start, afterE4]);
    });
  });

  // ── Mate ────────────────────────────────────────────────────────────────
  group('mate scores', () {
    test('throwing away a mate in one is a blunder', () async {
      // `scoreMate` with `scoreCp` null, the way Stockfish announces a mate.
      // Code reading `scoreCp` raw would see 0 here and find no swing at all.
      worker.script[start] = mateIn(1, pv: const ['d2d4']);
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);

      final result = await review(twoPly('mate1'));

      expect(result.positions.single.mistakeType, '??');
      expect(result.positions.single.mistakeAnalysis, startsWith('e4 #1 → '));
      expect(
        reviewed[key('mate1')],
        const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 1),
      );
      // A mate has no centipawn meaning, and the shared cache is
      // centipawns-only, so it must not be written there.
      expect(await EvalCache.instance.getEvalCpWhite(start), isNull);
    });

    test('a game that ends in mate scores every ply but the last, and the '
        'mating move is never punished', () async {
      // Fool's mate, and I am Black: my moves are plies 1 and 3, and ply 3
      // ends the game.
      final afterF3 = fenAfter(const ['f3']);
      final afterF3e5 = fenAfter(const ['f3', 'e5']);
      final afterF3e5g4 = fenAfter(const ['f3', 'e5', 'g4']);
      worker.script[afterF3] = cp(20, pv: const ['b8c6']);
      worker.script[afterF3e5] = cp(-30, pv: const ['g2g4']);
      worker.script[afterF3e5g4] = mateIn(1, pv: const ['d8h4']);

      final result = await review(
        game(
          'foolsmate',
          moves: '1. f3 e5 2. g4 Qh4# 0-1',
          white: 'opp',
          black: 'me',
          result: '0-1',
        ),
      );

      // The move that mated has no position after it to score, so it can
      // never be a mistake — and the pass never searches for one.
      expect(worker.searched, [afterF3, afterF3e5, afterF3e5g4]);
      expect(result.positions, isEmpty);
      expect(reviewed[key('foolsmate')], clean);
      // Scores are White-normalized whoever moved: my +0.20 as Black reads
      // -0.20, and my mate in one reads #-1.
      expect(
        annotated[key('foolsmate')],
        '1. f3 { [%eval -0.20,$kDepth] } '
        'e5 { [%eval -0.30,$kDepth] [%pv Nc6] } '
        '2. g4 { [%eval #-1,$kDepth] [%pv g4] } Qh4# 0-1',
      );
    });
  });

  // ── Shapes of game ──────────────────────────────────────────────────────
  group('the shape of the game', () {
    test('a one-move game is mined and annotated without running off the '
        'end of the ply series', () async {
      final at = straddleLoss(0.30);
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(-at.loses, pv: const ['e7e5']);

      final result = await review(game('oneply', moves: '1. e4 *'));

      expect(result.positions.single.mistakeType, '??');
      expect(
        annotated[key('oneply')],
        '1. e4 { [%eval -1.69,$kDepth] [%pv d4] } *',
      );
    });

    test('a game with nothing wrong in it is still recorded as reviewed, '
        'and is not reviewed twice', () async {
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);

      final first = await review(twoPly('clean'));
      expect(first.positions, isEmpty);
      expect(first.gamesAnalyzed, 1);
      expect(first.gamesSkipped, 0);
      expect(reviewed[key('clean')], clean);

      final second = await review(twoPly('clean'));
      expect(second.gamesAnalyzed, 0);
      expect(second.gamesSkipped, 1, reason: '"nothing wrong" is a result');
    });
  });

  // ── Cancellation ────────────────────────────────────────────────────────
  group('cancelling mid-game', () {
    test('a game cancelled partway is discarded whole, and is looked at '
        'again on the next run', () async {
      final at = straddleLoss(0.30);
      // My first move is a blunder; my second is fine. Every position is
      // scripted, so nothing but the cancel can stop the pass.
      void writeScript() {
        worker.script[start] = cp(0, pv: const ['d2d4']);
        worker.script[afterE4] = cp(-at.loses, pv: const ['e7e5']);
        worker.script[afterE4e5] = cp(0, pv: const ['b1c3']);
        worker.script[afterE4e5Nf3] = cp(0, pv: const ['g8f6']);
      }

      writeScript();
      // Raise the cancel as the second of my moves starts being evaluated —
      // after the first has already produced a puzzle.
      worker.onSearch = (fen) {
        if (fen == afterE4e5) service.cancel();
      };

      final cancelled = await review(
        game('abort', moves: '1. e4 e5 2. Nf3 Nc6 *'),
      );

      // Guarded twice on purpose — the analysis pass returns nothing for a
      // cancelled game, and the import loop breaks before it would take it —
      // so this fails only when both guards are gone. That is the behaviour
      // worth pinning: nothing from a cancelled game reaches the caller.
      expect(cancelled.positions, isEmpty, reason: 'no half-imported game');
      expect(cancelled.gamesAnalyzed, 0);
      expect(reviewed, isEmpty, reason: 'a cancelled game is not reviewed');
      expect(annotated, isEmpty);

      worker.onSearch = null;
      worker.searched.clear();
      writeScript();
      // The coordinator builds a service per run, and a cancelled one stays
      // cancelled for the rest of its life on purpose — see
      // [TacticsImportService.beginRun]. Resuming means a new service reading
      // the same analyzed-game list, which is the list under test here.
      service = await newService();

      final resumed = await review(
        game('abort', moves: '1. e4 e5 2. Nf3 Nc6 *'),
      );

      expect(resumed.gamesSkipped, 0, reason: 'never marked analyzed');
      expect(resumed.positions.single.mistakeType, '??');
      expect(
        reviewed[key('abort')],
        const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 1),
      );
    });
  });

  // ── Whose game is this ──────────────────────────────────────────────────
  group('deciding the game is mine', () {
    test('a game matching neither header is never marked analyzed', () async {
      // The regression: one import under a typo'd username used to write off
      // the whole library, because a game that is not mine was marked
      // analyzed anyway — and only clearing the database undid it.
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);
      final theirs = twoPly('theirs', white: 'someone', black: 'else');

      final first = await review(theirs, username: 'me');
      expect(first.positions, isEmpty);
      expect(worker.searched, isEmpty, reason: 'no engine work on their game');
      expect(reviewed, isEmpty);

      final second = await review(theirs, username: 'me');
      expect(
        second.gamesSkipped,
        0,
        reason: 'correcting the username must still find this game',
      );

      // The contrast, so the assertion above cannot pass because nothing is
      // ever marked: the same two runs on a game that *is* mine do skip.
      final mine = twoPly('mine');
      expect((await review(mine, username: 'me')).gamesSkipped, 0);
      expect((await review(mine, username: 'me')).gamesSkipped, 1);
    });

    test('an opponent whose name contains mine is not me', () async {
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);

      final result = await review(
        twoPly('superstring', white: 'talinda', black: 'opp'),
        username: 'tal',
      );

      expect(result.positions, isEmpty);
      expect(worker.searched, isEmpty);
      expect(reviewed, isEmpty);
    });

    test('the header match ignores case', () async {
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);

      await review(twoPly('caps', white: 'ME'), username: 'me');

      expect(worker.searched, [start, afterE4]);
      expect(reviewed[key('caps')], clean);
    });
  });

  // ── The ply series ──────────────────────────────────────────────────────
  group('the annotated movetext', () {
    test('every ply carries the score after it and the line before it, '
        'each White-normalized', () async {
      // Two of my moves, four plies. Site 0 writes plies 0 (its after-score)
      // and 1 (its after-line); site 1 writes plies 1 and 2. Distinct scores
      // and distinct lines, so any index or sign that shifted shows up.
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(30, pv: const ['e7e5']);
      worker.script[afterE4e5] = cp(40, pv: const ['b1c3']);
      worker.script[afterE4e5Nf3] = cp(-50, pv: const ['g8f6']);

      await review(game('series', moves: '1. e4 e5 2. Nf3 Nc6 *'));

      expect(
        annotated[key('series')],
        // The spacing and the terminator are dartchess's `makePgn`, which the
        // pass serializes through so a game's sidelines and opening comment
        // survive being written back. Both are valid PGN.
        '1. e4 { [%eval -0.30,$kDepth] [%pv d4] } '
        'e5 { [%eval 0.40,$kDepth] [%pv e5] } '
        '2. Nf3 { [%eval 0.50,$kDepth] [%pv Nc3] } Nc6 *',
      );
    });

    test('a clock comment already on a move survives the annotation', () async {
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);

      await review(
        game('clocks', moves: '1. e4 {[%clk 0:09:58]} e5 {[%clk 0:09:55]} *'),
      );

      expect(annotated[key('clocks')], contains('[%clk 0:09:58]'));
      expect(annotated[key('clocks')], contains('[%eval 0.00,$kDepth]'));
    });
  });
}
