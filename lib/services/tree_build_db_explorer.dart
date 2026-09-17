/// The DB Explorer build: a tree grown from the move frequencies of the
/// user's own PGN database, then given engine evals.
///
/// [TreeBuildService.buildFromPgnFreqMap] owns the run's lifecycle and calls
/// the three phases here in order; this class holds the per-phase work so
/// the service is not spread over two files.
library;

import '../chess_core/generation/build_tree_node.dart';
import 'generation/build_run.dart';
import 'generation/fen_map.dart';
import 'generation/frontier_queue.dart';
import 'generation/generation_config.dart';
import 'generation/lanes.dart';
import 'generation/node_expander.dart';
import 'generation/opponent_prior.dart';
import 'generation/pgn_freq_map.dart';
import 'generation/pgn_freq_parser.dart';
import 'tree_build_gates.dart';
import 'tree_build_types.dart';

/// Nodes between progress reports while external sources / Stockfish fill in
/// missing evals.
const int _externalEvalProgressInterval = 50;
const int _stockfishEvalProgressInterval = 10;

class DbExplorerTreeBuilder {
  DbExplorerTreeBuilder(this.run);

  final BuildRun run;

  BuildTree get _tree => run.tree;
  TreeBuildConfig get _config => run.config;

  // ── Phase 0: parse ─────────────────────────────────────────────────────

  /// Parse the configured PGN files into a frequency map (in an isolate).
  ///
  /// When [startMoves] is given the scan starts after those moves; otherwise
  /// a custom start FEN anchors it.  Throws [BuildCancelledException] on a
  /// hard cancel and [StateError] when no game could be used.
  Future<(PgnFreqMap, PgnFreqStats)> parseGames({String? startMoves}) async {
    final config = _config;
    final hasStartMoves = startMoves != null && startMoves.isNotEmpty;
    final customStart = !_fenKeysEqual(config.startFen, kDefaultStartFen);
    final (freqMap, freqStats) = await parsePgnFiles(
      paths: config.pgnFilePaths,
      config: PgnFreqConfig(
        startFen: (!hasStartMoves && customStart) ? config.startFen : null,
        startMoves: hasStartMoves ? startMoves : null,
        maxPly: config.maxPly,
        minElo: config.minElo,
        retainGames: config.retainedGameCount,
        retainMinElo: config.modelGameMinElo,
      ),
      onProgress: (games, file) {
        run.onProgress(
          BuildProgress(
            totalNodes: 0,
            maxPlyConfig: config.maxPly,
            elapsedMs: run.stopwatch.elapsedMilliseconds,
          ),
        );
      },
    );

    if (run.isCancelled) {
      throw const BuildCancelledException('Cancelled during PGN parsing.');
    }

    run.log(
      'Freq map: ${freqStats.totalGames} games, '
      '${freqStats.positions} positions, '
      '${freqStats.retainedGames} retained for model games, '
      '${freqStats.skippedElo} elo-filtered, '
      '${freqStats.parseErrors} movetext errors, '
      '${freqStats.fileReadErrors} file read errors',
    );

    if (freqStats.totalGames == 0) {
      throw StateError(_noGamesMessage(freqStats));
    }
    return (freqMap, freqStats);
  }

  String _noGamesMessage(PgnFreqStats stats) {
    final parts = <String>[
      'No games parsed from ${_config.pgnFilePaths.length} file(s).',
      if (stats.fileReadErrors > 0)
        '${stats.fileReadErrors} file(s) could not be read '
            '(check path and encoding).',
      if (stats.skippedElo > 0) '${stats.skippedElo} skipped by Elo filter.',
      if (stats.parseErrors > 0) '${stats.parseErrors} movetext parse errors.',
    ];
    return parts.join(' ');
  }

  static bool _fenKeysEqual(String fenA, String fenB) =>
      canonicalizeFen(fenA) == canonicalizeFen(fenB);

  // ── Phase 1: expand ────────────────────────────────────────────────────

  /// BFS-expand the tree from the root using [freqMap]'s move frequencies.
  /// Matches C `tree_build_from_freqmap`.  Stops on cancel or finish-now
  /// and records whether the frontier was exhausted in
  /// [BuildTree.buildComplete].
  Future<void> expand(PgnFreqMap freqMap) async {
    final root = _tree.root;
    final rootFreq = freqMap.get(root.fen);
    if (rootFreq != null) {
      // The scan records a reach for every position it plays *into* and
      // for a custom start position, but not for the standard start, so
      // the root's count falls back to its played total the same way the
      // probability denominator does in [_expandNode].
      root.totalGames = rootFreq.reachCount > 0
          ? rootFreq.reachCount
          : rootFreq.playedTotal;
    }

    final queue = FrontierQueue(bestFirst: _config.bestFirst);
    queue.add(root);

    while (!run.isCancelled && !run.shouldFinish() && queue.isNotEmpty) {
      await run.waitIfPaused();
      if (run.isCancelled) break;

      final node = queue.removeFirst();
      if (node.explored) continue;
      run.progress.onDequeue(
        node.ply,
        priority: effectiveSearchPriority(node),
        frontierSize: queue.length,
      );

      await _expandNode(node, freqMap, queue);
    }

    _tree.buildComplete = !run.isCancelled && !run.shouldFinish();

    run.log(
      'DB Explorer tree: ${_tree.totalNodes} nodes, '
      'ply ${_tree.maxPlyReached}',
    );
  }

  Future<void> _expandNode(
    BuildTreeNode node,
    PgnFreqMap freqMap,
    FrontierQueue queue,
  ) async {
    final config = _config;

    if (node.ply >= config.maxPly ||
        run.belowSearchFloor(node) ||
        _nodeBudgetSpent) {
      run.markExplored(node);
      return;
    }

    final pos = freqMap.get(node.fen);
    if (pos == null || pos.moves.isEmpty) {
      run.markExplored(node);
      return;
    }

    // Legacy caches recorded moves only, and the scan never records a reach
    // for the standard start position: the played total stands in for both
    // the annotation and the probability denominator.
    final reach = pos.reachCount > 0 ? pos.reachCount : pos.playedTotal;
    node.totalGames = reach;

    if (run.resolveTranspositionOrRegister(node, queue)) return;

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    if (isOurMove) {
      _addOurMoves(node, pos, reach, queue);
    } else {
      if (reach == 0) {
        run.markExplored(node);
        return;
      }
      await _addOpponentMoves(node, pos, reach, queue);
    }

    run.markExplored(node);
    run.emitNodeProgress(node);
  }

  bool get _nodeBudgetSpent =>
      _config.maxNodes > 0 && _tree.totalNodes >= _config.maxNodes;

  /// Our move: every move in the frequency map.  Search priority follows
  /// the DB frequency share so best-first explores our popular moves first —
  /// cumulative probability stays undiscounted (our moves are a choice, not
  /// chance).
  void _addOurMoves(
    BuildTreeNode node,
    PgnFreqPosition pos,
    int reach,
    FrontierQueue queue,
  ) {
    final basePriority = effectiveSearchPriority(node);
    for (final m in pos.moves) {
      if (_nodeBudgetSpent) break;

      final played = run.childMove(node, m.uci);
      if (played == null) continue;

      final child = run.makeChild(
        parent: node,
        fen: played.fen,
        san: m.san.isNotEmpty ? m.san : played.san,
        uci: m.uci,
        position: played.after,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      child.setLichessStats(m.whiteWins, m.blackWins, m.draws);
      final discount = reach > 0 ? m.count / reach : 1.0;
      child.searchPriority = basePriority * discount;
      child.searchPriorityDiscount = discount;
      queue.add(child);
    }
  }

  /// Opponent move: smoothed DB frequencies (Maia Dirichlet prior when
  /// coverage is sparse), else raw frequencies with min-games/min-prob.
  Future<void> _addOpponentMoves(
    BuildTreeNode node,
    PgnFreqPosition pos,
    int reach,
    FrontierQueue queue,
  ) async {
    final maiaPolicy = await maiaPolicyForSmoothing(run, node.fen, reach);
    final smoothing = maiaPolicy.isNotEmpty;

    final candidates = smoothOpponentMoves(
      observed: [
        for (final m in pos.moves)
          ObservedMove(
            uci: m.uci,
            san: m.san,
            games: m.count,
            whiteWins: m.whiteWins,
            blackWins: m.blackWins,
            draws: m.draws,
          ),
      ],
      totalGames: reach,
      maiaPolicy: maiaPolicy,
      priorGames: smoothing ? _config.maiaPriorGames : 0.0,
    );

    addOpponentChildren(
      run: run,
      node: node,
      candidates: candidates,
      smoothing: smoothing,
      minGames: _config.dbMinGames,
      minMoveProb: _config.dbMinProb,
      respectMaxNodes: true,
      attachStats: true,
      emitProgressPerChild: false,
      onChild: queue.add,
    );
  }

  // ── Phase 1.5: evals ───────────────────────────────────────────────────

  /// Batch-evaluate tree nodes that lack engine evals.
  /// Matches C `tree_enrich_evals`: cache → external chain → Stockfish.
  Future<void> enrichEvals() async {
    final config = _config;

    final noEval = <BuildTreeNode>[];
    void collectNoEval(BuildTreeNode node) {
      if (!node.hasEngineEval) noEval.add(node);
      for (final child in node.children) {
        collectNoEval(child);
      }
    }

    collectNoEval(_tree.root);

    if (noEval.isEmpty) return;

    run.log('Enriching evals: ${noEval.length} nodes without eval');

    // Phase 1: external eval sources (cache + cdbdirect + ChessDB).  The
    // cloud provider rate-limits itself to [chessDbApiConcurrency] requests,
    // so that many lanes keeps its quota busy without exceeding it.
    var enriched = 0;
    await runLanes(
      noEval,
      lanes: config.chessDbApiConcurrency,
      stop: () => run.isCancelled,
      task: (node) async {
        await run.waitIfPaused();
        if (run.isCancelled) return;

        final gotEval = await run.evalResolver.ensureEval(
          node,
          config,
          fenMap: run.fenMap,
          pool: run.pool,
          dbOnly: true,
        );
        if (gotEval) enriched++;

        if (enriched % _externalEvalProgressInterval == 0) {
          run.emitNodeProgress(node);
        }
      },
    );
    if (run.isCancelled) return;

    run.log('External eval enrichment: $enriched / ${noEval.length} resolved');

    // Phase 2: Stockfish batch for remaining — one eval per unique FEN,
    // propagated to every node sharing that position.
    final stillNeed = noEval.where((n) => !n.hasEngineEval).toList();
    if (stillNeed.isNotEmpty && run.pool.workerCount > 0) {
      run.log('Stockfish enrichment: ${stillNeed.length} nodes remaining');

      final byFen = <String, List<BuildTreeNode>>{};
      for (final node in stillNeed) {
        (byFen[node.fen] ??= []).add(node);
      }

      // One position per lane: each [ensureEval] acquires its own worker.
      var i = 0;
      await runLanes(
        byFen.values.toList(),
        lanes: run.expansionLanes,
        stop: () => run.isCancelled,
        task: (group) async {
          await run.waitIfPaused();
          if (run.isCancelled) return;

          final node = group.first;
          await run.evalResolver.ensureEval(
            node,
            config,
            fenMap: run.fenMap,
            pool: run.pool,
          );

          if (node.hasEngineEval) {
            for (final other in group.skip(1)) {
              other.engineEvalCp = node.engineEvalCp;
            }
          }

          if (i++ % _stockfishEvalProgressInterval == 0) {
            run.emitNodeProgress(node);
          }
        },
      );
      if (run.isCancelled) return;
    }

    final failed = noEval.where((n) => !n.hasEngineEval).length;
    run.log('Eval enrichment done: $failed / ${noEval.length} still missing');
  }
}
