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
    // Fast: MultiPV shrinks with reach priority; Pure: constant.  The root —
    // and, with "Wide opening search", the first [openingWidthPlies] of our
    // moves — always gets the wide [rootMultipv] sweep so early alternatives
    // are never missed (they can't be recovered later).
    final nodePriority = effectiveSearchPriority(node);
    final wideOpening = node.ply == 0 || config.widensOpeningAtPly(node.ply);
    final mpvCount = wideOpening
        ? config.rootMultipv
        : config.effectiveMultipv(nodePriority);
    final whiteToMove = node.isWhiteToMove;

    // Maia's view of this position is wanted for every child's
    // `maiaFrequency`.  Inference runs on its own isolate, so it is started
    // here and collected after the engine work: the two overlap instead of
    // queueing behind one another.
    final maiaPolicy = _maiaPolicyFor(node.fen);

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
    //
    // Even when it fires we leave the engine's move behind. This node is our
    // turn, which means the opponent has already played and the repertoire is
    // being asked a question; answering "nothing" is not available to us. The
    // prune reason stays on the node, so the move is recorded without the
    // subtree that would follow it — for a won position that reads as "play
    // this, then it is just technique".
    if (evalWindowPrune(node, config)) {
      _addBestMove(node, discovery.lines.first, whiteToMove: whiteToMove);
      return;
    }

    // Filter candidates by eval loss (direction depends on STM).  Fast
    // halves the window at cold nodes; the root and the wide-opening band
    // keep the full window.
    final bestCp = discovery.lines.first.effectiveCp;
    final evalLossWindow = wideOpening
        ? config.maxEvalLossCp
        : config.effectiveMaxEvalLossCp(nodePriority);

    for (final line in discovery.lines) {
      if (line.moveUci.isEmpty) continue;
      final evalLoss = whiteToMove
          ? bestCp - line.effectiveCp
          : line.effectiveCp - bestCp;
      // Line 0 loses nothing against itself, so the best move always clears
      // this gate however bad the position is. That is deliberate and
      // load-bearing: a position the opponent forced on us gets an answer
      // even when every answer is grim. The window only decides how many
      // *alternatives* ride along beside it.
      if (evalLoss > evalLossWindow) continue;
      _addBestMove(node, line, whiteToMove: whiteToMove);
    }

    // Belt and braces for the same rule: every gate above is a `continue`,
    // so a node can come out of the loop with nothing at all. The best move
    // by definition loses nothing against itself and should always survive —
    // if it somehow did not, take it anyway.
    if (node.children.isEmpty) {
      _addBestMove(node, discovery.lines.first, whiteToMove: whiteToMove);
    }

    await injectCandidates(node, bestCpWhite: bestCp);

    // Populate maia_frequency on our-move children.  C gates this on
    // `populate_maia_frequency` (novelty > 0 || find_traps); Dart always
    // populates when Maia is available since the data is useful for both
    // novelty scoring and trap-line display.
    final policy = await maiaPolicy;
    if (policy.isNotEmpty) {
      for (final child in node.children) {
        final freq = policy[child.moveUci];
        if (freq != null) child.maiaFrequency = freq;
      }
    }

    final incumbent = assignOurMovePriorities(node);

    // Coverage-only: the answer is the deliverable — children stay
    // unexplored leaves so a future resume with more budget can deepen them.
    if (coverageOnly) return;

    // Fast: only the incumbent and gap-qualifying alternatives grow
    // subtrees; the rest stay evaluated leaves for selection.
    enqueueChildren(ourChildrenToExpand(node, incumbent), queue);
  }

  /// Maia's policy at [fen], or empty when Maia is unavailable or fails.
  /// Best-effort: a missing policy costs the naturalness annotation, never
  /// the expansion.
  Future<Map<String, double>> _maiaPolicyFor(String fen) async {
    final maia = MaiaFactory.instance;
    if (!MaiaFactory.isAvailable || maia == null) return const {};
    try {
      final result = await maia.evaluate(fen, config.maiaElo);
      run.stats.maiaEvals++;
      return result.policy;
    } catch (_) {
      return const {};
    }
  }

  /// Attach one MultiPV line to [node] as an our-move child. No gates: the
  /// caller has already decided this move belongs here.
  void _addBestMove(
    BuildTreeNode node,
    DiscoveryLine line, {
    required bool whiteToMove,
  }) {
    if (line.moveUci.isEmpty) return;
    final played = run.childMove(node, line.moveUci);
    if (played == null) return;

    final childEvalStm = whiteToMove ? -line.effectiveCp : line.effectiveCp;

    final child = run.makeChild(
      parent: node,
      fen: played.fen,
      san: played.san,
      uci: line.moveUci,
      position: played.after,
    );
    if (child == null) return;

    child.moveProbability = 1.0;
    child.cumulativeProbability = node.cumulativeProbability;
    child.engineEvalCp = childEvalStm;
    run.evalResolver.cacheEvalWhite(
      played.fen,
      child.isWhiteToMove ? childEvalStm : -childEvalStm,
      config.evalDepth,
    );

    // Line 0 only: stash engine's preferred opponent reply on the child
    // (opponent-to-move position after our best move).
    if (line.pvNumber == 1 && line.pv.length >= 2) {
      child.pvContinuationMove = line.pv[1];
    }

    run.emitNodeProgress(child);
  }
}
