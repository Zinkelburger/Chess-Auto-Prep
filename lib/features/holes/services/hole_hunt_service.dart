/// Adversarial hole hunt over a loaded repertoire tree.
///
/// Walks the repertoire from the ATTACKER's side (the color opposite the
/// repertoire's own) and emits exploitable findings:
///  - uncoveredStrongMove: engine-strong attacker moves the file has no
///    reply to,
///  - refutation: owner repertoire moves that concretely lose, with a
///    verified refutation PV,
///  - practicalTrap: end-of-line positions whose expectimax (practical)
///    eval is far better for the attacker than the raw engine eval.
///
/// Unlike the defensive audit this is not a breadth checklist: findings
/// carry an exploitScore (reach probability × gain) and the report is
/// meant to surface a handful of killer holes.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../models/opening_tree.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/eval_cache.dart';
import '../../../services/expectimax_line_service.dart';
import '../../../services/generation/eca_calculator.dart';
import '../../../services/generation/fen_map.dart';
import '../../../services/generation/generation_config.dart';
import '../../../services/maia_factory.dart';
import '../../../services/tree_build_service.dart';
import '../../../utils/chess_move_utils.dart' as move_utils;
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import 'hole_hunt_config.dart';
import 'hole_scoring.dart';

enum HoleHuntPhase { walking, traps }

/// Progress callback emitted periodically during a hunt.
typedef HoleHuntProgressCallback = void Function(HoleHuntProgress progress);

class HoleHuntProgress {
  final HoleHuntPhase phase;
  final int nodesChecked;
  final int totalNodes;
  final int leavesDone;
  final int leavesTotal;
  final int findingsCount;

  const HoleHuntProgress({
    required this.phase,
    this.nodesChecked = 0,
    this.totalNodes = 0,
    this.leavesDone = 0,
    this.leavesTotal = 0,
    this.findingsCount = 0,
  });

  /// The walk owns 0..0.7 of the bar, the trap pass 0.7..1.0.
  double get fraction {
    switch (phase) {
      case HoleHuntPhase.walking:
        final walkFraction = totalNodes > 0 ? nodesChecked / totalNodes : 0.0;
        return 0.7 * walkFraction.clamp(0.0, 1.0);
      case HoleHuntPhase.traps:
        final trapFraction = leavesTotal > 0 ? leavesDone / leavesTotal : 1.0;
        return 0.7 + 0.3 * trapFraction.clamp(0.0, 1.0);
    }
  }

  String get message {
    switch (phase) {
      case HoleHuntPhase.walking:
        return 'Walking $nodesChecked / $totalNodes positions';
      case HoleHuntPhase.traps:
        return 'Trap search $leavesDone / $leavesTotal leaves';
    }
  }
}

class HoleHuntService {
  final StockfishPool _pool = StockfishPool.instance;
  final EvalCache _evalCache = EvalCache.instance;

  /// Wall-clock budget per leaf expectimax build; enforced via the build's
  /// own isCancelled hook so the builder unwinds cleanly instead of being
  /// orphaned by a thrown timeout.
  static const Duration _trapBuildTimeout = Duration(seconds: 180);

  bool _cancelled = false;
  bool _paused = false;

  /// True when the most recent hunt skipped the trap pass because Maia was
  /// unavailable. Surfaced as a note in the report panel.
  bool get trapPassSkipped => _trapPassSkipped;
  bool _trapPassSkipped = false;

  void cancel() => _cancelled = true;
  void pause() => _paused = true;
  void resume() => _paused = false;

  /// Run a full hunt over [tree].
  ///
  /// [isWhiteRepertoire] is the color the repertoire file plays; the
  /// attacker is always the other color.
  Future<AuditResult> hunt({
    required OpeningTree tree,
    required bool isWhiteRepertoire,
    required HoleHuntConfig config,
    HoleHuntProgressCallback? onProgress,
    void Function(AuditFinding)? onFinding,
  }) async {
    _cancelled = false;
    _paused = false;
    _trapPassSkipped = false;
    final stopwatch = Stopwatch()..start();
    final findings = <AuditFinding>[];
    final leaves = <LeafEntry>[];
    final attackerIsWhite = !isWhiteRepertoire;

    int attackerNodes = 0;
    int ownerNodes = 0;
    int leafNodes = 0;
    int evalCacheHits = 0;
    int evalCacheMisses = 0;

    await _evalCache.init();

    void emit(AuditFinding f) {
      findings.add(f);
      onFinding?.call(f);
    }

    // ── Pass 1: BFS walk ─────────────────────────────────────────────────
    final totalNodes = _countNodes(tree.root, config.maxPly);
    final queue = Queue<_HuntQueueEntry>();
    queue.add(
      _HuntQueueEntry(
        node: tree.root,
        movePath: tree.root.getMovePath(),
        ply: 0,
        cumProb: 1.0,
      ),
    );

    int checked = 0;

    while (queue.isNotEmpty) {
      if (_cancelled) break;
      while (_paused && !_cancelled) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_cancelled) break;

      final entry = queue.removeFirst();
      final node = entry.node;
      if (entry.ply > config.maxPly) continue;

      checked++;
      if (checked % 5 == 0 || checked == totalNodes) {
        onProgress?.call(
          HoleHuntProgress(
            phase: HoleHuntPhase.walking,
            nodesChecked: checked,
            totalNodes: totalNodes,
            findingsCount: findings.length,
          ),
        );
      }

      final isWhiteTurn = node.fen.contains(' w ');
      final isOwnerTurn = isWhiteTurn == isWhiteRepertoire;

      if (node.children.isEmpty) {
        leafNodes++;
        leaves.add(
          LeafEntry(
            fen: node.fen,
            movePath: entry.movePath,
            cumProb: entry.cumProb,
          ),
        );
        continue;
      }

      if (isOwnerTurn) {
        ownerNodes++;
        final (hits, misses) = await _checkOwnerMoves(
          node: node,
          entry: entry,
          isWhiteRepertoire: isWhiteRepertoire,
          config: config,
          emit: emit,
        );
        evalCacheHits += hits;
        evalCacheMisses += misses;
      } else {
        attackerNodes++;
        await _checkAttackerCoverage(
          node: node,
          entry: entry,
          attackerIsWhite: attackerIsWhite,
          tree: tree,
          config: config,
          emit: emit,
        );
      }

      // Enqueue children. Inverted attenuation vs the audit: the attacker
      // steers (probability 1); the owner chooses among their alternatives.
      final parentTotal = node.children.values.fold<int>(
        0,
        (sum, c) => sum + c.gamesPlayed,
      );
      for (final childEntry in node.children.entries) {
        queue.add(
          _HuntQueueEntry(
            node: childEntry.value,
            movePath: [...entry.movePath, childEntry.key],
            ply: entry.ply + 1,
            cumProb: childProbability(
              isOwnerTurn: isOwnerTurn,
              childGames: childEntry.value.gamesPlayed,
              parentTotalGames: parentTotal,
              cumProb: entry.cumProb,
            ),
          ),
        );
      }
    }

    // ── Pass 2: leaf expectimax (practical traps) ────────────────────────
    if (!_cancelled) {
      await _trapPass(
        leaves: leaves,
        attackerIsWhite: attackerIsWhite,
        config: config,
        findingsCount: () => findings.length,
        onProgress: onProgress,
        emit: emit,
      );
    }

    stopwatch.stop();

    final ranked = rankByExploitScore(findings);
    onProgress?.call(
      HoleHuntProgress(
        phase: HoleHuntPhase.traps,
        nodesChecked: checked,
        totalNodes: totalNodes,
        leavesDone: 1,
        leavesTotal: 1,
        findingsCount: ranked.length,
      ),
    );

    return AuditResult(
      findings: ranked,
      nodesChecked: checked,
      ourMoveNodesChecked: attackerNodes,
      opponentNodesChecked: ownerNodes,
      leafNodesChecked: leafNodes,
      evalCacheHits: evalCacheHits,
      evalCacheMisses: evalCacheMisses,
      elapsed: stopwatch.elapsed,
    );
  }

  // ── Attacker coverage: strong moves the file has no reply to ──────────

  Future<void> _checkAttackerCoverage({
    required OpeningTreeNode node,
    required _HuntQueueEntry entry,
    required bool attackerIsWhite,
    required OpeningTree tree,
    required HoleHuntConfig config,
    required void Function(AuditFinding) emit,
  }) async {
    try {
      final discovery = await _pool.discoverMoves(
        fen: node.fen,
        depth: config.discoveryDepth,
        multiPv: config.discoveryMultiPv,
        isWhiteToMove: node.fen.contains(' w '),
      );
      if (discovery.lines.isEmpty) return;

      int toAttacker(int whiteCp) => attackerIsWhite ? whiteCp : -whiteCp;

      final bestWhiteCp = discovery.lines.first.effectiveCp;
      final bestAttackerCp = toAttacker(bestWhiteCp);
      _evalCache.putEvalCpWhite(node.fen, bestWhiteCp, config.discoveryDepth);

      for (final line in discovery.lines) {
        final san = move_utils.uciToSan(node.fen, line.moveUci);
        if (san == null) continue;
        if (node.children.containsKey(san)) continue; // covered

        final attackerCp = toAttacker(line.effectiveCp);
        if (bestAttackerCp - attackerCp > config.strongMoveWindowCp) continue;
        if (attackerCp < config.uncoveredMinAdvantageCp) continue;

        final gainCp = attackerCp.clamp(0, 1 << 20) + config.outOfBookBonusCp;
        emit(
          AuditFinding(
            type: AuditFindingType.uncoveredStrongMove,
            severity: attackerCp >= 100
                ? AuditSeverity.critical
                : (attackerCp >= 0
                      ? AuditSeverity.warning
                      : AuditSeverity.info),
            movePath: entry.movePath,
            fen: node.fen,
            missingMove: san,
            positionEvalCp: line.effectiveCp,
            bestMoveEvalCp: bestWhiteCp,
            cumulativeProbability: entry.cumProb,
            transposesIntoRepertoire: move_utils.doesMoveTranspose(
              node.fen,
              san,
              tree,
            ),
            exploitScore: exploitScoreOf(
              cumProb: entry.cumProb,
              gainCp: gainCp,
            ),
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HoleHunt] Discovery failed at ${node.fen}: $e');
      }
    }
  }

  // ── Owner moves: refutations with verified PV ──────────────────────────

  /// Returns (cacheHits, cacheMisses).
  Future<(int, int)> _checkOwnerMoves({
    required OpeningTreeNode node,
    required _HuntQueueEntry entry,
    required bool isWhiteRepertoire,
    required HoleHuntConfig config,
    required void Function(AuditFinding) emit,
  }) async {
    int cacheHits = 0;
    int cacheMisses = 0;
    try {
      final discovery = await _pool.discoverMoves(
        fen: node.fen,
        depth: config.discoveryDepth,
        multiPv: config.discoveryMultiPv,
        isWhiteToMove: node.fen.contains(' w '),
      );
      cacheMisses++;
      if (discovery.lines.isEmpty) return (cacheHits, cacheMisses);

      final bestWhiteCp = discovery.lines.first.effectiveCp;
      final bestSan = move_utils.uciToSan(
        node.fen,
        discovery.lines.first.moveUci,
      );
      _evalCache.putEvalCpWhite(node.fen, bestWhiteCp, config.discoveryDepth);

      int ownerLossOf(int whiteCp) =>
          isWhiteRepertoire ? bestWhiteCp - whiteCp : whiteCp - bestWhiteCp;

      for (final repEntry in node.children.entries) {
        final repSan = repEntry.key;
        final repUci = move_utils.sanToUci(node.fen, repSan);
        if (repUci == null) continue;

        int? repWhiteCp;
        for (final line in discovery.lines) {
          if (line.moveUci == repUci) {
            repWhiteCp = line.effectiveCp;
            break;
          }
        }
        if (repWhiteCp == null) {
          final (cp, hit, miss) = await move_utils.evalAfterMoveCached(
            _pool,
            _evalCache,
            node.fen,
            repUci,
            config.discoveryDepth,
          );
          repWhiteCp = cp;
          cacheHits += hit;
          cacheMisses += miss;
        }
        if (repWhiteCp == null) continue;

        if (ownerLossOf(repWhiteCp) < config.refutationThresholdCp) continue;

        // Deep single-PV verification on the position after the move —
        // yields both a trustworthy eval and the concrete refutation line.
        final childFen = repEntry.value.fen;
        final verify = await _pool.evaluateFen(childFen, config.verifyDepth);
        final childIsWhiteTurn = childFen.contains(' w ');
        final verifiedWhiteCp = childIsWhiteTurn
            ? (verify.scoreCp ?? 0)
            : -(verify.scoreCp ?? 0);
        _evalCache.putEvalCpWhite(
          childFen,
          verifiedWhiteCp,
          config.verifyDepth,
        );

        final verifiedLoss = ownerLossOf(verifiedWhiteCp);
        // Shallow-search artifact guard: the deep search must confirm at
        // least half the claimed loss.
        if (verifiedLoss < config.refutationThresholdCp / 2) continue;

        final pvSan = move_utils.uciPvToSan(childFen, verify.pv, maxPlies: 8);
        emit(
          AuditFinding(
            type: AuditFindingType.refutation,
            severity: AuditSeverity.critical,
            movePath: [...entry.movePath, repSan],
            fen: node.fen,
            ourMove: repSan,
            bestMove: bestSan,
            evalLossCp: verifiedLoss,
            positionEvalCp: verifiedWhiteCp,
            bestMoveEvalCp: bestWhiteCp,
            exploitLine: pvSan,
            cumulativeProbability: entry.cumProb,
            exploitScore: exploitScoreOf(
              cumProb: entry.cumProb,
              gainCp: verifiedLoss,
            ),
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HoleHunt] Owner check failed at ${node.fen}: $e');
      }
    }
    return (cacheHits, cacheMisses);
  }

  // ── Trap pass: expectimax the top leaves ───────────────────────────────

  Future<void> _trapPass({
    required List<LeafEntry> leaves,
    required bool attackerIsWhite,
    required HoleHuntConfig config,
    required int Function() findingsCount,
    required HoleHuntProgressCallback? onProgress,
    required void Function(AuditFinding) emit,
  }) async {
    if (config.trapLeafCount <= 0 || leaves.isEmpty) return;

    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      _trapPassSkipped = true;
      debugPrint('[HoleHunt] Trap pass skipped — Maia unavailable');
      return;
    }
    try {
      await MaiaFactory.instance!.initialize();
    } catch (e) {
      _trapPassSkipped = true;
      debugPrint('[HoleHunt] Trap pass skipped — Maia init failed: $e');
      return;
    }

    final selected = selectTopLeaves(leaves, config.trapLeafCount);
    final buildService = TreeBuildService();

    for (var i = 0; i < selected.length; i++) {
      if (_cancelled) return;
      while (_paused && !_cancelled) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_cancelled) return;

      onProgress?.call(
        HoleHuntProgress(
          phase: HoleHuntPhase.traps,
          leavesDone: i,
          leavesTotal: selected.length,
          findingsCount: findingsCount(),
        ),
      );

      final leaf = selected[i];
      final buildConfig = TreeBuildConfig(
        startFen: leaf.fen,
        playAsWhite: attackerIsWhite,
        maxPly: config.trapSearchPly,
        maxNodes: 800 * config.trapSearchPly,
        buildMode: BuildMode.stockfishExpectimax,
        // 1 UCI thread per worker — same reasoning as the on-the-fly
        // service: parallelism comes from pool workers, and >1 would
        // reconfigure workers other features rely on.
        engineThreads: 1,
        minProbability: 0.02,
        evalDepth: config.trapEvalDepth,
        maiaElo: config.maiaElo,
        useLichessDb: config.useLichessInTraps,
        ourMultipv: 4,
        oppMaxChildren: 4,
        oppMassTarget: 0.80,
        verifyFinal: false,
        // The defaults (0..200, root-anchored) prune attacker tries that
        // merely hold the raw eval — exactly the moves a practical trap is
        // made of. Widen the window; still root-anchored via relativeEval.
        minEvalCp: -200,
        maxEvalCp: 400,
      );

      try {
        final buildClock = Stopwatch()..start();
        final tree = await buildService.build(
          config: buildConfig,
          isCancelled: () =>
              _cancelled || buildClock.elapsed > _trapBuildTimeout,
          onProgress: (_) {},
        );
        if (_cancelled) return;
        if (tree.root.children.isEmpty) continue;

        final fenMap = FenMap()..populate(tree.root);
        final eca = ExpectimaxCalculator(config: buildConfig, fenMap: fenMap);
        eca.calculate(tree);

        final lines = generateExpectimaxLines(
          tree.root,
          buildConfig,
          eca,
          topLines: 1,
          maxPlies: config.trapSearchPly,
          fenMap: fenMap,
        );
        if (lines.isEmpty) continue;

        final top = lines.first;
        final rawCp = top.evalCp;
        final gap = top.expectedEvalCp - (rawCp ?? top.expectedEvalCp);
        if (gap < config.practicalGapThresholdCp) continue;

        emit(
          AuditFinding(
            type: AuditFindingType.practicalTrap,
            severity: gap >= config.practicalGapThresholdCp * 2
                ? AuditSeverity.critical
                : AuditSeverity.warning,
            movePath: leaf.movePath,
            fen: leaf.fen,
            positionEvalCp: rawCp,
            expectedEvalCp: top.expectedEvalCp,
            practicalGapCp: gap,
            exploitLine: top.movesSan,
            cumulativeProbability: leaf.cumProb,
            exploitScore: exploitScoreOf(cumProb: leaf.cumProb, gainCp: gap),
          ),
        );
      } catch (e) {
        debugPrint('[HoleHunt] Trap build failed at leaf ${leaf.fen}: $e');
      }
    }

    onProgress?.call(
      HoleHuntProgress(
        phase: HoleHuntPhase.traps,
        leavesDone: selected.length,
        leavesTotal: selected.length,
        findingsCount: findingsCount(),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  int _countNodes(OpeningTreeNode root, int maxPly) {
    int count = 0;
    final queue = Queue<(OpeningTreeNode, int)>();
    queue.add((root, 0));
    while (queue.isNotEmpty) {
      final (node, ply) = queue.removeFirst();
      if (ply > maxPly) continue;
      count++;
      for (final child in node.children.values) {
        queue.add((child, ply + 1));
      }
    }
    return count;
  }
}

class _HuntQueueEntry {
  final OpeningTreeNode node;
  final List<String> movePath;
  final int ply;
  final double cumProb;

  const _HuntQueueEntry({
    required this.node,
    required this.movePath,
    required this.ply,
    required this.cumProb,
  });
}
