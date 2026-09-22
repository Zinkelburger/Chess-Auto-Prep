/// Exhaustive finite-horizon search. No frequency, MultiPV or eval-window
/// truncation; only the explicitly configured objective-loss constraint.
library;

import 'dart:collection';

import 'package:dartchess/dartchess.dart' show Position;

import '../../chess_core/generation/build_tree_node.dart';
import '../../utils/eval_constants.dart';
import '../maia/maia_factory.dart';
import 'build_run.dart';
import 'eca_calculator.dart';
import 'generation_config.dart';
import 'lanes.dart';
import 'pure_position.dart';

/// Builds a Pure (or Fast/rolling) tree over a [BuildRun]: every legal move
/// at our nodes, Maia's full policy at the opponent's, fixed-depth engine
/// evaluations at the horizon. Expansions are committed atomically, so a
/// budget or cancellation never leaves a partial action set.
class PureTreeBuilder {
  PureTreeBuilder(this.run);
  final BuildRun run;

  /// Recorded in the config snapshot: Pure never consults a game database.
  static const String _opponentBookSource = 'none';

  /// Horizon leaves are independent; this bounds the batch handed to the
  /// engines at once, even when every earlier node had a single legal move.
  static const int _horizonBatchSize = 256;

  /// Configuration keys a resumed Pure build must keep unchanged.
  static List<String> _resumeInvariantKeys(TreeBuildConfig config) => [
    'play_as_white',
    'eval_depth',
    'max_eval_loss_cp',
    'maia_elo',
    'bounded_database',
    if (config.boundedDatabase) 'our_multipv',
    if (config.boundedDatabase) 'opp_mass_target',
  ];

  Future<void> build() async {
    final config = run.config;
    if (config.evalDepth < 1 ||
        config.maxPly < 1 ||
        config.maxPly > 64 ||
        config.maxEvalLossCp < 0) {
      throw ArgumentError(
        'Pure requires positive engine depth, 1–64 plies and a nonnegative eval-loss limit.',
      );
    }
    if (run.tree.root.children.isNotEmpty) _assertResumable(config);
    run.tree.configSnapshot = {
      ...config.toJson(),
      'algorithm_version': 3,
      'maia_policy_version': 1,
      'search_algorithm': config.isRollingSearch ? 'rolling' : 'pure',
      'opponent_book_source': _opponentBookSource,
    };
    run.tree.buildComplete = false;
    run.tree.buildComplete = config.isRollingSearch
        ? await _buildRolling()
        : await _searchWindow(run.tree.root, config.maxPly);
  }

  /// A saved tree can only continue under the model that built it: same
  /// root, side, engine settings, opponent rating and search method, with a
  /// horizon that may grow but never shrink.
  void _assertResumable(TreeBuildConfig config) {
    // Old trees used different action sets and history-free transpositions.
    // They cannot be completed by merely adding more nodes.
    if (!run.tree.root.historyAware) {
      throw StateError('This tree predates Pure search. Start a new build.');
    }
    final previous = run.tree.configSnapshot;
    if (previous['maia_policy_version'] != 1) {
      throw StateError('Maia inference has changed. Start a new build.');
    }
    if ((previous['search_algorithm'] == 'rolling') != config.isRollingSearch) {
      throw StateError(
        'Cannot switch Pure and Fast on resume. Start a new build.',
      );
    }
    if (run.tree.root.fen != config.startFen ||
        previous['opponent_book_source'] != _opponentBookSource) {
      throw StateError(
        'Pure resume requires the same starting position and opponent book source.',
      );
    }
    final current = config.toJson();
    for (final key in _resumeInvariantKeys(config)) {
      final saved = key == 'bounded_database'
          ? previous[key] ?? false
          : previous[key];
      if (saved != current[key]) {
        throw StateError(
          'Pure resume requires unchanged $key; start a new build.',
        );
      }
    }
    if (config.maxPly < (previous['max_depth'] as int? ?? 0)) {
      throw StateError(
        'Cannot shorten the horizon of a saved Pure search. Start a new build.',
      );
    }
  }

  Future<bool> _buildRolling() async {
    final config = run.config;
    final calculator = ExpectimaxCalculator(config: config);
    final queue = Queue<BuildTreeNode>()..add(run.tree.root);
    while (queue.isNotEmpty) {
      await run.waitIfPaused();
      if (run.isCancelled || run.shouldFinish()) return false;
      final node = queue.removeFirst();
      final ours = _isOurTurn(node);
      final horizon =
          (node.ply + (ours ? TreeBuildConfig.rollingLookaheadPlies : 1)).clamp(
            0,
            config.maxPly,
          );
      if (node.terminalValue != null || node.ply >= config.maxPly) {
        if (!await _searchWindow(node, config.maxPly)) return false;
        continue;
      }
      if (ours) {
        if (node.committedMoveUci.isEmpty || node.decisionHorizon < horizon) {
          if (!await _searchWindow(node, horizon)) return false;
          if (node.terminalValue != null) continue;
          calculator.commitWindow(node, horizon);
        }
        final selected = node.children
            .where((c) => c.moveUci == node.committedMoveUci)
            .firstOrNull;
        if (selected == null) {
          throw StateError('Saved Fast decision is missing');
        }
        queue.add(selected);
      } else {
        if (!await _searchWindow(node, horizon)) return false;
        queue.addAll(node.children);
      }
    }
    return true;
  }

  /// Breadth-first expansion below [root] to [horizon]. Returns false when
  /// the run was cancelled, finished early or ran out of node budget.
  Future<bool> _searchWindow(BuildTreeNode root, int horizon) async {
    final config = run.config;
    final queue = Queue<BuildTreeNode>()..add(root);
    while (queue.isNotEmpty) {
      await run.waitIfPaused();
      if (run.isCancelled || run.shouldFinish()) return false;
      final node = queue.removeFirst();
      final position = _enterNode(node);
      if (node.terminalValue != null) {
        run.markExplored(node);
        continue;
      }
      if (node.ply >= horizon) {
        final leaves = _drainHorizonLeaves(
          queue,
          first: node,
          horizon: horizon,
        );
        if (!await _evaluateBatch(leaves)) return false;
        for (final leaf in leaves) {
          run.markExplored(leaf);
        }
        run.emitNodeProgress(leaves.last);
        continue;
      }
      if (node.explored && node.children.isNotEmpty) {
        queue.addAll(node.children);
        continue;
      }
      final legal = pureLegalMoves(position);
      final ours = _isOurTurn(node);
      final probabilities = ours && !config.boundedDatabase
          ? <String, double>{}
          : await _policy(node, legal);
      final moves = config.boundedDatabase
          ? await _boundedMoves(node, legal, probabilities)
          : ours
          ? List<String>.of(legal)
          : legal.where((m) => probabilities[m]! > 0).toList();
      // Atomic expansions: a budget never leaves a partially specified
      // probability distribution or a partially enumerated action set.
      if (config.maxNodes > 0 &&
          run.tree.totalNodes + moves.length > config.maxNodes) {
        return false;
      }
      final candidates = <BuildTreeNode>[];
      for (final uci in moves) {
        candidates.add(_candidate(node, uci, ours ? 1 : probabilities[uci]!));
        if (run.isCancelled || run.shouldFinish()) return false;
      }
      if (ours) {
        if (!await _evaluateBatch(candidates)) return false;
        final best = candidates
            .map((c) => c.evalForUs(config.playAsWhite))
            .reduce((a, b) => a > b ? a : b);
        if (!config.boundedDatabase) {
          candidates.removeWhere(
            (c) =>
                c.evalForUs(config.playAsWhite) < best - config.maxEvalLossCp,
          );
        }
        // Keep the fixed-depth child evaluation used by the parent guard.
        // A later expansion must never replace it with a different search.
      }
      node.children.clear();
      for (final child in candidates) {
        run.attachPureChild(node, child);
        queue.add(child);
      }
      run.markExplored(node);
      run.emitNodeProgress(node);
    }
    return true;
  }

  /// Mark [node] history-aware, parse its position and record whether it is
  /// an exact terminal.
  Position _enterNode(BuildTreeNode node) {
    node.historyAware = true;
    final position = run.positionOrNullOf(node);
    if (position == null) {
      throw StateError('Invalid Pure search position: ${node.fen}');
    }
    node.terminalValue = pureTerminal(node, position, run.config.playAsWhite);
    return position;
  }

  /// [first] plus the horizon leaves queued directly behind it, up to
  /// [_horizonBatchSize], each entered like [first] was.
  List<BuildTreeNode> _drainHorizonLeaves(
    Queue<BuildTreeNode> queue, {
    required BuildTreeNode first,
    required int horizon,
  }) {
    final leaves = <BuildTreeNode>[first];
    while (queue.isNotEmpty &&
        queue.first.ply >= horizon &&
        leaves.length < _horizonBatchSize) {
      final leaf = queue.removeFirst();
      _enterNode(leaf);
      leaves.add(leaf);
    }
    return leaves;
  }

  /// Bounded database exploration: the union of the engine's top MultiPV
  /// candidates and Maia's likeliest replies up to the mass target, in
  /// legal-move order. Every position includes strong rare replies as well
  /// as human moves; the caller keeps actual Maia probabilities, including
  /// zero for engine-only moves.
  Future<List<String>> _boundedMoves(
    BuildTreeNode node,
    List<String> legal,
    Map<String, double> probabilities,
  ) async {
    final config = run.config;
    final discovery = await run.pool.discoverMoves(
      fen: node.fen,
      depth: config.evalDepth,
      multiPv: config.ourMultipv,
      isWhiteToMove: node.isWhiteToMove,
    );
    if (discovery.lines.isEmpty) {
      throw StateError('Stockfish returned no legal candidates');
    }
    final selected = discovery.lines
        .take(config.ourMultipv)
        .map((line) => line.moveUci)
        .toSet();
    final likely = legal.where((m) => probabilities[m]! > 0).toList()
      ..sort((a, b) => probabilities[b]!.compareTo(probabilities[a]!));
    var mass = 0.0;
    for (final move in likely) {
      if (mass >= config.oppMassTarget) break;
      selected.add(move);
      mass += probabilities[move]!;
    }
    return legal.where(selected.contains).toList();
  }

  /// A not-yet-attached child of [node] for [uci], with its terminal status
  /// already known.
  BuildTreeNode _candidate(BuildTreeNode node, String uci, double probability) {
    final played = run.childMove(node, uci)!;
    final candidate = BuildTreeNode(
      fen: played.fen,
      moveSan: played.san,
      moveUci: uci,
      ply: node.ply + 1,
      isWhiteToMove: !node.isWhiteToMove,
      nodeId: run.nextNodeId++,
      parent: node,
      moveProbability: probability,
      cumulativeProbability: node.cumulativeProbability * probability,
    )..historyAware = true;
    candidate.terminalValue = pureTerminal(
      candidate,
      played.after,
      run.config.playAsWhite,
    );
    return candidate;
  }

  /// Workers take the next position as soon as they finish. Only evaluations
  /// run concurrently: action sets, node IDs and Fast decisions are committed
  /// by the caller in legal-move order after the entire batch succeeds.
  Future<bool> _evaluateBatch(List<BuildTreeNode> nodes) async {
    var failed = false;
    bool stopped() => failed || run.isCancelled || run.shouldFinish();
    // runLanes drains all in-flight evaluations even if one fails, so no
    // worker can mutate a node after build() returns or its pool is released.
    await runLanes(
      nodes,
      lanes: run.expansionLanes,
      stop: stopped,
      task: (node) async {
        await run.waitIfPaused();
        if (stopped()) return;
        try {
          await _evaluate(node);
        } catch (_) {
          failed = true;
          rethrow;
        }
      },
    );
    return !run.isCancelled && !run.shouldFinish();
  }

  Future<void> _evaluate(BuildTreeNode node) async {
    if (node.terminalValue != null) {
      final ourCp = node.terminalValue == 0.5
          ? 0
          : node.terminalValue == 1
          ? kMateCpBase
          : -kMateCpBase;
      node.engineEvalCp = _isOurTurn(node) ? ourCp : -ourCp;
      return;
    }
    if (node.hasEngineEval) return;
    final result = await run.pool.evaluateFen(node.fen, run.config.evalDepth);
    if (result.depth < run.config.evalDepth && result.scoreMate == null) {
      throw StateError(
        'Engine did not reach the requested depth at ${node.fen}',
      );
    }
    node.engineEvalCp = result.effectiveCp;
    run.stats.sfSingleCalls++;
  }

  /// Maia's policy over [legal], normalized to sum to one. Missing Maia or
  /// an empty policy is an error: Pure never substitutes another source.
  Future<Map<String, double>> _policy(
    BuildTreeNode node,
    List<String> legal,
  ) async {
    final maia = MaiaFactory.instance;
    if (!MaiaFactory.isAvailable || maia == null) {
      throw StateError('Maia is required for every opponent position.');
    }
    final result = await maia.evaluate(node.fen, run.config.maiaElo);
    run.stats.maiaEvals++;
    final policy = <String, double>{
      for (final m in legal) m: result.policy[m] ?? 0,
    };
    if (policy.values.any((p) => !p.isFinite || p < 0)) {
      throw StateError('Invalid opponent probabilities');
    }
    final mass = policy.values.fold(0.0, (a, b) => a + b);
    if (mass <= 0) {
      throw StateError('Opponent policy has no legal probability mass');
    }
    return policy.map((m, p) => MapEntry(m, p / mass));
  }

  bool _isOurTurn(BuildTreeNode node) =>
      node.isWhiteToMove == run.config.playAsWhite;
}
