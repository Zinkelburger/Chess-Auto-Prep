part of 'tree_build_service.dart';

const int _externalEvalProgressInterval = 50;
const int _stockfishEvalProgressInterval = 10;

extension TreeBuildServiceDbExplorer on TreeBuildService {
  // ── DB Explorer: build tree from PGN frequency map ─────────────────────

  /// Build a tree by parsing PGN files into a frequency map, then BFS-
  /// expanding from the root using move frequencies.  Matches C
  /// `tree_build_from_freqmap` + `tree_enrich_evals`.
  ///
  /// [finishNow] stops the BFS expansion early but does NOT skip eval
  /// enrichment or the coverage sweep — a finished-early tree still gets
  /// evals so downstream selection has something to work with.  Throws
  /// [BuildCancelledException] when hard-cancelled during PGN parsing.
  Future<BuildTree> buildFromPgnFreqMap({
    required TreeBuildConfig config,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    bool Function()? finishNow,
    void Function(String status, GenerationPhase phase)? onStatusChanged,
    String? startMoves,
  }) async {
    if (config.pgnFilePaths.isEmpty) {
      throw StateError('DB Explorer requires at least one PGN file.');
    }

    // Synchronous prologue — see _startRun for why.
    var nextNodeId = 1;
    final rootFen = config.startFen;
    final root = BuildTreeNode(
      fen: rootFen,
      moveSan: '',
      moveUci: '',
      ply: 0,
      isWhiteToMove: isWhiteToMove(rootFen),
      nodeId: nextNodeId++,
    );
    final tree = BuildTree(root: root, configSnapshot: config.toJson());
    tree.registerNode(root);
    root.cumulativeProbability = 1.0;
    root.searchPriority = 1.0;

    final run = _startRun(
      config: config,
      tree: tree,
      fenMap: FenMap(),
      isCancelled: isCancelled,
      finishNow: finishNow ?? () => false,
      onProgress: onProgress,
      nextNodeId: nextNodeId,
    );
    _log('DB Explorer start: config=${jsonEncode(config.toJson())}');

    try {
      // Phase 0: Parse PGN files into frequency map (isolate)
      onStatusChanged?.call('Parsing PGN files...', GenerationPhase.parsingPgn);
      final hasStartMoves = startMoves != null && startMoves.isNotEmpty;
      final pgnCustomFen = !_fenKeysEqual(config.startFen, kDefaultStartFen);
      final (freqMap, freqStats) = await parsePgnFiles(
        paths: config.pgnFilePaths,
        config: PgnFreqConfig(
          startFen: (!hasStartMoves && pgnCustomFen) ? config.startFen : null,
          startMoves: hasStartMoves ? startMoves : null,
          maxPly: config.maxPly,
          minElo: config.minElo,
        ),
        onProgress: (games, file) {
          onProgress(
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

      _log(
        'Freq map: ${freqStats.totalGames} games, '
        '${freqStats.positions} positions, '
        '${freqStats.skippedElo} elo-filtered, '
        '${freqStats.parseErrors} movetext errors, '
        '${freqStats.fileReadErrors} file read errors',
      );

      if (freqStats.totalGames == 0) {
        final parts = <String>[
          'No games parsed from ${config.pgnFilePaths.length} file(s).',
        ];
        if (freqStats.fileReadErrors > 0) {
          parts.add(
            '${freqStats.fileReadErrors} file(s) could not be read '
            '(check path and encoding).',
          );
        }
        if (freqStats.skippedElo > 0) {
          parts.add('${freqStats.skippedElo} skipped by Elo filter.');
        }
        if (freqStats.parseErrors > 0) {
          parts.add('${freqStats.parseErrors} movetext parse errors.');
        }
        throw StateError(parts.join(' '));
      }

      // Phase 1: BFS tree build from frequency map
      onStatusChanged?.call(
        'Building tree from ${freqStats.totalGames} games, '
        '${freqStats.positions} positions...',
        GenerationPhase.buildingTree,
      );

      final rootFreq = freqMap.get(rootFen);
      if (rootFreq != null) {
        root.totalGames = rootFreq.reachCount;
      }

      final queue = FrontierQueue(bestFirst: config.bestFirst);
      queue.add(root);

      while (!run.isCancelled && !run.finishNow() && queue.isNotEmpty) {
        await waitIfPaused();
        if (run.isCancelled) break;

        final node = queue.removeFirst();
        if (node.explored) continue;
        run.progress.onDequeue(
          node.ply,
          priority: effectiveSearchPriority(node),
          frontierSize: queue.length,
        );

        await _processDbExplorerNode(
          run: run,
          node: node,
          freqMap: freqMap,
          queue: queue,
        );
      }

      tree.buildComplete = !run.isCancelled && !run.finishNow();

      _log(
        'DB Explorer tree: ${tree.totalNodes} nodes, '
        'ply ${tree.maxPlyReached}',
      );

      // Phase 1.5: Eval enrichment.  Runs on finish-now too — a tree without
      // evals is useless to the selection phases downstream.
      if (!run.isCancelled) {
        onStatusChanged?.call(
          'Enriching evals (${tree.totalNodes} nodes)...',
          GenerationPhase.enrichingEvals,
        );

        await _evalResolver.evalCache.init();
        await _evalResolver.initProviders(config);

        if (config.usesStockfish || config.needsStockfish) {
          if (EngineLifecycle.instance.state != EngineState.generating) {
            await _pool.prepareForTreeBuild(config.resolvedEngineThreads);
          }
        }

        try {
          await _enrichEvals(run);
          // After enrichment the engine is available, so holes where the
          // user's games ran out can get an engine answer.
          if (!run.isCancelled) {
            await _coverageSweep(run, NodeExpander.forRun(run));
          }
        } finally {
          run.fenMap.clear();
          await _evalResolver.teardownProviders();
        }
      }

      _log(
        'DB Explorer complete: ${tree.totalNodes} nodes, '
        '${run.stopwatch.elapsedMilliseconds}ms',
      );
      _log('Stats: ${jsonEncode(_stats.toJson())}');

      return tree;
    } finally {
      _isBuilding = false;
      run.stopwatch.stop();
    }
  }

  Future<void> _processDbExplorerNode({
    required BuildRun run,
    required BuildTreeNode node,
    required PgnFreqMap freqMap,
    required FrontierQueue queue,
  }) async {
    final config = run.config;
    final tree = run.tree;

    if (node.ply >= config.maxPly) {
      node.explored = true;
      return;
    }
    // Fast: our-move sidelines whose frequency-share priority fell below
    // the floor are not worth expanding (priority ≤ cumulativeProbability).
    if (TreeBuildService._belowSearchFloor(node, config)) {
      node.explored = true;
      return;
    }
    if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) {
      node.explored = true;
      return;
    }

    final pos = freqMap.get(node.fen);
    if (pos == null || pos.moves.isEmpty) {
      node.explored = true;
      return;
    }

    node.totalGames = pos.reachCount;

    // Transposition detection
    if (TreeBuildService._resolveTranspositionOrRegister(run, node, queue))
      return;

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    final basePri = effectiveSearchPriority(node);

    int reach = pos.reachCount;
    if (reach == 0) {
      reach = pos.moves.fold(0, (sum, m) => sum + m.count);
    }

    if (isOurMove) {
      // Our move: add all moves from the frequency map.  Search priority
      // follows the DB frequency share so best-first explores our popular
      // moves first — cumulative probability stays undiscounted (our moves
      // are a choice, not chance).
      for (final m in pos.moves) {
        if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) break;

        final childFen = playUciMove(node.fen, m.uci);
        if (childFen == null) continue;

        final san = m.san.isNotEmpty ? m.san : uciToSan(node.fen, m.uci);
        final child = run.makeChild(
          parent: node,
          fen: childFen,
          san: san,
          uci: m.uci,
        );
        if (child == null) continue;

        child.moveProbability = 1.0;
        child.cumulativeProbability = node.cumulativeProbability;
        final discount = reach > 0 ? m.count / reach : 1.0;
        child.searchPriority = basePri * discount;
        child.searchPriorityDiscount = discount;
        queue.add(child);
      }
    } else {
      // Opponent move: smoothed DB frequencies (Maia Dirichlet prior when
      // coverage is sparse), else raw frequencies with min-games/min-prob.
      if (reach == 0) {
        node.explored = true;
        return;
      }

      final maiaPolicy = await maiaPolicyForSmoothing(run, node.fen, reach);
      final smoothing = maiaPolicy.isNotEmpty;

      final candidates = smoothOpponentMoves(
        observed: [
          for (final m in pos.moves)
            ObservedMove(uci: m.uci, san: m.san, games: m.count),
        ],
        totalGames: reach,
        maiaPolicy: maiaPolicy,
        priorGames: smoothing ? config.maiaPriorGames : 0.0,
      );

      addOpponentChildren(
        run: run,
        node: node,
        candidates: candidates,
        smoothing: smoothing,
        minGames: config.dbMinGames,
        minMoveProb: config.dbMinProb,
        respectMaxNodes: true,
        emitProgressPerChild: false,
        onChild: queue.add,
      );
    }

    node.explored = true;

    run.emitNodeProgress(node);
  }

  /// Batch-evaluate tree nodes that lack engine evals.
  /// Matches C `tree_enrich_evals`: cache → external chain → Stockfish.
  Future<void> _enrichEvals(BuildRun run) async {
    final tree = run.tree;
    final config = run.config;

    final noEval = <BuildTreeNode>[];
    void collectNoEval(BuildTreeNode node) {
      if (!node.hasEngineEval) noEval.add(node);
      for (final child in node.children) {
        collectNoEval(child);
      }
    }

    collectNoEval(tree.root);

    if (noEval.isEmpty) return;

    _log('Enriching evals: ${noEval.length} nodes without eval');

    // Phase 1: external eval sources (cache + cdbdirect + ChessDB)
    int enriched = 0;
    for (final node in noEval) {
      await waitIfPaused();
      if (run.isCancelled) return;

      final gotEval = await _evalResolver.ensureEval(
        node,
        config,
        fenMap: run.fenMap,
        pool: _pool,
        dbOnly: true,
      );
      if (gotEval) enriched++;

      if (enriched % _externalEvalProgressInterval == 0) {
        run.emitNodeProgress(node);
      }
    }

    _log('External eval enrichment: $enriched / ${noEval.length} resolved');

    // Phase 2: Stockfish batch for remaining — one eval per unique FEN,
    // propagated to every node sharing that position.
    final stillNeed = noEval.where((n) => !n.hasEngineEval).toList();
    if (stillNeed.isNotEmpty && _pool.workerCount > 0) {
      _log('Stockfish enrichment: ${stillNeed.length} nodes remaining');

      final byFen = <String, List<BuildTreeNode>>{};
      for (final node in stillNeed) {
        (byFen[node.fen] ??= []).add(node);
      }

      int i = 0;
      for (final group in byFen.values) {
        await waitIfPaused();
        if (run.isCancelled) return;

        final node = group.first;
        await _evalResolver.ensureEval(
          node,
          config,
          fenMap: run.fenMap,
          pool: _pool,
        );

        if (node.hasEngineEval) {
          for (final other in group.skip(1)) {
            other.engineEvalCp = node.engineEvalCp;
          }
        }

        if (i++ % _stockfishEvalProgressInterval == 0) {
          run.emitNodeProgress(node);
        }
      }
    }

    final failed = noEval.where((n) => !n.hasEngineEval).length;
    _log('Eval enrichment done: $failed / ${noEval.length} still missing');
  }
}
