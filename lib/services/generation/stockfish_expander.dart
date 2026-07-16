part of 'node_expander.dart';

// ── Stockfish MultiPV our-move expansion ─────────────────────────────────

class StockfishExpander extends NodeExpander {
  StockfishExpander(super.run);

  @override
  Future<void> expandOurMove(
    BuildTreeNode node,
    FrontierQueue queue, {
    bool coverageOnly = false,
  }) async {
    // Fast: MultiPV shrinks with reach priority; Pure: constant.  Root
    // always gets a wide sweep — everything descends from it.
    final nodePriority = effectiveSearchPriority(node);
    final mpvCount = node.ply == 0
        ? config.rootMultipv
        : config.effectiveMultipv(nodePriority);
    final whiteToMove = isWhiteToMove(node.fen);

    final sw = Stopwatch()..start();
    final discovery = await run.pool.discoverMoves(
      fen: node.fen,
      depth: config.evalDepth,
      multiPv: mpvCount,
      isWhiteToMove: whiteToMove,
    );
    run.stats.sfMultipvCalls++;
    run.stats.sfMultipvMs += sw.elapsedMilliseconds;

    if (discovery.lines.isEmpty) return;

    // Set node eval from top line
    if (!node.hasEngineEval) {
      final topCp = discovery.lines.first.effectiveCp;
      final stmCp = whiteToMove ? topCp : -topCp;
      node.engineEvalCp = stmCp;
      run.evalResolver.cacheEvalWhite(node.fen, topCp, config.evalDepth);
    }

    // Eval-window pruning (deferred from the build loop so the eval comes
    // from MultiPV line 0, avoiding an extra single-PV call).
    if (evalWindowPrune(node, config)) return;

    // Lichess enrichment for SAN + win rates at our-move nodes.
    // Matches C: queried when `!maia_only` (Lichess is the opponent
    // source, so the explorer data is available anyway).
    ExplorerResponse? lichess;
    if (!config.maiaOnly) {
      lichess = await run.evalResolver.getDbData(node.fen, config);
    }

    if (lichess != null) {
      final totalW = lichess.moves.fold(0, (s, m) => s + m.white);
      final totalB = lichess.moves.fold(0, (s, m) => s + m.black);
      final totalD = lichess.moves.fold(0, (s, m) => s + m.draws);
      node.setLichessStats(totalW, totalB, totalD);
    }

    // Filter candidates by eval loss (direction depends on STM).  Fast
    // halves the window at cold nodes; the root keeps the full window.
    final bestCp = discovery.lines.first.effectiveCp;
    final evalLossWindow = node.ply == 0
        ? config.maxEvalLossCp
        : config.effectiveMaxEvalLossCp(nodePriority);

    for (final line in discovery.lines) {
      if (line.moveUci.isEmpty) continue;
      final evalLoss = whiteToMove
          ? bestCp - line.effectiveCp
          : line.effectiveCp - bestCp;
      if (evalLoss > evalLossWindow) continue;

      final childFen = playUciMove(node.fen, line.moveUci);
      if (childFen == null) continue;

      // Get SAN from Lichess data or compute it
      String san = line.moveUci;
      if (lichess != null) {
        final lichessMove = lichess.moves
            .where((m) => m.uci == line.moveUci)
            .firstOrNull;
        if (lichessMove != null) {
          san = lichessMove.san;
        }
      }
      if (san == line.moveUci) {
        san = uciToSan(node.fen, line.moveUci);
      }

      final childIsWhite = isWhiteToMove(childFen);
      final childEvalStm = whiteToMove ? -line.effectiveCp : line.effectiveCp;

      final child = run.makeChild(
        parent: node,
        fen: childFen,
        san: san,
        uci: line.moveUci,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      child.engineEvalCp = childEvalStm;
      run.evalResolver.cacheEvalWhite(
        childFen,
        childIsWhite ? childEvalStm : -childEvalStm,
        config.evalDepth,
      );

      // Enrich with Lichess stats
      if (lichess != null) {
        final lm = lichess.moves
            .where((m) => m.uci == line.moveUci)
            .firstOrNull;
        if (lm != null) {
          child.setLichessStats(lm.white, lm.black, lm.draws);
        }
      }

      // Line 0 only: stash engine's preferred opponent reply on the child
      // (opponent-to-move position after our best move).
      if (line.pvNumber == 1 && line.pv.length >= 2) {
        child.pvContinuationMove = line.pv[1];
      }

      run.emitNodeProgress(child);
    }

    await injectSetupCandidates(node, bestCpWhite: bestCp);

    // Populate maia_frequency on our-move children.  C gates this on
    // `populate_maia_frequency` (novelty > 0 || find_traps); Dart always
    // populates when Maia is available since the data is useful for both
    // novelty scoring and trap-line display.
    if (MaiaFactory.isAvailable &&
        MaiaFactory.instance != null &&
        node.children.isNotEmpty) {
      try {
        final maiaResult = await MaiaFactory.instance!.evaluate(
          node.fen,
          config.maiaElo,
        );
        run.stats.maiaEvals++;
        if (maiaResult.policy.isNotEmpty) {
          for (final child in node.children) {
            final freq = maiaResult.policy[child.moveUci];
            if (freq != null) {
              child.maiaFrequency = freq;
            }
          }
        }
      } catch (_) {
        // Maia frequency is best-effort
      }
    }

    final incumbent = assignOurMovePriorities(node);

    // Coverage-only: the answer is the deliverable — children stay
    // unexplored leaves so a future resume with more budget can deepen them.
    if (coverageOnly) return;

    // Fast: only the incumbent and gap-qualifying alternatives grow
    // subtrees; the rest stay evaluated leaves for selection.
    for (final child in ourChildrenToExpand(node, incumbent)) {
      if (run.isCancelled) break;
      queue.add(child);
    }
  }
}
