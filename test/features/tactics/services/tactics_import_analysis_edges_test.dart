/// The corners of the tactics mining pass that `tactics_import_analysis_test`
/// leaves untouched: the per-run opening memo, the castling encoding the
/// best-move skip has to see through, what a mate looks like once it is
/// written down, the flaw tags read off a game's clocks, games that start from
/// a `[FEN]`, games with an illegal ply, and the sign of everything when I am
/// Black.
///
/// Same rig as the sibling file: the real `_processGames` driven through
/// [TacticsImportService.reviewFetchedGames] over a [ScriptedPool], where an
/// unscripted FEN throws — so every "this search is skipped" below is asserted
/// from both sides.
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
import 'package:dartchess/dartchess.dart';
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

const int kDepth = 8;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ScriptedWorker worker;
  late ScriptedPool pool;
  late TacticsImportService service;
  late Map<String, ReviewCounts> reviewed;
  late Map<String, String> annotated;

  final start = fenAfter(const []);
  final afterE4 = fenAfter(const ['e4']);
  final afterE4e5 = fenAfter(const ['e4', 'e5']);
  final afterE4e5Nf3 = fenAfter(const ['e4', 'e5', 'Nf3']);

  Future<TacticsImportService> newService() async {
    final database = TacticsDatabase();
    await database.loadPositions();
    return TacticsImportService(database: database)..pool = pool;
  }

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tactics_analysis_edges');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDownAll(() async {
    MaiaFactory.testOverride = null;
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GameStoreService.setTestInstance(GameStoreService());
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
    await EvalCache.instance.clear();
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

  String pad(String id) => id.padRight(8, 'z').substring(0, 8);

  String game(
    String id, {
    required String moves,
    String white = 'me',
    String black = 'opp',
    String result = '*',
    String timeControl = '600+0',
    String? fen,
  }) =>
      '''
[Event "Rated blitz game"]
[Site "https://lichess.org/${pad(id)}"]
[UTCDate "2025.06.01"]
[UTCTime "12:00:00"]
[White "$white"]
[Black "$black"]
[Result "$result"]
[TimeControl "$timeControl"]
${fen == null ? '' : '[SetUp "1"]\n[FEN "$fen"]\n'}
$moves''';

  String key(String id) => 'https://lichess.org/${pad(id)}';

  Future<ImportResult> review(String pgn, {String username = 'me'}) =>
      service.reviewFetchedGames(
        pgnContent: pgn,
        username: username,
        depth: kDepth,
        maxCores: 1,
        onGameReviewed: (dedupKey, counts) => reviewed[dedupKey] = counts,
        onGameAnnotated: (dedupKey, text) => annotated[dedupKey] = text,
      );

  const clean = ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 0);

  /// The FEN before each ply of [sans] from the standard start, ply 0 first.
  List<String> fensBefore(List<String> sans) {
    Position pos = Chess.initial;
    final fens = <String>[];
    for (final san in sans) {
      fens.add(pos.fen);
      pos = pos.play(pos.parseSan(san)!);
    }
    return fens;
  }

  String numbered(List<String> sans) {
    final buf = StringBuffer();
    for (var i = 0; i < sans.length; i++) {
      if (i.isEven) buf.write('${i ~/ 2 + 1}. ');
      buf.write('${sans[i]} ');
    }
    return '$buf*';
  }

  // ── The opening memo ─────────────────────────────────────────────────────
  group('the per-run opening memo', () {
    test('a position two games share is searched once up to move 10, and '
        'once per game past it', () async {
      // Knights out and back, five times, then out again: 22 plies, every
      // FEN distinct (the move counters keep climbing), my 11th move made
      // from a fullmove-11 position — one past the memo's reach.
      final sans = <String>[
        for (var i = 0; i < 5; i++) ...['Nf3', 'Nf6', 'Ng1', 'Ng8'],
        'Nf3',
        'Nf6',
      ];
      final fens = fensBefore(sans);
      // Every one of my moves is the engine's own, so only the position
      // before each is ever searched.
      for (var ply = 0; ply < sans.length; ply += 2) {
        final uci = (ply ~/ 2).isEven ? 'g1f3' : 'f3g1';
        worker.script[fens[ply]] = cp(0, pv: [uci]);
      }
      final pgn =
          '${game('shuffle1', moves: numbered(sans))}\n\n'
          '${game('shuffle2', moves: numbered(sans))}';

      final result = await review(pgn);

      expect(result.gamesAnalyzed, 2);
      expect(reviewed[key('shuffle1')], clean);
      expect(reviewed[key('shuffle2')], clean);
      final mine = [for (var ply = 0; ply < sans.length; ply += 2) fens[ply]];
      expect(worker.searched.length, mine.length + 1);
      for (final fen in mine.sublist(0, mine.length - 1)) {
        expect(
          worker.searched.where((f) => f == fen).length,
          1,
          reason: 'fullmove ≤ 10 is served from the memo on the second game',
        );
      }
      expect(
        worker.searched.where((f) => f == mine.last).length,
        2,
        reason: 'fullmove 11 is outside the memo and searched per game',
      );
    });

    test('a search that failed is not memoised: the next game reaching the '
        'position asks the engine again', () async {
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);
      // Unscripted on its first visit, so the first game's search throws;
      // scripted from the second visit on. A memo that kept the failed
      // future would hand the second game the same error.
      var visits = 0;
      worker.onSearch = (fen) {
        if (fen != start) return;
        visits++;
        if (visits >= 2) worker.script[start] = cp(0, pv: const ['d2d4']);
      };
      final pgn =
          '${game('fail1', moves: '1. e4 e5 *')}\n\n'
          '${game('fail2', moves: '1. e4 e5 *')}';

      await review(pgn);

      expect(worker.searched, [start, start, afterE4]);
      expect(reviewed.keys, [key('fail2')]);
      expect(reviewed[key('fail2')], clean);
    });
  });

  // ── The best-move skip ───────────────────────────────────────────────────
  group('the best-move skip', () {
    test('castling is recognised whichever way the engine spells it', () async {
      // Stockfish says e1g1; dartchess plays O-O as e1h1. The skip compares
      // the positions reached, not the strings — if it compared strings, the
      // unscripted position after castling would be searched and throw.
      final sans = ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'O-O'];
      final fens = fensBefore(sans);
      worker.script[fens[0]] = cp(0, pv: const ['e2e4']);
      worker.script[fens[2]] = cp(0, pv: const ['g1f3']);
      worker.script[fens[4]] = cp(0, pv: const ['f1c4']);
      worker.script[fens[6]] = cp(15, pv: const ['e1g1']);

      final result = await review(game('castle', moves: numbered(sans)));

      expect(worker.searched, [fens[0], fens[2], fens[4], fens[6]]);
      expect(result.positions, isEmpty);
      expect(reviewed[key('castle')], clean);
      expect(
        annotated[key('castle')],
        endsWith('4. O-O { [%eval 0.15,$kDepth] [%pv O-O] } *'),
      );
    });

    test('playing the first move of a mate-in-two writes mate-in-one after '
        'it, not the packed score that reads back as mate-in-two', () async {
      // Kf6 + Qa2 v Kh8: 1. Qa7 (threat Qg7#) Kg8 2. Qg7#. Both my moves
      // are the engine's own, so neither position after them is searched;
      // the score written onto 1. Qa7 is derived from the search before it.
      const fen = '7k/8/5K2/8/8/8/Q7/8 w - - 0 1';
      final before = Chess.fromSetup(Setup.parseFen(fen));
      final afterQa7Kg8 = before
          .play(before.parseSan('Qa7')!)
          .play(before.play(before.parseSan('Qa7')!).parseSan('Kg8')!);
      worker.script[before.fen] = mateIn(2, pv: const ['a2a7', 'h8g8', 'a7g7']);
      worker.script[afterQa7Kg8.fen] = mateIn(1, pv: const ['a7g7']);

      await review(
        game(
          'matein2',
          moves: '1. Qa7 Kg8 2. Qg7# 1-0',
          result: '1-0',
          fen: fen,
        ),
      );

      expect(worker.searched, [before.fen, afterQa7Kg8.fen]);
      expect(reviewed[key('matein2')], clean);
      // Once Qa7 is on the board White mates in one more move. Written as a
      // collapsed centipawn value (99.98) it reads back through the viewer's
      // mate unpacking as "#2" — the off-by-one the skip set out to avoid.
      expect(
        annotated[key('matein2')],
        '1. Qa7 { [%eval #1,$kDepth] [%pv Qa7,Kg8,Qg7#] } '
        'Kg8 { [%eval #1,$kDepth] [%pv Kg8,Qg7#] } 2. Qg7# 1-0',
      );
    });

    test('the distance of a mate against me survives my best defence, and '
        'a mate for Black keeps its sign', () async {
      // Getting mated in three and playing the engine's own delaying move:
      // the opponent still needs three of their moves, so the distance
      // written after my move is unchanged.
      worker.script[start] = mateIn(-3, pv: const ['e2e4']);
      await review(game('mated3', moves: '1. e4 e5 *'));
      expect(
        annotated[key('mated3')],
        '1. e4 \$4 { [%eval #-3,$kDepth] [%pv e4] } 1... e5 *',
      );

      // As Black with a mate in two, my first move of it reads #-1 in the
      // White-normalized comment, and the position before it #-2.
      worker.script[afterE4] = mateIn(2, pv: const ['e7e5', 'd2d4']);
      await review(
        game('blackmate', moves: '1. e4 e5 *', white: 'opp', black: 'me'),
      );
      expect(
        annotated[key('blackmate')],
        '1. e4 \$4 { [%eval #-2,$kDepth] } 1... e5 { [%eval #-1,$kDepth] [%pv e5,d4] } *',
      );
    });
  });

  // ── Mate through the opponent's reply ────────────────────────────────────
  group('being mated', () {
    test('walking into mate as White is a blunder with the mating reply on '
        'the card, and losing to it is not "lucky"', () async {
      final afterF3 = fenAfter(const ['f3']);
      final afterF3e5 = fenAfter(const ['f3', 'e5']);
      final afterF3e5g4 = fenAfter(const ['f3', 'e5', 'g4']);
      worker.script[start] = cp(20, pv: const ['e2e4']);
      worker.script[afterF3] = cp(30, pv: const ['e7e5']);
      worker.script[afterF3e5] = cp(-30, pv: const ['b1c3']);
      worker.script[afterF3e5g4] = mateIn(1, pv: const ['d8h4']);

      final result = await review(
        game('foolwhite', moves: '1. f3 e5 2. g4 Qh4# 0-1', result: '0-1'),
      );

      expect(worker.searched, [start, afterF3, afterF3e5, afterF3e5g4]);
      final mined = result.positions.single;
      expect(mined.fen, afterF3e5);
      expect(mined.userMove, 'g4');
      expect(mined.mistakeType, '??');
      expect(mined.correctLine, ['Nc3']);
      expect(mined.opponentBestResponse, 'Qh4#');
      // The card's evals are from my side: the score after my move is the
      // opponent's mate-in-one, negated.
      expect(mined.mistakeAnalysis, 'g4 -0.3 → #-1, Nc3 -0.3');
      // A blunder at my last move is "lucky" only when the game did not end
      // in my defeat; 0-1 as White is a defeat.
      expect(mined.flawTags, ['opening']);
      expect(
        reviewed[key('foolwhite')],
        const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 1),
      );
      expect(
        annotated[key('foolwhite')],
        '1. f3 { [%eval -0.30,$kDepth] [%pv e4] } '
        'e5 { [%eval -0.30,$kDepth] [%pv e5] } '
        '2. g4 \$4 { [%eval #-1,$kDepth] [%pv Nc3] } 2... Qh4# 0-1',
      );
      // The shared cache is centipawns-only: the mated position is not
      // filed, the others are, White-normalized.
      expect(await EvalCache.instance.getEvalCpWhite(afterF3e5g4), isNull);
      expect(await EvalCache.instance.getEvalCpWhite(afterF3), -30);
      expect(await EvalCache.instance.getEvalCpWhite(afterF3e5), -30);
    });

    test('choosing a slower mate is not a mistake', () async {
      // Winning chances saturate at ten pawns, the same clamp Lichess uses,
      // so a mate in three and a mate in four are worth the same.
      worker.script[start] = mateIn(3, pv: const ['d2d4']);
      worker.script[afterE4] = mateIn(-4, pv: const ['e7e5']);

      final result = await review(game('slower', moves: '1. e4 e5 *'));

      expect(worker.searched, [start, afterE4]);
      expect(result.positions, isEmpty);
      expect(reviewed[key('slower')], clean);
      expect(
        annotated[key('slower')],
        '1. e4 { [%eval #4,$kDepth] [%pv d4] } e5 *',
      );
    });
  });

  // ── Flaw tags ────────────────────────────────────────────────────────────
  group('flaw tags', () {
    test('a blunder is tagged from the game around it: the gift before it, '
        'the escape after it, and the seconds spent on it', () async {
      // My 1. e4 is fine. The opponent's 1... e5 hands me +1.50 (a
      // mistake-sized gift), which I throw away with a three-second 2. Nf3
      // in a 600+0 game. Nothing follows, and the game is not lost.
      worker.script[start] = cp(0, pv: const ['d2d4']);
      worker.script[afterE4] = cp(0, pv: const ['e7e5']);
      worker.script[afterE4e5] = cp(150, pv: const ['b1c3']);
      worker.script[afterE4e5Nf3] = cp(50, pv: const ['g8f6']);

      final result = await review(
        game(
          'tagged',
          moves:
              '1. e4 {[%clk 0:09:58]} e5 {[%clk 0:09:59]} '
              '2. Nf3 {[%clk 0:09:55]} Nc6 {[%clk 0:09:50]} *',
        ),
      );

      final mined = result.positions.single;
      expect(mined.userMove, 'Nf3');
      expect(mined.mistakeType, '??');
      expect(mined.flawTags, ['miss', 'lucky', 'opening', 'hasty']);
      expect(
        reviewed[key('tagged')],
        const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 1),
      );
    });
  });

  // ── Untrainable mistakes ─────────────────────────────────────────────────
  group('a mistake with no line to train', () {
    test('is counted but not mined, and its ply carries no [%pv]', () async {
      final at = straddleLoss(0.30);
      worker.script[start] = cp(0, pv: const []);
      worker.script[afterE4] = cp(-at.loses, pv: const ['e7e5']);

      final result = await review(game('nopv', moves: '1. e4 e5 *'));

      expect(result.positions, isEmpty);
      expect(
        reviewed[key('nopv')],
        const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 1),
      );
      final evalText = (-at.loses / 100).toStringAsFixed(2);
      expect(
        annotated[key('nopv')],
        '1. e4 \$4 { [%eval -$evalText,$kDepth] } 1... e5 *',
      );
    });
  });

  // ── Being Black ──────────────────────────────────────────────────────────
  group('as Black', () {
    test('a game that starts from a FEN is mined from that position, with '
        'the card and the cache seen from the right side', () async {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final before = Chess.fromSetup(Setup.parseFen(fen));
      final afterE5 = before.play(before.parseSan('e5')!);
      worker.script[before.fen] = cp(40, pv: const ['d7d5']);
      worker.script[afterE5.fen] = cp(30, pv: const ['g1f3']);

      final result = await review(
        game(
          'fenstart',
          moves: '1... e5 2. Nf3 *',
          white: 'opp',
          black: 'me',
          fen: fen,
        ),
      );

      expect(worker.searched, [before.fen, afterE5.fen]);
      final mined = result.positions.single;
      expect(mined.fen, before.fen);
      expect(mined.userMove, 'e5');
      expect(mined.mistakeType, '?!');
      expect(mined.correctLine, ['d5']);
      // Evals on the card are from my side — Black's — not White's.
      expect(mined.mistakeAnalysis, 'e5 +0.4 → -0.3, d5 +0.4');
      // No numbered replay from move 1 exists for a custom start.
      expect(mined.sourceMovetext, isEmpty);
      // The movetext keeps its start rather than being renumbered from 1.
      expect(
        annotated[key('fenstart')],
        '1... e5 { [%eval 0.30,$kDepth] [%pv d5] } 2. Nf3 *',
      );
      // Both positions reach the shared cache White-normalized: my +0.40 as
      // Black files as -40, the opponent's +0.30 as White as +30.
      expect(await EvalCache.instance.getEvalCpWhite(before.fen), -40);
      expect(await EvalCache.instance.getEvalCpWhite(afterE5.fen), 30);
    });

    test('the shared-cache screen-out reads a White-normalized score from '
        'my side', () async {
      final at = straddleLoss(0.10);
      worker.script[afterE4] = cp(0, pv: const ['d7d5']);
      // A White-normalized +54 is -54 to me: a loss the screen must send to
      // the engine. Read unnegated it would look like a gain and be skipped.
      await EvalCache.instance.putEvalCpWhite(afterE4e5, -at.loses, kDepth);
      worker.script[afterE4e5] = cp(-at.loses, pv: const ['g1f3']);

      final result = await review(
        game('bcache1', moves: '1. e4 e5 *', white: 'opp', black: 'me'),
      );

      expect(worker.searched, [afterE4, afterE4e5]);
      expect(result.positions.single.mistakeType, '?!');

      // One centipawn less lost, and the screen-out holds: no second search.
      await EvalCache.instance.clear();
      worker.searched.clear();
      await EvalCache.instance.putEvalCpWhite(afterE4e5, -at.keeps, kDepth);
      final kept = await review(
        game('bcache2', moves: '1. e4 e5 *', white: 'opp', black: 'me'),
      );
      expect(worker.searched, [afterE4]);
      expect(kept.positions, isEmpty);
      expect(reviewed[key('bcache2')], clean);
    });
  });

  // ── Odd shapes of game ───────────────────────────────────────────────────
  group('odd shapes of game', () {
    test('a game with an illegal ply is reviewed up to it and then marked '
        'analyzed, never searched past it', () async {
      // Black cannot play 2... Nf3. Everything before it is a normal game.
      worker.script[start] = cp(0, pv: const ['e2e4']);
      worker.script[afterE4e5] = cp(0, pv: const ['g1f3']);
      final pgn = game('illegal', moves: '1. e4 e5 2. Nf3 Nf3 3. Nc3 *');

      final first = await review(pgn);

      expect(worker.searched, [start, afterE4e5]);
      expect(first.gamesAnalyzed, 1);
      expect(reviewed[key('illegal')], clean);

      final second = await review(pgn);
      expect(second.gamesSkipped, 1, reason: 'retrying cannot help');
    });

    test('a game with no moves is reviewed clean without touching the engine '
        'and gets no annotated movetext', () async {
      final result = await review(game('empty', moves: '*'));

      expect(worker.searched, isEmpty);
      expect(result.gamesAnalyzed, 1);
      expect(result.positions, isEmpty);
      expect(reviewed[key('empty')], clean);
      expect(annotated, isEmpty);
    });

    test('a move that ends the game is never followed by a search', () async {
      // Kg6 + Qf2 v Kh8: 1. Qf7 stalemates. The position after it is over,
      // so there is nothing for the engine to say about it.
      const fen = '7k/8/6K1/8/8/8/5Q2/8 w - - 0 1';
      final before = Chess.fromSetup(Setup.parseFen(fen));
      worker.script[before.fen] = mateIn(1, pv: const ['f2f8']);

      await review(
        game('stale1', moves: '1. Qf7 1/2-1/2', result: '1/2-1/2', fen: fen),
      );

      expect(worker.searched, [before.fen]);
    });

    test(
      'stalemating from a mate-in-one is a blunder',
      () async {
        // BUG: a move that ends the game gets no post-eval and "cannot be a
        // mistake" (see the `endsGame` branch), which is right for a mating
        // move and wrong for a stalemate or a draw by insufficient material
        // reached from a won position. Here Qf8# was on and Qf7 threw the
        // whole point away; the pass reports the game as clean and mines
        // nothing.
        const fen = '7k/8/6K1/8/8/8/5Q2/8 w - - 0 1';
        final before = Chess.fromSetup(Setup.parseFen(fen));
        worker.script[before.fen] = mateIn(1, pv: const ['f2f8']);

        final result = await review(
          game('stale2', moves: '1. Qf7 1/2-1/2', result: '1/2-1/2', fen: fen),
        );

        expect(
          reviewed[key('stale2')],
          const ReviewCounts(inaccuracies: 0, mistakes: 0, blunders: 1),
        );
        expect(result.positions.single.userMove, 'Qf7');
        expect(result.positions.single.correctLine, ['Qf8#']);
      },
      skip:
          'documents bug: a game-ending draw (stalemate, insufficient '
          'material) from a winning position is counted as clean and never '
          'mined',
    );
  });
}
