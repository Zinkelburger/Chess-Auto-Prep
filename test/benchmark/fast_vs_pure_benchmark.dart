/// Fast-vs-Pure Expectimax experiment harness.
///
/// Deliberately named without a `_test` suffix so a bare `flutter test`
/// (and CI) never runs it.  Driven by
/// `tools/experiments/fast_vs_pure/run_overnight.sh`, which runs one
/// `flutter test` process per phase:
///
///   MODE=build   ALGO=fast|pure  OUT=dir   — build a tree with the real
///                pipeline (Stockfish + Maia ONNX, phase 1 → phase 2 selection,
///                no deep verify), save `tree.json` + `stats.json`.
///   MODE=compare FAST=dir PURE=dir OUT=dir — load both trees and
///                measure move-choice agreement, Pure-valued regret of Fast's
///                choices, and the incumbent-bias diagnostics.
///
/// Every setting arrives via `--dart-define`; see `_defs` below.  Each build
/// runs in its own sandbox support directory (fresh eval/Maia cache) so the
/// two timings are cold-cache comparable.  Only the Stockfish binary is
/// borrowed (symlinked) from the real app-support dir; real app data is never
/// touched.
///
/// Requires `LD_LIBRARY_PATH` to include the onnxruntime shared library
/// (`build/linux/x64/debug/bundle/lib`) so Maia loads under flutter_tester.
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_my_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show fenAfterMoves;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── dart-define inputs ───────────────────────────────────────────────────

const _mode = String.fromEnvironment('MODE', defaultValue: 'build');
const _algo = String.fromEnvironment('ALGO', defaultValue: 'fast');
const _out = String.fromEnvironment('OUT', defaultValue: '');
const _fastDir = String.fromEnvironment('FAST', defaultValue: '');
const _pureDir = String.fromEnvironment('PURE', defaultValue: '');

/// Space-separated SAN moves played before the build root.  Empty = start.
const _startMoves = String.fromEnvironment('START_MOVES', defaultValue: '');
const _playAsWhite = bool.fromEnvironment('PLAY_WHITE', defaultValue: true);
const _maxPly = int.fromEnvironment('MAX_PLY', defaultValue: 10);
const _evalDepth = int.fromEnvironment('EVAL_DEPTH', defaultValue: 14);
const _threads = int.fromEnvironment('THREADS', defaultValue: 6);
const _budgetMin = int.fromEnvironment('BUDGET_MIN', defaultValue: 0);
const _multipv = int.fromEnvironment('MULTIPV', defaultValue: 4);
const _maiaElo = int.fromEnvironment('MAIA_ELO', defaultValue: 2200);

/// Eval-window floor relative to the root eval.  The app default (0) lets
/// root-eval noise prune every root child at shallow depths (observed:
/// root +47, best child +30 → empty tree), which would waste a run; the
/// experiment widens it symmetrically for both algorithms.
const _minEvalCp = int.fromEnvironment('MIN_EVAL_CP', defaultValue: -20);

// ── sandbox path provider ────────────────────────────────────────────────

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
  stdout.writeln('[fvp] $s');
}

// ── build phase ──────────────────────────────────────────────────────────

TreeBuildConfig _buildConfig() {
  final sans = _startMoves.trim().isEmpty
      ? const <String>[]
      : _startMoves.trim().split(RegExp(r'\s+'));
  final startFen = fenAfterMoves(kStandardStartFen, sans, sans.length - 1);
  return TreeBuildConfig(
    startFen: startFen,
    playAsWhite: _playAsWhite,
    searchAlgorithm: _algo == 'pure'
        ? SearchAlgorithm.pure
        : SearchAlgorithm.fast,
    maxPly: _maxPly,
    evalDepth: _evalDepth,
    engineThreads: _threads,
    timeBudgetMinutes: _budgetMin,
    ourMultipv: _multipv,
    maiaElo: _maiaElo,
    minEvalCp: _minEvalCp,
    verifyFinal: false,
    // Nothing that reaches the network / external eval sources.
    enableChessDbApi: false,
    enableCdbDirect: false,
    enableLocalChessDb: false,
    modelGameCount: 0,
  );
}

Future<void> _runBuild() async {
  if (_out.isEmpty) fail('OUT dart-define is required in build mode');
  final outDir = Directory(_out)..createSync(recursive: true);
  final support = Directory(p.join(outDir.path, 'support'))
    ..createSync(recursive: true);
  final docs = Directory(p.join(outDir.path, 'docs'))
    ..createSync(recursive: true);

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

  final config = _buildConfig();
  _say('build algo=$_algo config=${jsonEncode(config.toJson())}');

  // Load Maia up front so its one-off model load is not charged to the
  // build clock (both runs pay it identically anyway).
  final maiaSw = Stopwatch()..start();
  await MaiaFactory.instance!.initialize();
  final probe = await MaiaFactory.instance!.evaluate(config.startFen, _maiaElo);
  maiaSw.stop();
  if (probe.policy.isEmpty) fail('Maia returned an empty policy — not loaded');
  _say(
    'maia ready in ${maiaSw.elapsedMilliseconds}ms, '
    '${probe.policy.length} policy entries at root',
  );

  final service = TreeBuildService();
  var lastReport = 0;
  final wall = Stopwatch()..start();
  final tree = await service.build(
    config: config,
    isCancelled: () => false,
    onProgress: (bp) {
      final now = wall.elapsedMilliseconds;
      if (now - lastReport < 30000) return;
      lastReport = now;
      _say(
        'progress ${(now / 60000).toStringAsFixed(1)}min '
        'nodes=${bp.totalNodes} maxPly=${bp.maxPlyReached} '
        'frontier=${bp.frontierSize} '
        'depth=${bp.currentDepth} '
        'sf=${service.buildStats.sfMultipvCalls}',
      );
    },
  );
  wall.stop();
  final buildMs = wall.elapsedMilliseconds;
  File(p.join(outDir.path, 'run.log')).writeAsStringSync(service.runLog.dump());
  if (tree.totalNodes < 20) {
    fail(
      'Degenerate tree (${tree.totalNodes} nodes) — root eval '
      '${tree.root.engineEvalCp}cp probably pruned every child; '
      'see ${outDir.path}/run.log',
    );
  }
  final searches =
      service.buildStats.sfMultipvCalls + service.buildStats.sfSingleCalls;
  _say(
    'build done: ${tree.totalNodes} nodes, maxPly ${tree.maxPlyReached}, '
    'complete=${tree.buildComplete}, ${(buildMs / 60000).toStringAsFixed(1)}min, '
    '$searches searches',
  );

  // Phase 2 exactly as GenerationSessionController._analyzeTreePhase.
  final p2 = Stopwatch()..start();
  // Against the root-anchored window, as the controller does it. With the
  // raw window, a root where our side is worse than minEvalCp selects
  // nothing at all — the Black side of any gambit scores zero moves and the
  // comparison silently measures empty trees.
  final anchored = config.anchoredToRoot(tree.root);
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
    'phase2 done: root V=${tree.root.expectimaxValue.toStringAsFixed(4)}, '
    '$selected selected, ${p2.elapsedMilliseconds}ms',
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

  File(p.join(outDir.path, 'tree.json')).writeAsStringSync(serializeTree(tree));
  File(p.join(outDir.path, 'stats.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'algo': _algo,
      'config': config.toJson(),
      'start_fen': config.startFen,
      'build_ms': buildMs,
      'phase2_ms': p2.elapsedMilliseconds,
      'searches': searches,
      'build_stats': service.buildStats.toJson(),
      'total_nodes': tree.totalNodes,
      'max_ply_reached': tree.maxPlyReached,
      'build_complete': tree.buildComplete,
      'root_v': tree.root.expectimaxValue,
      'selected': selected,
      'per_ply': perPly,
    }),
  );
  _say('wrote ${outDir.path}/tree.json + stats.json');
}

// ── compare phase ────────────────────────────────────────────────────────

class _Loaded {
  _Loaded(this.dir, this.tree, this.stats, this.config);
  final String dir;
  final BuildTree tree;
  final Map<String, dynamic> stats;
  final TreeBuildConfig config;

  /// FEN → canonical our-move node (the one with children, else any).
  late final Map<String, BuildTreeNode> ourNodes = _index();

  Map<String, BuildTreeNode> _index() {
    final m = <String, BuildTreeNode>{};
    void walk(BuildTreeNode n) {
      if (n.isWhiteToMove == config.playAsWhite) {
        final prev = m[n.fen];
        if (prev == null || (prev.children.isEmpty && n.children.isNotEmpty)) {
          m[n.fen] = n;
        }
      }
      for (final c in n.children) {
        walk(c);
      }
    }

    walk(tree.root);
    return m;
  }
}

_Loaded _load(String dir) {
  final stats =
      jsonDecode(File(p.join(dir, 'stats.json')).readAsStringSync())
          as Map<String, dynamic>;
  final configJson = stats['config'] as Map<String, dynamic>;
  final config = TreeBuildConfig.fromJson(
    configJson,
    startFen: stats['start_fen'] as String? ?? kStandardStartFen,
  );
  final tree = deserializeTree(
    File(p.join(dir, 'tree.json')).readAsStringSync(),
  );
  return _Loaded(dir, tree, stats, config);
}

BuildTreeNode? _chosen(BuildTreeNode n) {
  for (final c in n.children) {
    if (c.isRepertoireMove) return c;
  }
  return null;
}

BuildTreeNode? _engineBest(BuildTreeNode n, bool white) {
  BuildTreeNode? best;
  var bestCp = -1 << 30;
  for (final c in n.children) {
    if (!c.hasEngineEval) continue;
    final cp = c.evalForUs(white);
    if (best == null || cp > bestCp) {
      best = c;
      bestCp = cp;
    }
  }
  return best;
}

String _zone(double cumP) =>
    cumP >= 0.02 ? 'hot' : (cumP >= 0.002 ? 'warm' : 'cold');

class _Acc {
  int nodes = 0;
  double mass = 0;
  int agree = 0;
  double agreeMass = 0;
  int fastMissingInPure = 0;
  double regretMass = 0; // Σ cumP × (V_P(m_P) − V_P(m_F)) over disagreements
  double regretMax = 0;
  int disagreeFastIsEngineBest = 0;
  int disagreePureIsEngineBest = 0;
  int disagreeFastChoiceIsFastIncumbent = 0;
  int fastChosenIsIncumbent = 0;
  int fastChosenDeeperThanAlts = 0;
  int fastNodesWithAlts = 0;
  final List<Map<String, dynamic>> worst = [];

  Map<String, dynamic> toJson() => {
    'nodes': nodes,
    'reach_mass': mass,
    'agree': agree,
    'agree_rate': nodes == 0 ? null : agree / nodes,
    'agree_mass_rate': mass == 0 ? null : agreeMass / mass,
    'fast_choice_missing_in_pure': fastMissingInPure,
    'regret_mass_weighted': regretMass,
    'regret_per_reach': mass == 0 ? null : regretMass / mass,
    'regret_max': regretMax,
    'disagree_fast_is_engine_best': disagreeFastIsEngineBest,
    'disagree_pure_is_engine_best': disagreePureIsEngineBest,
    'disagree_fast_choice_is_fast_incumbent': disagreeFastChoiceIsFastIncumbent,
    'fast_chosen_is_incumbent': fastChosenIsIncumbent,
    'fast_nodes_with_alts': fastNodesWithAlts,
    'fast_chosen_deeper_than_alts': fastChosenDeeperThanAlts,
  };
}

Future<void> _runCompare() async {
  if (_fastDir.isEmpty || _pureDir.isEmpty || _out.isEmpty) {
    fail('FAST, PURE and OUT dart-defines are required in compare mode');
  }
  final fast = _load(_fastDir);
  final pure = _load(_pureDir);
  final white = pure.config.playAsWhite;

  final zones = {'hot': _Acc(), 'warm': _Acc(), 'cold': _Acc()};
  final all = _Acc();
  int fastOnly = 0;
  int pureOnly = 0;
  int sharedNoChoice = 0;

  for (final entry in pure.ourNodes.entries) {
    final pn = entry.value;
    final fn = fast.ourNodes[entry.key];
    if (fn == null) {
      pureOnly++;
      continue;
    }
    final pc = _chosen(pn);
    final fc = _chosen(fn);
    if (pc == null || fc == null) {
      sharedNoChoice++;
      continue;
    }
    final cumP = pn.cumulativeProbability;
    final accs = [all, zones[_zone(cumP)]!];

    // Incumbent in Fast = engine-best child at expansion time (recomputed
    // from stored evals; ties resolve like NodeExpander: first max).
    final fastIncumbent = _engineBest(fn, white);
    final fastIsIncumbent =
        fastIncumbent != null && identical(fastIncumbent, fc);
    var deeper = false;
    var hasAlts = false;
    for (final c in fn.children) {
      if (identical(c, fc)) continue;
      hasAlts = true;
      if (fc.subtreePly > c.subtreePly) deeper = true;
    }

    final agree = pc.moveUci == fc.moveUci;
    BuildTreeNode? fInPure;
    for (final c in pn.children) {
      if (c.moveUci == fc.moveUci) fInPure = c;
    }
    final regret = (!agree && fInPure != null)
        ? (pc.expectimaxValue - fInPure.expectimaxValue).clamp(0.0, 1.0)
        : 0.0;

    for (final a in accs) {
      a.nodes++;
      a.mass += cumP;
      if (fastIsIncumbent) a.fastChosenIsIncumbent++;
      if (hasAlts) a.fastNodesWithAlts++;
      if (hasAlts && deeper) a.fastChosenDeeperThanAlts++;
      if (agree) {
        a.agree++;
        a.agreeMass += cumP;
      } else {
        if (fInPure == null) {
          a.fastMissingInPure++;
        } else {
          a.regretMass += cumP * regret;
          if (regret > a.regretMax) a.regretMax = regret;
        }
        final pb = _engineBest(pn, white);
        if (pb != null && identical(pb, pc)) a.disagreePureIsEngineBest++;
        BuildTreeNode? fb;
        for (final c in pn.children) {
          if (fb == null ||
              (c.hasEngineEval && c.evalForUs(white) > (fb.evalForUs(white)))) {
            if (c.hasEngineEval) fb = c;
          }
        }
        if (fb != null && fb.moveUci == fc.moveUci) {
          a.disagreeFastIsEngineBest++;
        }
        if (fastIsIncumbent) a.disagreeFastChoiceIsFastIncumbent++;
        if (identical(a, all)) {
          a.worst.add({
            'fen': pn.fen,
            'ply': pn.ply,
            'cum_p': cumP,
            'pure_move': pc.moveSan,
            'pure_v': pc.expectimaxValue,
            'pure_eval': pc.evalForUs(white),
            'fast_move': fc.moveSan,
            'fast_v_in_fast': fc.expectimaxValue,
            'fast_move_v_in_pure': fInPure?.expectimaxValue,
            'fast_move_eval': fc.evalForUs(white),
            'regret': regret,
            'weighted_regret': cumP * regret,
            'fast_choice_is_incumbent': fastIsIncumbent,
          });
        }
      }
    }
  }
  for (final fen in fast.ourNodes.keys) {
    if (!pure.ourNodes.containsKey(fen)) fastOnly++;
  }
  all.worst.sort(
    (a, b) => (b['weighted_regret'] as double).compareTo(
      a['weighted_regret'] as double,
    ),
  );

  final report = {
    'fast': fast.stats..remove('config'),
    'pure': pure.stats..remove('config'),
    'shared_our_nodes': all.nodes,
    'shared_without_choice': sharedNoChoice,
    'pure_only_our_nodes': pureOnly,
    'fast_only_our_nodes': fastOnly,
    'all': all.toJson(),
    'zones': zones.map((k, v) => MapEntry(k, v.toJson())),
    'worst_disagreements': all.worst.take(40).toList(),
  };
  final outDir = Directory(_out)..createSync(recursive: true);
  File(
    p.join(outDir.path, 'compare.json'),
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));

  final md = StringBuffer()
    ..writeln('# Fast vs Pure Expectimax')
    ..writeln()
    ..writeln('| | Fast | Pure |')
    ..writeln('|---|---|---|');
  for (final k in [
    'build_ms',
    'searches',
    'total_nodes',
    'max_ply_reached',
    'build_complete',
    'root_v',
    'selected',
  ]) {
    md.writeln('| $k | ${fast.stats[k]} | ${pure.stats[k]} |');
  }
  md
    ..writeln()
    ..writeln(
      'Shared our-move nodes with a choice in both: ${all.nodes} '
      '(pure-only $pureOnly, fast-only $fastOnly, '
      'shared w/o choice $sharedNoChoice)',
    )
    ..writeln()
    ..writeln(
      '| zone (Pure reach) | nodes | reach mass | agree | agree (mass) | '
      'regret/reach | max regret | disagree: Fast=engine-best | '
      'disagree: Pure=engine-best | Fast choice = incumbent | '
      'Fast chosen deeper than alts |',
    )
    ..writeln('|---|---|---|---|---|---|---|---|---|---|---|');
  String pct(num? x) => x == null ? '-' : '${(x * 100).toStringAsFixed(1)}%';
  for (final e in [MapEntry('all', all), ...zones.entries]) {
    final a = e.value;
    final dis = a.nodes - a.agree;
    md.writeln(
      '| ${e.key} | ${a.nodes} | ${a.mass.toStringAsFixed(3)} | '
      '${pct(a.nodes == 0 ? null : a.agree / a.nodes)} | '
      '${pct(a.mass == 0 ? null : a.agreeMass / a.mass)} | '
      '${a.mass == 0 ? '-' : (a.regretMass / a.mass).toStringAsFixed(4)} | '
      '${a.regretMax.toStringAsFixed(3)} | '
      '${a.disagreeFastIsEngineBest}/$dis | ${a.disagreePureIsEngineBest}/$dis | '
      '${a.fastChosenIsIncumbent}/${a.nodes} | '
      '${a.fastChosenDeeperThanAlts}/${a.fastNodesWithAlts} |',
    );
  }
  md
    ..writeln()
    ..writeln('## Worst disagreements (by reach × regret, Pure valuation)')
    ..writeln()
    ..writeln(
      '| ply | reach | Pure move (V, eval) | Fast move (V in Pure, eval) | '
      'regret | Fast=incumbent | fen |',
    )
    ..writeln('|---|---|---|---|---|---|---|');
  for (final w in all.worst.take(25)) {
    md.writeln(
      '| ${w['ply']} | ${(w['cum_p'] as double).toStringAsFixed(4)} | '
      '${w['pure_move']} (${(w['pure_v'] as double).toStringAsFixed(3)}, '
      '${w['pure_eval']}) | ${w['fast_move']} '
      '(${(w['fast_move_v_in_pure'] as double?)?.toStringAsFixed(3) ?? 'n/a'}, '
      '${w['fast_move_eval']}) | '
      '${(w['regret'] as double).toStringAsFixed(3)} | '
      '${w['fast_choice_is_incumbent']} | `${w['fen']}` |',
    );
  }
  File(p.join(outDir.path, 'compare.md')).writeAsStringSync(md.toString());
  stdout.writeln(md);
  _say('wrote ${outDir.path}/compare.md + compare.json');
}

// ── entry ────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() {
    StockfishPool.instance.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('fast-vs-pure $_mode', () async {
    if (_mode == 'compare') {
      await _runCompare();
    } else {
      await _runBuild();
    }
  }, timeout: Timeout.none);
}
