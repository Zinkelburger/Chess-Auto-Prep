/// Headless repertoire build with the master-games book wired in.
///
/// The real pipeline — Stockfish + Maia ONNX + the TWIC book — run from the
/// command line, so a long build can happen while nobody is watching.  Named
/// without a `_test` suffix so a bare `flutter test` (and CI) never runs it.
/// Sibling of `fast_vs_pure_benchmark.dart`, which this borrows its sandbox
/// and Maia warm-up from; the difference is the `masterBook` handed to
/// [TreeBuildService.build] and the PGN written at the end.
///
/// Requires `LD_LIBRARY_PATH` to include the onnxruntime shared library
/// (`build/linux/x64/debug/bundle/lib`) so Maia loads under flutter_tester.
///
///   flutter test test/benchmark/master_build_overnight.dart \
///     --dart-define=OUT=/tmp/run --dart-define=DB=…/master_games.db \
///     --dart-define=START_MOVES="d4 Nf6 c4 c5 d5 b5 cxb5 a6 bxa6 e6"
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/course/master_improvements.dart';
import 'package:chess_auto_prep/services/generation/course/model_game_selector.dart';
import 'package:chess_auto_prep/services/generation/snapshot_export.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_prune.dart';
import 'package:chess_auto_prep/services/generation/tree_my_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_model_games.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show fenAfterMoves;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _out = String.fromEnvironment('OUT');
const _db = String.fromEnvironment('DB');

/// Space-separated SAN moves played before the build root.  Empty = start.
const _startMoves = String.fromEnvironment('START_MOVES', defaultValue: '');
const _playAsWhite = bool.fromEnvironment('PLAY_WHITE', defaultValue: true);
const _maxPly = int.fromEnvironment('MAX_PLY', defaultValue: 14);
const _evalDepth = int.fromEnvironment('EVAL_DEPTH', defaultValue: 16);
const _threads = int.fromEnvironment('THREADS', defaultValue: 16);
const _budgetMin = int.fromEnvironment('BUDGET_MIN', defaultValue: 300);
const _multipv = int.fromEnvironment('MULTIPV', defaultValue: 4);
const _maiaElo = int.fromEnvironment('MAIA_ELO', defaultValue: 2200);
const _minEvalCp = int.fromEnvironment('MIN_EVAL_CP', defaultValue: -20);
const _pure = bool.fromEnvironment('PURE', defaultValue: false);
const _modelGames = int.fromEnvironment('MODEL_GAMES', defaultValue: 6);
const _masterPriorityWeight = String.fromEnvironment(
  'MASTER_PRIORITY_WEIGHT',
  defaultValue: '0.35',
);

class _SandboxPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _SandboxPathProvider({required this.documents, required this.support});
  final String documents;
  final String support;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

String get _home => Platform.environment['HOME']!;
String get _realSupportPath =>
    p.join(_home, '.local', 'share', 'com.example.chess_auto_prep');

void _say(String s) {
  stdout.writeln('[mgb] ${DateTime.now().toIso8601String()} $s');
}

void main() {
  // Without the binding, rootBundle has no ServicesBinding and the Maia
  // model asset fails to load — inside MaiaService's catch, so the build
  // only dies later with "Maia not initialized".
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues({});
    // No HttpOverrides reset here on purpose: this build reaches no network
    // (see the config below). A harness that does needs `HttpOverrides.global
    // = null`, or the binding's mock answers every request with an empty 400
    // — see `chessdb_book_build.dart`.
  });

  test('build with the master book', () async {
    if (_out.isEmpty) fail('OUT dart-define is required');
    if (_db.isEmpty) fail('DB dart-define is required');

    final outDir = Directory(_out)..createSync(recursive: true);
    final support = Directory(p.join(outDir.path, 'support'))
      ..createSync(recursive: true);
    final docs = Directory(p.join(outDir.path, 'docs'))
      ..createSync(recursive: true);

    // Only the engine binary is borrowed from the real app-support dir; the
    // caches this run fills are its own.
    final realBinary = File(p.join(_realSupportPath, 'stockfish-linux'));
    if (!realBinary.existsSync()) {
      fail('Stockfish binary not found at ${realBinary.path}');
    }
    final link = Link(p.join(support.path, 'stockfish-linux'));
    if (!link.existsSync()) link.createSync(realBinary.path);
    PathProviderPlatform.instance = _SandboxPathProvider(
      documents: docs.path,
      support: support.path,
    );

    // Read-only: the downloader owns the file, and a build must never be the
    // reason the database changes.
    final book = MasterGamesDb.open(_db, readOnly: true);
    final stats = book.stats();
    _say('master book: ${stats.games} games, ${stats.issues} issues');
    if (stats.games == 0) fail('master database is empty — download first');

    final sans = _startMoves.trim().isEmpty
        ? const <String>[]
        : _startMoves.trim().split(RegExp(r'\s+'));
    final startFen = fenAfterMoves(kStandardStartFen, sans, sans.length - 1);
    final config = TreeBuildConfig(
      startFen: startFen,
      playAsWhite: _playAsWhite,
      searchAlgorithm: _pure ? SearchAlgorithm.pure : SearchAlgorithm.fast,
      maxPly: _maxPly,
      evalDepth: _evalDepth,
      engineThreads: _threads,
      timeBudgetMinutes: _budgetMin,
      ourMultipv: _multipv,
      maiaElo: _maiaElo,
      minEvalCp: _minEvalCp,
      verifyFinal: false,
      useMasterGames: true,
      // Nothing that reaches the network / external eval sources.
      enableChessDbApi: false,
      enableCdbDirect: false,
      enableLocalChessDb: false,
      modelGameCount: _modelGames,
      masterPriorityWeight: double.parse(_masterPriorityWeight),
    );
    _say('root after "${sans.join(' ')}" = $startFen');
    _say('config ${jsonEncode(config.toJson())}');
    final rootBook = book.bookMoves(startFen);
    _say(
      'book at root: ${rootBook.length} moves '
      '${rootBook.take(5).map((m) => '${m.uci}(${m.games})').join(' ')}',
    );

    // Maia's one-off model load, kept off the build clock.
    await MaiaFactory.instance!.initialize();
    final probe = await MaiaFactory.instance!.evaluate(startFen, _maiaElo);
    if (probe.policy.isEmpty) fail('Maia returned an empty policy');
    _say('maia ready, ${probe.policy.length} policy entries at root');

    final service = TreeBuildService();
    var lastReport = 0;
    final wall = Stopwatch()..start();
    final tree = await service.build(
      config: config,
      isCancelled: () => false,
      masterBook: book.bookMoves,
      onProgress: (bp) {
        final now = wall.elapsedMilliseconds;
        if (now - lastReport < 60000) return;
        lastReport = now;
        _say(
          'progress ${(now / 60000).toStringAsFixed(1)}min '
          'nodes=${bp.totalNodes} maxPly=${bp.maxPlyReached} '
          'frontier=${bp.frontierSize} depth=${bp.currentDepth} '
          'sf=${service.buildStats.sfMultipvCalls}',
        );
      },
    );
    wall.stop();
    File(
      p.join(outDir.path, 'run.log'),
    ).writeAsStringSync(service.runLog.dump());
    _say(
      'build done: ${tree.totalNodes} nodes, maxPly ${tree.maxPlyReached}, '
      'complete=${tree.buildComplete}, '
      '${(wall.elapsedMilliseconds / 60000).toStringAsFixed(1)}min',
    );

    // Phase 2, exactly as GenerationSessionController._analyzeTreePhase.
    final p2 = Stopwatch()..start();
    // Phase 2 judges nodes against the *root-anchored* window, exactly as
    // the controller does. Without this the window stays an absolute
    // [minEvalCp, maxEvalCp] from our side, which quietly selects nothing
    // whenever our side starts out worse than minEvalCp — the whole Black
    // side of a gambit, for instance.
    final anchored = config.anchoredToRoot(tree.root);
    _say(
      'eval window: raw [${config.minEvalCp}, ${config.maxEvalCp}] → '
      'anchored [${anchored.minEvalCp}, ${anchored.maxEvalCp}] '
      '(root eval for us ${tree.root.evalForUs(config.playAsWhite)}cp)',
    );
    calculateTreeEase(tree);
    final fenMap = FenMap()..populate(tree.root);
    final eca = ExpectimaxCalculator(config: anchored, fenMap: fenMap);
    eca.calculate(tree);
    eca.computeTrapScores(tree.root);
    eca.calculateCplValues(tree.root);
    calculateMyEase(tree, playAsWhite: anchored.playAsWhite);
    final selected = RepertoireSelector(
      config: anchored,
      ecaCalc: eca,
      fenMap: fenMap,
    ).select(tree);
    p2.stop();
    _say(
      'phase2: root V=${tree.root.expectimaxValue.toStringAsFixed(4)}, '
      '$selected selected, ${p2.elapsedMilliseconds}ms',
    );

    // The very lines the PGN is written from, so the improvement prober
    // judges what the user will actually see rather than every raw leaf.
    final exported = snapshotLines(tree: tree, config: config, fenMap: fenMap);

    // What the build threw away.  Both lists are gone from the tree by the
    // time it is returned, so without these files "was this line ever
    // generated?" cannot be answered from tree.json alone.
    void dumpPruned(String name, List<PrunedLine> lines, String what) {
      final sorted = [...lines]
        ..sort((a, b) => b.subtreeNodes.compareTo(a.subtreeNodes));
      File(p.join(outDir.path, name)).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'what': what,
          'count': sorted.length,
          'nodes_removed': sorted.fold<int>(0, (n, l) => n + l.subtreeNodes),
          'lines': [for (final l in sorted) l.toJson()],
        }),
      );
      _say(
        '$name: ${sorted.length} lines, '
        '${sorted.fold<int>(0, (n, l) => n + l.subtreeNodes)} nodes',
      );
    }

    dumpPruned(
      'pruned_too_low.json',
      service.lastPrunedTooLow,
      'subtrees deleted after the build because the eval at build depth fell '
          'outside [minEvalCp, maxEvalCp] relative to the root',
    );
    dumpPruned(
      'removed_uncovered.json',
      service.lastRemovedUncovered,
      'leaves deleted by the coverage sweep: the opponent had just moved, we '
          'had no reply, and the position was under coverMinProb',
    );

    // Phase 3.8 before 3.6 and before the PGN on purpose: the improvements
    // decide which games get the reserved model-game slots, and the notes
    // they carry belong in the written lines.
    final prober = MasterImprovementProber(
      config: config,
      book: book.bookMoves,
      gameById: book.game,
    );
    final sites = prober.sites(exported);
    _say('improvement sites: ${sites.length}');
    var improvements = <String, MasterImprovement>{};
    if (sites.isNotEmpty) {
      if (StockfishPool.instance.workerCount == 0) {
        await StockfishPool.instance.prepareForTreeBuild(
          config.resolvedEngineThreads,
        );
      }
      improvements = Map.of(await prober.probe(exported));
      _say('improvements found: ${improvements.length}');
      for (final imp in improvements.values.take(5)) {
        _say('  ${imp.note} (+${imp.gainCp}cp)');
      }
    }

    // Phase 3: the lines themselves, through the same extract → prune →
    // write pass the app runs, so what gets reviewed is what a build would
    // hand the user.  The raw extractor alone wrote every leaf — 602 lines
    // for a tree the app's coverage pruning reduces to 149, three quarters
    // of them siblings differing only in the opponent's last move.
    final entries = extractSnapshotLines(
      tree: tree,
      config: config,
      fenMap: fenMap,
      prefix: sans,
      repertoireStartFen: kStandardStartFen,
      improvements: improvements,
    );
    File(
      p.join(outDir.path, 'repertoire.pgn'),
    ).writeAsStringSync(entries.join('\n\n'));
    _say(
      'phase3: ${entries.length} lines written to repertoire.pgn, '
      '${improvements.length} improvement notes attached',
    );

    final modelGames = ModelGameSelector(playAsWhite: config.playAsWhite)
        .select(
          masterGameCandidates(
            book,
            tree,
            playAsWhite: config.playAsWhite,
            minElo: config.modelGameMinElo,
          ),
          tree,
          limit: config.modelGameCount,
          fenMap: fenMap,
          improvedFens: improvements.keys.toSet(),
        );
    _say(
      'model games: ${modelGames.length} of ${config.modelGameCount} '
      'asked for',
    );
    for (final g in modelGames.take(6)) {
      final dep = g.departure;
      final improved = dep != null && improvements.containsKey(dep.fenBefore);
      _say(
        '  ${g.record.white} — ${g.record.black} '
        '(${g.record.outcome?.name ?? '?'}), '
        'followed ${g.followedPlies} plies'
        '${improved ? ' [we improve on it]' : ''}',
      );
    }

    File(p.join(outDir.path, 'master_practice.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'model_games': [
          for (final g in modelGames)
            {
              'white': g.record.white,
              'black': g.record.black,
              'result': g.record.outcome?.name,
              'followed_plies': g.followedPlies,
            },
        ],
        'improvement_sites': sites.length,
        'improvements': [
          for (final e in improvements.entries)
            {
              'fen': e.key,
              'note': e.value.note,
              'gain_cp': e.value.gainCp,
              'master_san': e.value.masterSan,
              'master_games': e.value.masterGames,
              'continuation': e.value.continuation,
            },
        ],
      }),
    );

    final perPly = <int>[];
    void count(BuildTreeNode n) {
      while (perPly.length <= n.ply) {
        perPly.add(0);
      }
      perPly[n.ply]++;
      for (final c in n.children) {
        count(c);
      }
    }

    count(tree.root);

    File(
      p.join(outDir.path, 'tree.json'),
    ).writeAsStringSync(serializeTree(tree));
    File(p.join(outDir.path, 'stats.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'config': config.toJson(),
        'start_moves': sans,
        'start_fen': startFen,
        'master_games': stats.games,
        'master_issues': stats.issues,
        'book_moves_at_root': rootBook.length,
        'build_ms': wall.elapsedMilliseconds,
        'phase2_ms': p2.elapsedMilliseconds,
        'build_stats': service.buildStats.toJson(),
        'total_nodes': tree.totalNodes,
        'max_ply_reached': tree.maxPlyReached,
        'build_complete': tree.buildComplete,
        'root_v': tree.root.expectimaxValue,
        'root_eval_for_us': tree.root.evalForUs(config.playAsWhite),
        'eval_window_anchored': [anchored.minEvalCp, anchored.maxEvalCp],
        'selected': selected,
        'lines': entries.length,
        'model_games': modelGames.length,
        'improvement_sites': sites.length,
        'improvements': improvements.length,
        'pruned_too_low': service.lastPrunedTooLow.length,
        'removed_uncovered': service.lastRemovedUncovered.length,
        'per_ply': perPly,
      }),
    );
    _say(
      'wrote ${outDir.path}/{tree.json,stats.json,repertoire.pgn,'
      'run.log,pruned_too_low.json,removed_uncovered.json}',
    );
    book.close();
  }, timeout: const Timeout(Duration(hours: 14)));
}
