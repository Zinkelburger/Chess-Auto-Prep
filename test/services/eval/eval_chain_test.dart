import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/eval/chessdb_api_provider.dart';
import 'package:chess_auto_prep/services/eval/eval_chain.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/eval/external_eval_provider.dart';
import 'package:chess_auto_prep/services/eval/in_memory_eval_provider.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'eval_test_helpers.dart';

void main() {
  const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

  setUpAll(() async {
    await initEvalTestSqlite();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EvalCache.instance.init();
    await EvalCache.instance.clear();
  });

  TreeBuildConfig baseConfig({int quota = 100}) => TreeBuildConfig(
    startFen: fen,
    playAsWhite: true,
    enableLocalChessDb: true,
    enableChessDbApi: true,
    chessDbApiDailyQuota: quota,
    enableExtEvalSubtreeSkip: true,
    evalDepth: 20,
    minAcceptableEvalDepth: 18,
  );

  Future<({int stmCp, int depth})> fakeStockfish(String f, int depth) async {
    return (stmCp: 7, depth: depth);
  }

  test('precedence: project cache wins over external sources', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    await cache.init();
    await cache.putEvalCpWhite(fen, 99, 20);

    final local = InMemoryEvalProvider()
      ..put(fen, const EvalHit(cp: 50, depth: 20));
    final api = ChessDbApiProvider(
      httpFetch: (_) async => http.Response('eval:40', 200),
    );
    await api.init();

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig(),
      cache: cache,
      stats: stats,
      localEvalProvider: local,
      chessDbApi: api,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.source, EvalChainSource.projectCache);
    expect(outcome.whiteCp, 99);
    expect(stats.localChessDbHits, 0);
    expect(stats.chessDbApiHits, 0);
  });

  test('precedence: local DB used when cache misses', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    final local = InMemoryEvalProvider()
      ..put(fen, const EvalHit(cp: 44, depth: 20));

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig(),
      cache: cache,
      stats: stats,
      localEvalProvider: local,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.source, EvalChainSource.localChessDb);
    expect(outcome.whiteCp, 44);
  });

  test('precedence: API used when cache and local miss', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    final api = ChessDbApiProvider(
      httpFetch: (_) async => http.Response('eval:33', 200),
    );
    await api.init();

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig().copyWith(enableLocalChessDb: false),
      cache: cache,
      stats: stats,
      chessDbApi: api,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.source, EvalChainSource.chessDbApi);
    expect(outcome.whiteCp, -33);
  });

  test('the Lichess store answers after the ChessDB dump', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    final local = InMemoryEvalProvider()
      ..put(fen, const EvalHit(cp: 44, depth: 20));
    final lichess = InMemoryEvalProvider()
      ..put(fen, const EvalHit(cp: 12, depth: 40));

    final config = baseConfig().copyWith(enableLichessEvals: true);

    // With both on, the broader database wins.
    final both = await resolveEvalChain(
      fen: fen,
      config: config,
      cache: cache,
      stats: stats,
      localEvalProvider: local,
      lichessEvals: lichess,
      stockfishEval: fakeStockfish,
    );
    expect(both.source, EvalChainSource.localChessDb);

    await cache.clear();

    // With ChessDB off, the Lichess store answers instead of the engine.
    final alone = await resolveEvalChain(
      fen: fen,
      config: config.copyWith(enableLocalChessDb: false),
      cache: cache,
      stats: stats,
      lichessEvals: lichess,
      stockfishEval: fakeStockfish,
    );
    expect(alone.source, EvalChainSource.lichessEvals);
    expect(alone.whiteCp, 12);
    expect(stats.lichessEvalHits, 1);
  });

  test('a Lichess miss does not skip the subtree', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    // Nothing in it: 394 million positions is a small fraction of what a
    // build asks about, so a miss here must not stand in for "ChessDB has
    // never heard of this line".
    final lichess = InMemoryEvalProvider();
    final api = ChessDbApiProvider(
      httpFetch: (_) async => http.Response('eval:33', 200),
    );
    await api.init();

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig().copyWith(
        enableLocalChessDb: false,
        enableLichessEvals: true,
      ),
      cache: cache,
      stats: stats,
      lichessEvals: lichess,
      chessDbApi: api,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.source, EvalChainSource.chessDbApi);
    expect(outcome.extEvalMode, isNot(ExtEvalMode.skipExternal));
    expect(stats.extEvalSubtreeSkips, 0);
    expect(stats.lichessEvalMisses, 1);
  });

  test('falls back to Stockfish when all external sources miss', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    final api = ChessDbApiProvider(
      httpFetch: (_) async => http.Response('unknown', 200),
    );
    await api.init();

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig().copyWith(
        enableLocalChessDb: false,
        enableExtEvalSubtreeSkip: false,
      ),
      cache: cache,
      stats: stats,
      chessDbApi: api,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.source, EvalChainSource.stockfish);
    expect(outcome.whiteCp, -7);
  });

  test('hard miss sets skip external mode for subtree', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    final local = InMemoryEvalProvider();
    final api = ChessDbApiProvider(
      httpFetch: (_) async => http.Response('eval:1', 200),
    );
    await api.init();

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig(),
      cache: cache,
      stats: stats,
      localEvalProvider: local,
      chessDbApi: api,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.extEvalMode, ExtEvalMode.skipExternal);
    expect(stats.localChessDbHardMisses, 1);
    expect(stats.extEvalSubtreeSkips, 1);
  });

  test('skip flag prevents API after hard miss', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    var apiCalled = false;
    final api = ChessDbApiProvider(
      httpFetch: (_) async {
        apiCalled = true;
        return http.Response('eval:1', 200);
      },
    );
    await api.init();

    await resolveEvalChain(
      fen: fen,
      config: baseConfig(),
      cache: cache,
      stats: stats,
      chessDbApi: api,
      extEvalMode: ExtEvalMode.skipExternal,
      stockfishEval: fakeStockfish,
    );

    expect(apiCalled, isFalse);
    expect(stats.chessDbApiHits, 0);
  });

  test('quota exhaustion skips API and uses Stockfish', () async {
    SharedPreferences.setMockInitialValues({
      'chessdb_api_quota_date':
          '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}',
      'chessdb_api_quota_count': 10,
    });

    final stats = BuildStats();
    final cache = EvalCache.instance;
    final api = ChessDbApiProvider(
      dailyQuota: 10,
      httpFetch: (_) async => http.Response('eval:5', 200),
    );
    await api.init();

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig(quota: 10),
      cache: cache,
      stats: stats,
      chessDbApi: api,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.source, EvalChainSource.stockfish);
    expect(stats.chessDbApiQuotaBlocked, 1);
  });

  test('transposition reuses canonical eval', () async {
    final stats = BuildStats();
    final cache = EvalCache.instance;
    final canonical = BuildTreeNode(
      fen: fen,
      moveSan: '',
      moveUci: '',
      ply: 1,
      isWhiteToMove: false,
      nodeId: 1,
    )..engineEvalCp = -12;

    final outcome = await resolveEvalChain(
      fen: fen,
      config: baseConfig(),
      cache: cache,
      stats: stats,
      canonicalNode: canonical,
      stockfishEval: fakeStockfish,
    );

    expect(outcome.source, EvalChainSource.transposition);
    expect(outcome.whiteCp, 12);
    expect(stats.transpositionEvalHits, 1);
  });
}
