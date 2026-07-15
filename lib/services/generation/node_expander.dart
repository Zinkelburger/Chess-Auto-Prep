/// Per-mode node expansion strategies for the tree builder.
///
/// The build loop (`TreeBuildService._processBuildNode`) owns the plumbing
/// every mode shares — coverage floor, probability/budget floors, eval
/// window, transposition detection.  What differs per [BuildMode] is how a
/// node grows children, and that lives here behind [NodeExpander]:
///
///   - [StockfishExpander] (`BuildMode.stockfishExpectimax`): our moves
///     from Stockfish MultiPV, opponent moves from Lichess stats with a
///     Maia fallback (or Maia only).
///   - [MaiaDbExpander] (`BuildMode.maiaDbExplore`): our moves from Maia's
///     policy filtered to positions with database evals; same opponent
///     sources.
///
/// Adding a build mode means adding a subclass, not another copy of the
/// expansion plumbing.  The opponent-children loop in particular exists
/// exactly once ([addOpponentChildren]) — its coverage-floor semantics were
/// historically copy-pasted per source and had already drifted.
library;

import '../../models/build_tree_node.dart';
import '../../models/explorer_response.dart';
import '../../utils/chess_utils.dart' show playUciMove, sanToUci, uciToSan;
import '../../utils/fen_utils.dart';
import '../maia_factory.dart';
import '../maia_service.dart';
import 'build_run.dart';
import 'frontier_queue.dart';
import 'generation_config.dart';
import 'opponent_prior.dart';
import 'setup_bias.dart';

/// Move probability assigned to an engine-injected PV continuation when
/// Maia has no opinion on it.  Small but non-zero: the move must survive
/// probability floors so the engine's expected reply is present in the
/// tree, without meaningfully distorting the expectimax tail mass.
const double kPvInjectEpsilon = 0.01;

/// Apply the eval window to [node]: outside [TreeBuildConfig.minEvalCp] /
/// [TreeBuildConfig.maxEvalCp] the node gets an explicit [PruneReason] and
/// true is returned (caller stops expanding it).  No-op without an eval.
bool evalWindowPrune(BuildTreeNode node, TreeBuildConfig config) {
  if (!node.hasEngineEval) return false;
  final evalUs = node.evalForUs(config.playAsWhite);
  if (evalUs > config.maxEvalCp) {
    node.pruneReason = PruneReason.evalTooHigh;
    node.pruneEvalCp = evalUs;
    return true;
  }
  if (evalUs < config.minEvalCp) {
    node.pruneReason = PruneReason.evalTooLow;
    node.pruneEvalCp = evalUs;
    return true;
  }
  return false;
}

/// Add opponent children to [node] from probability-ranked [candidates].
///
/// This is the single implementation of the opponent fan-out policy, shared
/// by every candidate source (Lichess stats, Maia policy, PGN frequency
/// map).  Per candidate, in order:
///
///   1. Coverage floor: a reply at/above [TreeBuildConfig.coverMinProb]
///      local probability bypasses every other filter — it must exist in
///      the tree or the no-silent-holes guarantee breaks.
///   2. Node budget ([respectMaxNodes]), stopping the fan-out.
///   3. Noise filter: fewer than [minGames] observations (skipped while
///      Dirichlet smoothing is on — the prior replaces it).
///   4. Per-move probability floor [minMoveProb].
///   5. Fan-out caps: [maxChildren] count and [massTarget] cumulative
///      probability mass, both stopping the fan-out.
///   6. Reach floor: cumulative probability below
///      [TreeBuildConfig.minProbability] skips the move.
///
/// Children get raw (unrenormalized) probabilities — Σpᵢ ≤ 1 — because the
/// expectimax tail term accounts for uncovered mass; renormalizing would
/// silently bias V.  [attachStats] copies per-move W/B/D onto children
/// (Lichess only — frequency-map counts carry no outcome split worth
/// storing).  [onChild] runs for each added child (e.g. direct enqueue).
void addOpponentChildren({
  required BuildRun run,
  required BuildTreeNode node,
  required List<SmoothedMove> candidates,
  required bool smoothing,
  int minGames = 0,
  double minMoveProb = 0.0,
  int maxChildren = 0,
  double massTarget = 0.0,
  bool respectMaxNodes = false,
  bool attachStats = false,
  bool emitProgressPerChild = true,
  void Function(BuildTreeNode child)? onChild,
}) {
  final config = run.config;
  final basePri = effectiveSearchPriority(node);
  int childrenAdded = 0;
  double massCovered = 0.0;

  for (final move in candidates) {
    final prob = move.probability;
    final newCumul = node.cumulativeProbability * prob;
    final covered = config.coverMinProb > 0.0 && prob >= config.coverMinProb;
    if (!covered) {
      if (respectMaxNodes &&
          config.maxNodes > 0 &&
          run.tree.totalNodes >= config.maxNodes) {
        break;
      }
      if (!smoothing && move.games < minGames) continue;
      if (prob < minMoveProb) continue;
      if (maxChildren > 0 && childrenAdded >= maxChildren) break;
      if (massTarget > 0.0 && massCovered >= massTarget) break;
      if (newCumul < config.minProbability) continue;
    }

    final childFen = playUciMove(node.fen, move.uci);
    if (childFen == null) continue;

    final san = move.san.isNotEmpty ? move.san : uciToSan(node.fen, move.uci);
    final child = run.makeChild(
      parent: node,
      fen: childFen,
      san: san,
      uci: move.uci,
    );
    if (child == null) continue;

    child.moveProbability = prob;
    child.cumulativeProbability = newCumul;
    child.searchPriority = basePri * prob;
    if (attachStats && move.games > 0) {
      child.setLichessStats(move.whiteWins, move.blackWins, move.draws);
    }
    childrenAdded++;
    massCovered += prob;

    onChild?.call(child);
    if (emitProgressPerChild) run.emitNodeProgress(child);
  }
}

/// Maia policy for Dirichlet smoothing, or empty when smoothing is off,
/// Maia is unavailable, or [totalGames] is large enough that the prior's
/// weight would be negligible (saves the inference).
///
/// Top-level because both the [NodeExpander]s and the PGN frequency-map
/// build (which has no expander) smooth opponent frequencies the same way.
Future<Map<String, double>> maiaPolicyForSmoothing(
  BuildRun run,
  String fen,
  int totalGames,
) async {
  final config = run.config;
  if (!smoothingWorthwhile(totalGames, config.maiaPriorGames)) {
    return const {};
  }
  if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
    return const {};
  }
  try {
    final sw = Stopwatch()..start();
    final result = await MaiaFactory.instance!.evaluate(fen, config.maiaElo);
    run.stats.maiaEvals++;
    run.stats.maiaTotalMs += sw.elapsedMilliseconds;
    return result.policy;
  } catch (e) {
    run.log('Maia prior lookup failed @ $fen: $e');
    return const {};
  }
}

/// Strategy for growing a node's children in one [BuildMode].
abstract class NodeExpander {
  final BuildRun run;

  NodeExpander(this.run);

  /// The expander for [run]'s configured build mode.
  ///
  /// `BuildMode.dbExplorer` never reaches here — it has its own entry point
  /// driven by the PGN frequency map rather than per-node move sources.
  factory NodeExpander.forRun(BuildRun run) => switch (run.config.buildMode) {
    BuildMode.maiaDbExplore => MaiaDbExpander(run),
    _ => StockfishExpander(run),
  };

  TreeBuildConfig get config => run.config;

  /// Expand an our-move node: generate candidates, attach evals, assign
  /// best-first priorities, and enqueue the children that deserve subtrees.
  ///
  /// [coverageOnly]: the node exists to answer a coverage-floor opponent
  /// move — add evaluated children but grow no subtrees (they stay
  /// unexplored leaves a future resume can deepen).
  Future<void> expandOurMove(
    BuildTreeNode node,
    FrontierQueue queue, {
    bool coverageOnly = false,
  });

  /// Expand an opponent node from a single source (Lichess stats, falling
  /// back to Maia; or Maia only) and enqueue all children — eval-window
  /// checks happen when each child is dequeued.
  Future<void> expandOpponentMove(
    BuildTreeNode node,
    FrontierQueue queue,
  ) async {
    if (config.maiaOnly) {
      await _addOpponentChildrenFromMaia(node, maiaForInject: true);
    } else {
      await _addOpponentChildrenFromLichess(node);
      // Fall back to Maia when the Lichess DB has no data for this position
      if (node.children.isEmpty) {
        await _addOpponentChildrenFromMaia(node, maiaForInject: true);
      } else {
        await _maybeInjectPvContinuation(node);
      }
    }

    if (node.children.isEmpty) return;

    for (final child in List.of(node.children)) {
      if (run.isCancelled) break;
      queue.add(child);
    }
  }

  // ── Shared opponent sources ─────────────────────────────────────────────

  Future<void> _addOpponentChildrenFromLichess(BuildTreeNode node) async {
    final response = await run.evalResolver.getDbData(node.fen, config);
    if (response == null || response.totalGames == 0) return;

    final totalW = response.moves.fold(0, (s, m) => s + m.white);
    final totalB = response.moves.fold(0, (s, m) => s + m.black);
    final totalD = response.moves.fold(0, (s, m) => s + m.draws);
    node.setLichessStats(totalW, totalB, totalD);

    // λ-smoothing: blend DB counts with Maia's policy so sparsely covered
    // positions degrade continuously toward Maia instead of trusting the
    // frequencies from a handful of games (or falling off a hard cliff).
    final maiaPolicy = await maiaPolicyForSmoothing(
      run,
      node.fen,
      response.totalGames,
    );
    final smoothing = maiaPolicy.isNotEmpty;

    final candidates = smoothOpponentMoves(
      observed: [
        for (final m in response.moves)
          ObservedMove(
            uci: m.uci,
            san: m.san,
            games: m.total,
            whiteWins: m.white,
            blackWins: m.black,
            draws: m.draws,
          ),
      ],
      totalGames: response.totalGames,
      maiaPolicy: maiaPolicy,
      priorGames: smoothing ? config.maiaPriorGames : 0.0,
    );

    // Fast halves the fan-out at cold nodes; coverage-floor replies bypass
    // the cap inside addOpponentChildren, so no silent holes.
    addOpponentChildren(
      run: run,
      node: node,
      candidates: candidates,
      smoothing: smoothing,
      minGames: config.minGames,
      maxChildren: config.effectiveOppMaxChildren(
        effectiveSearchPriority(node),
      ),
      massTarget: config.oppMassTarget,
      attachStats: true,
    );
  }

  Future<void> _addOpponentChildrenFromMaia(
    BuildTreeNode node, {
    bool maiaForInject = false,
  }) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) return;

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
    if (maiaResult.policy.isEmpty) {
      if (maiaForInject) {
        await _maybeInjectPvContinuation(node);
      }
      return;
    }

    final sortedMoves = maiaResult.policy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    addOpponentChildren(
      run: run,
      node: node,
      candidates: [
        for (final e in sortedMoves)
          SmoothedMove(uci: e.key, san: '', probability: e.value, games: 0),
      ],
      smoothing: false,
      minMoveProb: config.maiaMinProb,
      maxChildren: config.effectiveOppMaxChildren(
        effectiveSearchPriority(node),
      ),
      massTarget: config.oppMassTarget,
    );

    if (maiaForInject) {
      await _maybeInjectPvContinuation(node, maiaPolicy: maiaResult.policy);
    }
  }

  /// Ensure the engine's preferred opponent reply (stashed on the node by
  /// the our-move MultiPV pass) exists as a child, with Maia's probability
  /// for it when available, else [kPvInjectEpsilon].
  Future<void> _maybeInjectPvContinuation(
    BuildTreeNode node, {
    Map<String, double>? maiaPolicy,
  }) async {
    final pvUci = node.pvContinuationMove;
    if (pvUci == null || pvUci.isEmpty) return;

    if (node.children.any((c) => c.moveUci == pvUci)) return;

    final childFen = playUciMove(node.fen, pvUci);
    if (childFen == null) return;

    final san = uciToSan(node.fen, pvUci);
    final child = run.makeChild(
      parent: node,
      fen: childFen,
      san: san,
      uci: pvUci,
    );
    if (child == null) return;

    double prob = maiaPolicy?[pvUci] ?? -1.0;
    if (prob < 0 && MaiaFactory.isAvailable && MaiaFactory.instance != null) {
      try {
        final maiaResult = await MaiaFactory.instance!.evaluate(
          node.fen,
          config.maiaElo,
        );
        run.stats.maiaEvals++;
        prob = maiaResult.policy[pvUci] ?? -1.0;
      } catch (_) {
        // Best-effort Maia lookup for injected move probability.
      }
    }
    if (prob < 0) prob = kPvInjectEpsilon;

    child.moveProbability = prob;
    child.cumulativeProbability = node.cumulativeProbability * prob;
    child.searchPriority = effectiveSearchPriority(node) * prob;
    child.engineInjected = true;

    run.emitNodeProgress(child);
  }

  // ── Shared our-move plumbing ────────────────────────────────────────────

  /// Preferred-setup candidate injection: quiet system moves (h4, Nh3, ...)
  /// are often missing from Maia/MultiPV top-N, so the selection tie-break
  /// would have nothing to choose.  Evaluate any legal setup move not
  /// already a candidate and add it, subject to the same eval-loss window
  /// as regular candidates.  [bestCpWhite] is the best candidate eval in
  /// white-POV centipawns (null = no reference, window not applied).
  Future<void> injectSetupCandidates(
    BuildTreeNode node, {
    required int? bestCpWhite,
  }) async {
    final setup = parseSetupMoves(config.setupMoves);
    if (setup.isEmpty) return;
    final whiteToMove = isWhiteToMove(node.fen);

    for (final san in setup) {
      final uci = sanToUci(node.fen, san);
      if (uci == null) continue; // not legal here (or already played)
      final childFen = playUciMove(node.fen, uci);
      if (childFen == null) continue;
      if (node.children.any((c) => c.fen == childFen || c.moveUci == uci)) {
        continue; // already a candidate
      }

      // Child eval: Stockfish when available, else the DB eval chain
      // (matches how each build mode evaluates regular candidates).
      final int childCpWhite;
      final int evalDepthUsed;
      if (config.usesStockfish && run.pool.workerCount > 0) {
        final result = await run.pool.evaluateFen(childFen, config.evalDepth);
        run.stats.sfMultipvCalls++;
        final childIsWhite = isWhiteToMove(childFen);
        childCpWhite = childIsWhite ? result.effectiveCp : -result.effectiveCp;
        evalDepthUsed = config.evalDepth;
      } else {
        final dbEval = await run.evalResolver.lookupDbEvalWhite(
          childFen,
          config,
        );
        if (dbEval == null) continue;
        childCpWhite = dbEval.$1;
        evalDepthUsed = dbEval.$2;
      }

      if (bestCpWhite != null) {
        final evalLoss = whiteToMove
            ? bestCpWhite - childCpWhite
            : childCpWhite - bestCpWhite;
        if (evalLoss > config.maxEvalLossCp) continue;
      }

      final child = run.makeChild(
        parent: node,
        fen: childFen,
        san: uciToSan(node.fen, uci),
        uci: uci,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      final childIsWhite = isWhiteToMove(childFen);
      child.engineEvalCp = childIsWhite ? childCpWhite : -childCpWhite;
      run.evalResolver.cacheEvalWhite(childFen, childCpWhite, evalDepthUsed);

      run.emitNodeProgress(child);
    }
  }

  /// Best-first priorities at an our-move node: the incumbent (best eval for
  /// us at expansion time) inherits the parent's priority; alternatives are
  /// discounted so they stay shallow unless the mainline budget runs out.
  /// Returns the incumbent (null when the node has no children).
  BuildTreeNode? assignOurMovePriorities(BuildTreeNode node) {
    if (node.children.isEmpty) return null;
    final basePri = effectiveSearchPriority(node);

    BuildTreeNode? incumbent;
    var bestCp = 0;
    for (final child in node.children) {
      final cp = child.evalForUs(config.playAsWhite);
      if (incumbent == null || cp > bestCp) {
        bestCp = cp;
        incumbent = child;
      }
    }
    for (final child in node.children) {
      child.searchPriority = identical(child, incumbent)
          ? basePri
          : basePri * config.ourAltDiscount;
    }
    return incumbent;
  }

  /// Fast alternative gating: which our-move children deserve a subtree.
  ///
  /// The incumbent always expands.  Alternatives expand only while within
  /// [TreeBuildConfig.fastAltGapCp] of the incumbent's eval, best first, at
  /// most [TreeBuildConfig.fastMaxExpandedAlts] of them — a move 30+cp
  /// behind only wins the argmax if deep search flips the ordering by more
  /// than the gap, which the verification pass would catch anyway.  Gated
  /// children stay evaluated leaves: selection still sees them, and a
  /// resume with more budget may deepen them.
  ///
  /// Everything expands under Pure (exhaustive by contract), under trappy
  /// selection (worse-eval moves are the point and need searched subtrees),
  /// and for preferred-setup candidates (the setup bias needs them alive).
  List<BuildTreeNode> ourChildrenToExpand(
    BuildTreeNode node,
    BuildTreeNode? incumbent,
  ) {
    final children = List.of(node.children);
    if (config.searchAlgorithm == SearchAlgorithm.pure ||
        config.selectionMode == SelectionMode.trappy ||
        config.fastAltGapCp <= 0 ||
        incumbent == null ||
        !incumbent.hasEngineEval) {
      return children;
    }

    final setupSans = parseSetupMoves(config.setupMoves).toSet();
    final incumbentCp = incumbent.evalForUs(config.playAsWhite);
    final alts =
        [
          for (final c in children)
            if (!identical(c, incumbent)) c,
        ]..sort(
          (a, b) => b
              .evalForUs(config.playAsWhite)
              .compareTo(a.evalForUs(config.playAsWhite)),
        );

    final expand = <BuildTreeNode>[incumbent];
    var altsTaken = 0;
    for (final alt in alts) {
      if (setupSans.contains(alt.moveSan)) {
        expand.add(alt);
        continue;
      }
      if (!alt.hasEngineEval) continue;
      final gapCp = incumbentCp - alt.evalForUs(config.playAsWhite);
      if (config.expandAlternative(
        gapCp: gapCp,
        altsAlreadyExpanded: altsTaken,
      )) {
        expand.add(alt);
        altsTaken++;
      }
    }
    return expand;
  }
}

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

    // Window prune using the DB eval set by the build loop.
    if (evalWindowPrune(node, config)) return;

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
    for (final entry in sortedMoves) {
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

    await injectSetupCandidates(node, bestCpWhite: bestCpWhite);

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
