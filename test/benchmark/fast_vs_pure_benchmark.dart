/// Opt-in real-engine benchmark. Run through the bounded driver:
/// tools/experiments/fast_vs_pure/run_overnight.sh [output-directory]
/// Each invocation has fresh Stockfish processes and disposable app storage.
/// No `_test` suffix: ordinary CI must not launch this experiment.
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show fenAfterMoves;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _algo = String.fromEnvironment('ALGO', defaultValue: 'fast');
const _out = String.fromEnvironment('OUT');
const _fen = String.fromEnvironment('FEN', defaultValue: kStandardStartFen);
const _moves = String.fromEnvironment('START_MOVES');
const _white = bool.fromEnvironment('PLAY_WHITE', defaultValue: true);
const _plies = int.fromEnvironment('MAX_PLY', defaultValue: 6);
const _depth = int.fromEnvironment('EVAL_DEPTH', defaultValue: 8);
const _seconds = int.fromEnvironment('BUDGET_SECONDS', defaultValue: 90);
const _loss = int.fromEnvironment('MAX_EVAL_LOSS', defaultValue: 40);
const _database = String.fromEnvironment('MASTER_DB');

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => p.join(root, 'docs');
  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'support');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('$_algo actual finite-horizon benchmark', () async {
    expect(_out, isNotEmpty);
    expect(['pure', 'fast'], contains(_algo));
    expect(_seconds, greaterThan(0));
    final output = Directory(_out)..createSync(recursive: true);
    for (final dir in ['support', 'docs']) {
      Directory(p.join(output.path, dir)).createSync();
    }
    final home = Platform.environment['HOME']!;
    final binary = p.join(
      home,
      '.local/share/com.example.chess_auto_prep/stockfish-linux',
    );
    expect(
      File(binary).existsSync(),
      isTrue,
      reason: 'Install Stockfish first',
    );
    Link(p.join(_out, 'support/stockfish-linux')).createSync(binary);
    PathProviderPlatform.instance = _Paths(output.path);
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final masterDb = _database.isEmpty
        ? null
        : MasterGamesDb.open(_database, readOnly: true);
    final sans = _moves.trim().isEmpty
        ? <String>[]
        : _moves.trim().split(RegExp(r'\s+'));
    final fen = sans.isEmpty
        ? _fen
        : fenAfterMoves(_fen, sans, sans.length - 1);
    final config = TreeBuildConfig(
      startFen: fen,
      playAsWhite: _white,
      searchAlgorithm: _algo == 'fast'
          ? SearchAlgorithm.rolling
          : SearchAlgorithm.pure,
      maxPly: _plies,
      evalDepth: _depth,
      maxEvalLossCp: _loss,
      engineThreads: 1,
      maiaElo: 2200,
      useMasterGames: masterDb != null,
      verifyFinal: false,
      enableChessDbApi: false,
      enableCdbDirect: false,
      enableLocalChessDb: false,
      modelGameCount: 0,
    );
    try {
      // Exclude model/process startup consistently. Each run starts cold;
      // Stockfish's ordinary within-run hash reuse is left enabled.
      final startup = Stopwatch()..start();
      final maia = MaiaFactory.instance!;
      await maia.initialize();
      expect((await maia.evaluate(fen, 2200)).policy, isNotEmpty);
      await StockfishPool.instance.prepareForTreeBuild(1);
      startup.stop();
      var bookHits = 0;
      var bookMisses = 0;
      List<BookMove> lookup(String fen) {
        final moves = masterDb!.bookMoves(fen);
        if (moves.isEmpty) {
          bookMisses++;
        } else {
          bookHits++;
        }
        return moves;
      }

      final service = TreeBuildService();
      final wall = Stopwatch()..start();
      var lastReport = 0;
      final tree = await service.build(
        config: config,
        masterBook: masterDb == null ? null : lookup,
        isCancelled: () => false,
        finishNow: () => wall.elapsed.inSeconds >= _seconds,
        onProgress: (progress) {
          if (wall.elapsed.inSeconds - lastReport >= 20) {
            lastReport = wall.elapsed.inSeconds;
            stdout.writeln(
              '[fvp] $_algo ${lastReport}s nodes=${progress.totalNodes}',
            );
          }
        },
      );
      wall.stop();
      expect(
        tree.configSnapshot['search_algorithm'],
        _algo == 'fast' ? 'rolling' : 'pure',
      );
      final calc = ExpectimaxCalculator(config: config)..calculate(tree);
      RepertoireSelector(config: config, ecaCalc: calc).select(tree);
      if (tree.buildComplete) {
        expect(tree.root.valueLower, closeTo(tree.root.valueUpper, 1e-12));
      }
      final decisions = <String, String>{};
      void visit(BuildTreeNode node, String path) {
        if (node.isWhiteToMove == _white &&
            node.terminalValue == null &&
            node.ply < _plies) {
          final selected = node.children
              .where((child) => child.isRepertoireMove)
              .firstOrNull;
          if (selected != null) decisions[path] = selected.moveUci;
        }
        for (final child in node.children) {
          visit(child, '$path ${child.moveUci}'.trim());
        }
      }

      visit(tree.root, '');
      final stats = {
        'algorithm': _algo,
        'start_fen': fen,
        'config': tree.configSnapshot,
        'budget_seconds': _seconds,
        'startup_ms': startup.elapsedMilliseconds,
        'build_ms': wall.elapsedMilliseconds,
        'complete': tree.buildComplete,
        'nodes': tree.totalNodes,
        'engine_calls':
            service.buildStats.sfSingleCalls +
            service.buildStats.sfMultipvCalls,
        'master_book_hits': bookHits,
        'master_book_misses': bookMisses,
        'root_move': decisions[''],
        'root_value': tree.root.expectimaxValue,
        'root_lower': tree.root.valueLower,
        'root_upper': tree.root.valueUpper,
        'decisions_by_full_uci_path': decisions,
      };
      File(
        p.join(_out, 'stats.json'),
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(stats));
      File(p.join(_out, 'tree.json')).writeAsStringSync(serializeTree(tree));
      stdout.writeln(
        '[fvp] ${jsonEncode({...stats}
          ..remove('decisions_by_full_uci_path')
          ..remove('config'))}',
      );
    } finally {
      masterDb?.close();
      StockfishPool.instance.dispose();
      MaiaFactory.instance?.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
