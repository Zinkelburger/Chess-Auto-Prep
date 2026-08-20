part of 'node_expander.dart';

// ── Maia + DB our-move expansion ─────────────────────────────────────────

class MaiaDbExpander extends NodeExpander {
  MaiaDbExpander(super.run);

  @override
  Future<void> expandOurMove(
    BuildTreeNode node,
    FrontierQueue queue, {
    bool coverageOnly = false,
  }) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      run.log('Maia unavailable — cannot run maiaDbExplore mode');
      return;
    }

    // Window prune using the DB eval set by the build loop. Even when it
    // fires the node still gets a move below — see [_addFallbackOurMove].
    final windowStop = evalWindowPrune(node, config);

    final sw = Stopwatch()..start();
    final MaiaResult maiaResult;
    try {
      maiaResult = await MaiaFactory.instance!.evaluate(
        node.fen,
        config.maiaElo,
      );
    } catch (e) {
      run.log('Maia eval failed @ ${node.fen}: $e');
      return;
    }
    run.stats.maiaEvals++;
    run.stats.maiaTotalMs += sw.elapsedMilliseconds;
    if (maiaResult.policy.isEmpty) return;

    final sortedMoves = maiaResult.policy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Fast: candidate count shrinks with reach priority, like MultiPV.
    final maxCandidates = config
        .effectiveMultipv(effectiveSearchPriority(node))
        .clamp(1, TreeBuildConfig.maxOurCandidates);
    final bestCpWhite = node.hasEngineEval
        ? (node.isWhiteToMove ? node.engineEvalCp! : -node.engineEvalCp!)
        : null;

    int added = 0;
    for (final entry
        in windowStop ? const <MapEntry<String, double>>[] : sortedMoves) {
      if (added >= maxCandidates) break;
      final uci = entry.key;
      final prob = entry.value;
      if (prob < config.maiaMinProb) continue;

      final childFen = playUciMove(node.fen, uci);
      if (childFen == null) continue;

      // Child eval from DB only — skip candidates with no database coverage.
      final childEval = await run.evalResolver.lookupDbEvalWhite(
        childFen,
        config,
      );
      if (childEval == null) continue;

      final childIsWhite = isWhiteToMove(childFen);
      final childCpWhite = childEval.$1;

      if (bestCpWhite != null) {
        final evalLoss = bestCpWhite - childCpWhite;
        if (evalLoss > config.maxEvalLossCp) continue;
      }

      final san = uciToSan(node.fen, uci);
      final child = run.makeChild(
        parent: node,
        fen: childFen,
        san: san,
        uci: uci,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      child.maiaFrequency = prob;
      child.engineEvalCp = childIsWhite ? childCpWhite : -childCpWhite;
      run.evalResolver.cacheEvalWhite(childFen, childCpWhite, childEval.$2);

      added++;
      run.emitNodeProgress(child);
    }

    // Every gate in that loop is a `continue` — an unpopular move, a
    // position the database has never seen, an eval outside the window — so
    // a node can come out of it with nothing. This is our turn, though: the
    // opponent has moved and the repertoire is being asked what to play, and
    // "nothing" is not an answer it is allowed to give. Fall back to the move
    // Maia thinks most likely, eval or no eval.
    if (node.children.isEmpty) {
      await _addFallbackOurMove(node, sortedMoves);
    }

    await injectSetupCandidates(node, bestCpWhite: bestCpWhite);
    await injectMasterCandidates(node, bestCpWhite: bestCpWhite);
    await injectTransferCandidate(node, bestCpWhite: bestCpWhite);
    await injectPinnedCandidate(node);

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

  /// Last-resort our-move: the highest-policy legal move, with whatever eval
  /// the database can offer and none required. Used only when every ordinary
  /// candidate was filtered out.
  Future<void> _addFallbackOurMove(
    BuildTreeNode node,
    List<MapEntry<String, double>> sortedMoves,
  ) async {
    for (final entry in sortedMoves) {
      final childFen = playUciMove(node.fen, entry.key);
      if (childFen == null) continue;

      final child = run.makeChild(
        parent: node,
        fen: childFen,
        san: uciToSan(node.fen, entry.key),
        uci: entry.key,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      child.maiaFrequency = entry.value;

      final childEval = await run.evalResolver.lookupDbEvalWhite(
        childFen,
        config,
      );
      if (childEval != null) {
        final childCpWhite = childEval.$1;
        child.engineEvalCp = isWhiteToMove(childFen)
            ? childCpWhite
            : -childCpWhite;
        run.evalResolver.cacheEvalWhite(childFen, childCpWhite, childEval.$2);
      }

      run.emitNodeProgress(child);
      return;
    }
  }
}
