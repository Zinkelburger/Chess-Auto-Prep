/// End-of-build coverage sweep: no silent holes.
///
/// Every our-turn node in the final tree must have at least one answer,
/// carry an explicit prune reason, or transpose to an answered position.
/// Dangling our-turn leaves (left by the node budget, the search floor, or
/// maxPly parity) whose incoming opponent move clears
/// [TreeBuildConfig.coverMinProb] get a coverage-only expansion; the rest
/// are removed so their mass returns honestly to the expectimax tail term
/// instead of ending exported lines on an unanswered opponent move.
library;

import '../chess_core/generation/build_tree_node.dart';
import 'generation/build_run.dart';
import 'generation/fen_map.dart';
import 'generation/frontier_queue.dart';
import 'generation/generation_config.dart';
import 'generation/lanes.dart';
import 'generation/node_expander.dart';
import 'generation/tree_prune.dart';

/// What one sweep did.
class CoverageSweepResult {
  final int answered;
  final int removed;

  /// Holes worth answering that the sweep's time grace ran out on; they are
  /// removed like the rest.
  final int outOfTime;

  /// The leaves removed, recorded because the sweep otherwise deletes
  /// silently and "was this line ever generated?" becomes unanswerable.
  final List<PrunedLine> removedLines;

  const CoverageSweepResult({
    required this.answered,
    required this.removed,
    required this.outOfTime,
    required this.removedLines,
  });

  static const none = CoverageSweepResult(
    answered: 0,
    removed: 0,
    outOfTime: 0,
    removedLines: [],
  );

  /// Holes closed, answered or removed.
  int get closed => answered + removed;
}

/// Runs the sweep over one [BuildRun]'s tree; see the library comment.
class CoverageSweep {
  CoverageSweep(this.run, this.expander);

  final BuildRun run;
  final NodeExpander expander;

  TreeBuildConfig get _config => run.config;

  Future<CoverageSweepResult> sweep() async {
    if (_config.coverMinProb <= 0.0) return CoverageSweepResult.none;

    final dangling = <BuildTreeNode>[];
    void collect(BuildTreeNode node) {
      for (final child in node.children) {
        collect(child);
      }
      if (node.ply == 0 || node.children.isNotEmpty) return;
      if (node.isWhiteToMove != _config.playAsWhite) return; // tail-covered
      if (node.pruneReason != PruneReason.none) return; // explicit prune
      dangling.add(node);
    }

    collect(run.tree.root);
    if (dangling.isEmpty) return CoverageSweepResult.none;

    // One expansion per position: group duplicates so the answer lands on
    // the canonical node and transposition leaves resolve through it.
    final groups = <String, List<BuildTreeNode>>{};
    for (final n in dangling) {
      (groups[canonicalizeFen(n.fen)] ??= []).add(n);
    }

    final tally = _Tally();
    final throwawayQueue = FrontierQueue(bestFirst: false);

    // Holes are independent positions, so they are answered [expansionLanes]
    // at a time: one recorded run swept 152 minutes for 4,590 holes, one
    // MultiPV search after another on a single worker.
    await runLanes(
      groups.values.toList(),
      lanes: run.expansionLanes,
      stop: () => run.isCancelled,
      task: (group) => _sweepGroup(group, throwawayQueue, tally),
    );

    if (tally.answered > 0 || tally.removed > 0) {
      run.log(
        'Coverage sweep: ${tally.answered} holes answered, '
        '${tally.removed} uncovered leaves removed'
        '${tally.outOfTime > 0 ? ', ${tally.outOfTime} left unanswered (out of time)' : ''}',
      );
    }
    return CoverageSweepResult(
      answered: tally.answered,
      removed: tally.removed,
      outOfTime: tally.outOfTime,
      removedLines: tally.removedLines,
    );
  }

  /// Answer or remove one equivalence group of dangling our-turn leaves.
  Future<void> _sweepGroup(
    List<BuildTreeNode> group,
    FrontierQueue throwawayQueue,
    _Tally tally,
  ) async {
    final config = _config;
    await run.waitIfPaused();
    if (run.isCancelled) return;
    // Past the budget's sweep grace we stop *answering* holes but keep
    // walking, so the leaves we never got to are still removed rather than
    // left dangling on an unanswered opponent move.
    final graced = !run.sweepBudgetExhausted;

    final canonical = run.fenMap.getCanonical(group.first.fen);
    if (canonical != null && !group.contains(canonical)) {
      // The position lives elsewhere in the tree: answered there, or
      // explicitly pruned there — these leaves resolve via transposition.
      if (canonical.children.isNotEmpty ||
          canonical.pruneReason != PruneReason.none) {
        return;
      }
    }

    // Representative: the registered canonical when it dangles here,
    // else the most-reachable member (registered for future resolution).
    final rep = (canonical != null && group.contains(canonical))
        ? canonical
        : (group..sort(
                (a, b) =>
                    b.cumulativeProbability.compareTo(a.cumulativeProbability),
              ))
              .first;
    run.fenMap.putCanonical(rep.fen, rep);

    // The hole is worth answering if any path into this position carries
    // an opponent move at/above the coverage floor.
    var maxProb = 0.0;
    for (final n in group) {
      if (n.moveProbability > maxProb) maxProb = n.moveProbability;
    }
    for (final t in run.fenMap.getTranspositions(rep.fen)) {
      if (t.moveProbability > maxProb) maxProb = t.moveProbability;
    }

    final worthAnswering = maxProb >= config.coverMinProb;
    if (worthAnswering && !graced) tally.outOfTime++;
    if (worthAnswering && graced) {
      final canExpand =
          config.buildMode == BuildMode.maiaDbExplore ||
          run.pool.workerCount > 0;
      if (config.buildMode == BuildMode.maiaDbExplore) {
        await run.evalResolver.ensureEval(
          rep,
          config,
          fenMap: run.fenMap,
          pool: run.pool,
          dbOnly: true,
        );
      }
      if (canExpand) {
        await expander.expandOurMove(rep, throwawayQueue, coverageOnly: true);
      }
      run.markExplored(rep);
      if (rep.children.isNotEmpty) {
        tally.answered++;
        return; // duplicates resolve via transposition
      }
      // Now explicitly flagged (eval window) — keep, it's not silent.
      if (rep.pruneReason != PruneReason.none) return;
    }

    // Below the floor, or the expansion produced no answer: remove the
    // whole equivalence group so no line ends on an unanswered move.
    for (final n in group) {
      tally.removedLines.add(PrunedLine.fromNode(n));
      run.removeLeaf(n);
      tally.removed++;
    }
  }
}

/// Counters the sweep's lanes share.
class _Tally {
  int answered = 0;
  int removed = 0;
  int outOfTime = 0;
  final List<PrunedLine> removedLines = [];
}
