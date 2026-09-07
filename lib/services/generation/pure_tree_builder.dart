/// Exhaustive finite-horizon search. No frequency, MultiPV or eval-window
/// truncation; only the explicitly configured objective-loss constraint.
library;

import 'dart:collection';
import '../../models/build_tree_node.dart';
import '../maia/maia_factory.dart';
import 'build_run.dart';
import 'eca_calculator.dart';
import 'generation_config.dart';
import 'pure_position.dart';

class PureTreeBuilder {
  PureTreeBuilder(this.run);
  final BuildRun run;

  Future<void> build() async {
    final config = run.config;
    const source = 'none';
    if (config.evalDepth < 1 ||
        config.maxPly < 1 ||
        config.maxPly > 64 ||
        config.maxEvalLossCp < 0) {
      throw ArgumentError(
        'Pure requires positive engine depth, 1–64 plies and a nonnegative eval-loss limit.',
      );
    }
    // Old trees used different action sets and history-free transpositions.
    // They cannot be completed by merely adding more nodes.
    if (run.tree.root.children.isNotEmpty && !run.tree.root.historyAware) {
      throw StateError('This tree predates Pure search. Start a new build.');
    }
    if (run.tree.root.children.isNotEmpty) {
      final previous = run.tree.configSnapshot;
      if ((previous['search_algorithm'] == 'rolling') !=
          config.isRollingSearch) {
        throw StateError(
          'Cannot switch Pure and Fast on resume. Start a new build.',
        );
      }
      if (run.tree.root.fen != config.startFen ||
          previous['opponent_book_source'] != source) {
        throw StateError(
          'Pure resume requires the same starting position and opponent book source.',
        );
      }
      final current = config.toJson();
      for (final key in [
        'play_as_white',
        'eval_depth',
        'max_eval_loss_cp',
        'maia_elo',
      ]) {
        if (previous[key] != current[key]) {
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
    run.tree.configSnapshot = {
      ...config.toJson(),
      'algorithm_version': 3,
      'search_algorithm': config.isRollingSearch ? 'rolling' : 'pure',
      'opponent_book_source': source,
    };
    run.tree.buildComplete = false;
    run.tree.buildComplete = config.isRollingSearch
        ? await _buildRolling()
        : await _searchWindow(run.tree.root, config.maxPly);
  }

  Future<bool> _buildRolling() async {
    final config = run.config;
    final calculator = ExpectimaxCalculator(config: config);
    final queue = Queue<BuildTreeNode>()..add(run.tree.root);
    while (queue.isNotEmpty) {
      await run.waitIfPaused();
      if (run.isCancelled || run.shouldFinish()) return false;
      final node = queue.removeFirst();
      final ours = node.isWhiteToMove == config.playAsWhite;
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

  Future<bool> _searchWindow(BuildTreeNode root, int horizon) async {
    final config = run.config;
    final queue = Queue<BuildTreeNode>()..add(root);
    while (queue.isNotEmpty) {
      await run.waitIfPaused();
      if (run.isCancelled || run.shouldFinish()) return false;
      final node = queue.removeFirst()..historyAware = true;
      final position = run.positionOrNullOf(node);
      if (position == null) {
        throw StateError('Invalid Pure search position: ${node.fen}');
      }
      node.terminalValue = pureTerminal(node, position, config.playAsWhite);
      if (node.terminalValue != null) {
        run.markExplored(node);
        continue;
      }
      if (node.ply >= horizon) {
        await _evaluate(node);
        run.markExplored(node);
        continue;
      }
      if (node.explored && node.children.isNotEmpty) {
        queue.addAll(node.children);
        continue;
      }
      final legal = pureLegalMoves(position);
      final ours = node.isWhiteToMove == config.playAsWhite;
      final policy = ours ? <String, double>{} : await _policy(node, legal);
      final probabilities = policy;
      final moves = ours
          ? legal
          : legal.where((m) => probabilities[m]! > 0).toList();
      // Atomic expansions: a budget never leaves a partially specified
      // probability distribution or a partially enumerated action set.
      if (config.maxNodes > 0 &&
          run.tree.totalNodes + moves.length > config.maxNodes) {
        return false;
      }
      final candidates = <BuildTreeNode>[];
      for (final uci in moves) {
        final played = run.childMove(node, uci)!;
        final candidate = BuildTreeNode(
          fen: played.fen,
          moveSan: played.san,
          moveUci: uci,
          ply: node.ply + 1,
          isWhiteToMove: !node.isWhiteToMove,
          nodeId: run.nextNodeId++,
          parent: node,
          moveProbability: ours ? 1 : probabilities[uci]!,
          cumulativeProbability:
              node.cumulativeProbability * (ours ? 1 : probabilities[uci]!),
        )..historyAware = true;
        candidate.terminalValue = pureTerminal(
          candidate,
          played.after,
          config.playAsWhite,
        );
        if (ours) await _evaluate(candidate);
        candidates.add(candidate);
        if (run.isCancelled || run.shouldFinish()) return false;
      }
      if (ours) {
        final best = candidates
            .map((c) => c.evalForUs(config.playAsWhite))
            .reduce((a, b) => a > b ? a : b);
        candidates.removeWhere(
          (c) => c.evalForUs(config.playAsWhite) < best - config.maxEvalLossCp,
        );
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

  Future<void> _evaluate(BuildTreeNode node) async {
    if (node.terminalValue != null) {
      final ourCp = node.terminalValue == 0.5
          ? 0
          : node.terminalValue == 1
          ? 10000
          : -10000;
      node.engineEvalCp = node.isWhiteToMove == run.config.playAsWhite
          ? ourCp
          : -ourCp;
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
}
