/// Adversarial hole hunt over a loaded repertoire tree.
///
/// Walks the repertoire from the ATTACKER's side (the color opposite the
/// repertoire's own) and emits exploitable findings:
///  - uncoveredStrongMove: engine-strong attacker moves the file has no
///    reply to,
///  - refutation: owner repertoire moves that concretely lose, with a
///    verified refutation PV,
///  - trickyMove: near-best attacker moves and novelties whose practical
///    (Maia expectimax) value beats even the engine-best move's raw eval —
///    the owner is expected to misplay against them by more than they
///    concede objectively.
///
/// One MultiPV discovery per attacker position feeds both the uncovered
/// check and the trick candidates. Attacker-to-move leaves get discovery
/// after the walk (most reachable first), which is how the hunt reaches
/// past the recorded games; the best candidates then each get a short
/// expectimax probe.
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
import '../../../services/generation/tree_ease.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../services/run_control.dart';
import '../../../services/tree_build_service.dart';
import '../../../services/eval/eval_move_helpers.dart';
import '../../../utils/chess_utils.dart' as chess_utils;
import '../../../utils/ease_utils.dart';
import '../../../utils/fen_utils.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../audit/services/exploit_ranking.dart';
import 'hole_hunt_config.dart';
import 'hole_scoring.dart';

enum HoleHuntPhase { walking, leaves, probing }

/// Progress callback emitted periodically during a hunt.
typedef HoleHuntProgressCallback = void Function(HoleHuntProgress progress);

class HoleHuntProgress {
  final HoleHuntPhase phase;

  /// Units of the current phase: positions walked, leaves discovered, or
  /// candidates probed.
  final int done;
  final int total;
  final int findingsCount;

  const HoleHuntProgress({
    required this.phase,
    this.done = 0,
    this.total = 0,
    this.findingsCount = 0,
  });

  /// The walk owns 0..0.6 of the bar, leaf discovery 0.6..0.7, the probes
  /// 0.7..1.0. An empty later phase reads as done, not as stuck.
  double get fraction {
    switch (phase) {
      case HoleHuntPhase.walking:
        final f = total > 0 ? done / total : 0.0;
        return 0.6 * f.clamp(0.0, 1.0);
      case HoleHuntPhase.leaves:
        final f = total > 0 ? done / total : 1.0;
        return 0.6 + 0.1 * f.clamp(0.0, 1.0);
      case HoleHuntPhase.probing:
        final f = total > 0 ? done / total : 1.0;
        return 0.7 + 0.3 * f.clamp(0.0, 1.0);
    }
  }

  String get message => switch (phase) {
    HoleHuntPhase.walking => 'Walking $done / $total positions',
    HoleHuntPhase.leaves => 'Discovery $done / $total leaves',
    HoleHuntPhase.probing => 'Probing $done / $total candidates',
  };
}

class HoleHuntService {
  final StockfishPool _pool = StockfishPool.instance;
  final EvalCache _evalCache = EvalCache.instance;

  /// At most this many trick candidates per position enter the probe pool,
  /// so one hot position cannot eat the whole probe budget. An in-tree move
  /// inside the window is always kept in addition.
  static const int _maxCandidatesPerNode = 3;

  /// Wall-clock budget per probe build; enforced via the build's own
  /// isCancelled hook so the builder unwinds cleanly instead of being
  /// orphaned by a thrown timeout.
  static const Duration _probeTimeout = Duration(seconds: 60);

  /// Cooperative pause/cancel for the run in progress.
  final RunControl _control = RunControl();

  /// True when the most recent hunt skipped the trick probes because Maia
  /// was unavailable. Surfaced as a note in the report panel.
  bool get probesSkipped => _probesSkipped;
  bool _probesSkipped = false;

  /// Trick candidates the most recent hunt collected, before the probe
  /// budget was applied.
  @visibleForTesting
  int get lastCandidateCount => _lastCandidateCount;
  int _lastCandidateCount = 0;

  void cancel() => _control.cancel();
  void pause() => _control.pause();
  void resume() => _control.resume();

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
    _control.reset();
    _probesSkipped = false;
    _lastCandidateCount = 0;
    final stopwatch = Stopwatch()..start();
    final findings = <AuditFinding>[];
    final attackerIsWhite = !isWhiteRepertoire;
    final wantTricks = config.probeBudget > 0;

    // Trick targets, deduplicated across transpositions: a position reached
    // twice sums its reach onto the first-seen representative.
    final targetsByFen = <String, TrickTarget>{};
    // Attacker-to-move leaves, discovered after the walk under the probe
    // budget rather than one by one inside it.
    final leafTargets = <TrickTarget>[];
    final candidates = <TrickCandidate>[];

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

    /// The trick target for [node], or null when the position was already
    /// seen (its reach has been added to the existing target).
    TrickTarget? newTarget(OpeningTreeNode node, _HuntQueueEntry entry) {
      final key = normalizeFen(node.fen);
      final existing = targetsByFen[key];
      if (existing != null) {
        existing.reach = (existing.reach + entry.cumProb).clamp(0.0, 1.0);
        return null;
      }
      final target = TrickTarget(
        node: node,
        movePath: entry.movePath,
        reach: entry.cumProb,
      );
      targetsByFen[key] = target;
      return target;
    }

    // ── Pass 1: BFS walk ─────────────────────────────────────────────────
    final totalNodes = tree.root.countDescendants(maxPly: config.maxPly);
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
      if (!await _control.checkpoint()) break;

      final entry = queue.removeFirst();
      final node = entry.node;
      if (entry.ply > config.maxPly) continue;

      checked++;
      if (checked % 5 == 0 || checked == totalNodes) {
        onProgress?.call(
          HoleHuntProgress(
            phase: HoleHuntPhase.walking,
            done: checked,
            total: totalNodes,
            findingsCount: findings.length,
          ),
        );
      }

      final isWhiteTurn = isWhiteToMove(node.fen);
      final isOwnerTurn = isWhiteTurn == isWhiteRepertoire;

      if (node.children.isEmpty) {
        leafNodes++;
        if (wantTricks && !isOwnerTurn) {
          final target = newTarget(node, entry);
          if (target != null) leafTargets.add(target);
        }
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
        await _checkAttackerNode(
          node: node,
          entry: entry,
          attackerIsWhite: attackerIsWhite,
          tree: tree,
          config: config,
          emit: emit,
          target: wantTricks ? newTarget(node, entry) : null,
          candidates: candidates,
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

    // ── Pass 2: trick search — leaf discovery, then expectimax probes ────
    final haveTrickWork = leafTargets.isNotEmpty || candidates.isNotEmpty;
    if (wantTricks && haveTrickWork && !_control.isCancelled) {
      // Every probe is a Maia expectimax build, so settle the model before
      // spending any more engine time.
      if (!await _ensureMaia()) {
        _probesSkipped = true;
      } else {
        await _discoverLeaves(
          leaves: leafTargets,
          attackerIsWhite: attackerIsWhite,
          config: config,
          candidates: candidates,
          findingsCount: () => findings.length,
          onProgress: onProgress,
        );
        _lastCandidateCount = candidates.length;
        if (!_control.isCancelled) {
          await _probePass(
            candidates: candidates,
            tree: tree,
            attackerIsWhite: attackerIsWhite,
            config: config,
            findingsCount: () => findings.length,
            onProgress: onProgress,
            emit: emit,
          );
        }
      }
    }

    stopwatch.stop();

    final ranked = rankByExploitScore(findings);
    onProgress?.call(
      HoleHuntProgress(
        phase: HoleHuntPhase.probing,
        done: 1,
        total: 1,
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

  // ── Discovery ──────────────────────────────────────────────────────────

  /// MultiPV lines at [fen] in engine order, SAN-resolved, with the best
  /// line's eval cached White-normalised. Empty when the engine had
  /// nothing to say.
  Future<List<DiscoveredCandidate>> _discover(
    String fen,
    HoleHuntConfig config,
  ) async {
    final discovery = await _pool.discoverMoves(
      fen: fen,
      depth: config.discoveryDepth,
      multiPv: config.discoveryMultiPv,
      isWhiteToMove: isWhiteToMove(fen),
    );
    if (discovery.lines.isEmpty) return const [];

    _evalCache.putEvalCpWhiteSoon(
      fen,
      discovery.lines.first.effectiveCp,
      config.discoveryDepth,
    );

    final lines = <DiscoveredCandidate>[];
    for (final line in discovery.lines) {
      final san = chess_utils.uciToSanOrNull(fen, line.moveUci);
      if (san == null) continue;
      lines.add(
        DiscoveredCandidate(
          uci: line.moveUci,
          san: san,
          whiteCp: line.effectiveCp,
        ),
      );
    }
    return lines;
  }

  // ── Attacker nodes: uncovered strong moves + trick candidates ──────────

  Future<void> _checkAttackerNode({
    required OpeningTreeNode node,
    required _HuntQueueEntry entry,
    required bool attackerIsWhite,
    required OpeningTree tree,
    required HoleHuntConfig config,
    required void Function(AuditFinding) emit,
    required TrickTarget? target,
    required List<TrickCandidate> candidates,
  }) async {
    try {
      final lines = await _discover(node.fen, config);
      if (lines.isEmpty) return;

      int toAttacker(int whiteCp) => attackerIsWhite ? whiteCp : -whiteCp;

      final bestWhiteCp = lines.first.whiteCp;
      final bestAttackerCp = toAttacker(bestWhiteCp);

      for (final line in lines) {
        if (node.children.containsKey(line.san)) continue; // covered

        final attackerCp = toAttacker(line.whiteCp);
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
            missingMove: line.san,
            positionEvalCp: line.whiteCp,
            bestMoveEvalCp: bestWhiteCp,
            cumulativeProbability: entry.cumProb,
            transposesIntoRepertoire: tree.doesMoveTranspose(
              node.fen,
              line.san,
            ),
            exploitScore: exploitScoreOf(
              cumProb: entry.cumProb,
              gainCp: gainCp,
            ),
          ),
        );
      }

      if (target != null) {
        candidates.addAll(
          selectCandidates(
            target: target,
            lines: lines,
            inTreeSans: node.children.keys.toSet(),
            attackerIsWhite: attackerIsWhite,
            windowCp: config.candidateWindowCp,
            maxPerNode: _maxCandidatesPerNode,
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
      final lines = await _discover(node.fen, config);
      cacheMisses++;
      if (lines.isEmpty) return (cacheHits, cacheMisses);

      final bestWhiteCp = lines.first.whiteCp;
      final bestSan = lines.first.san;

      int ownerLossOf(int whiteCp) =>
          isWhiteRepertoire ? bestWhiteCp - whiteCp : whiteCp - bestWhiteCp;

      for (final repEntry in node.children.entries) {
        final repSan = repEntry.key;
        final repUci = chess_utils.sanToUci(node.fen, repSan);
        if (repUci == null) continue;

        int? repWhiteCp;
        for (final line in lines) {
          if (line.uci == repUci) {
            repWhiteCp = line.whiteCp;
            break;
          }
        }
        if (repWhiteCp == null) {
          final (cp, hit, miss) = await evalAfterMoveCached(
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
        final childIsWhiteTurn = isWhiteToMove(childFen);
        // `effectiveCp` folds a forced mate into the score the way the
        // discovery lines above already do. Reading `scoreCp` raw scored a
        // mate as 0.00, so a repertoire move that loses by force verified as
        // "no loss at all" and the finding was thrown away — the hunt was
        // blind to precisely its most severe holes.
        final verifiedWhiteCp = childIsWhiteTurn
            ? verify.effectiveCp
            : -verify.effectiveCp;
        _evalCache.putEvalCpWhiteSoon(
          childFen,
          verifiedWhiteCp,
          config.verifyDepth,
        );

        final verifiedLoss = ownerLossOf(verifiedWhiteCp);
        // Shallow-search artifact guard: the deep search must confirm at
        // least half the claimed loss.
        if (verifiedLoss < config.refutationThresholdCp / 2) continue;

        final pvSan = chess_utils.uciPvToSan(childFen, verify.pv);
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

  // ── Leaf discovery: candidates past the recorded games ─────────────────

  Future<void> _discoverLeaves({
    required List<TrickTarget> leaves,
    required bool attackerIsWhite,
    required HoleHuntConfig config,
    required List<TrickCandidate> candidates,
    required int Function() findingsCount,
    required HoleHuntProgressCallback? onProgress,
  }) async {
    final selected = selectTopTargets(leaves, config.probeBudget);
    for (var i = 0; i < selected.length; i++) {
      onProgress?.call(
        HoleHuntProgress(
          phase: HoleHuntPhase.leaves,
          done: i,
          total: selected.length,
          findingsCount: findingsCount(),
        ),
      );
      if (!await _control.checkpoint()) return;

      final target = selected[i];
      try {
        final lines = await _discover(target.fen, config);
        candidates.addAll(
          selectCandidates(
            target: target,
            lines: lines,
            inTreeSans: const {},
            attackerIsWhite: attackerIsWhite,
            windowCp: config.candidateWindowCp,
            maxPerNode: _maxCandidatesPerNode,
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[HoleHunt] Leaf discovery failed at ${target.fen}: $e');
        }
      }
    }
  }

  // ── Probe pass: expectimax the best candidates ─────────────────────────

  Future<void> _probePass({
    required List<TrickCandidate> candidates,
    required OpeningTree tree,
    required bool attackerIsWhite,
    required HoleHuntConfig config,
    required int Function() findingsCount,
    required HoleHuntProgressCallback? onProgress,
    required void Function(AuditFinding) emit,
  }) async {
    final selected = selectProbeCandidates(
      candidates,
      budget: config.probeBudget,
      windowCp: config.candidateWindowCp,
    );
    if (selected.isEmpty) return;

    final buildService = TreeBuildService();

    for (var i = 0; i < selected.length; i++) {
      onProgress?.call(
        HoleHuntProgress(
          phase: HoleHuntPhase.probing,
          done: i,
          total: selected.length,
          findingsCount: findingsCount(),
        ),
      );
      if (!await _control.checkpoint()) return;

      final candidate = selected[i];
      final postFen = chess_utils.playUciMove(
        candidate.target.fen,
        candidate.uci,
      );
      if (postFen == null) continue;

      final buildConfig = TreeBuildConfig(
        startFen: postFen,
        playAsWhite: attackerIsWhite,
        maxPly: config.probePly,
        maxNodes: 800 * config.probePly,
        buildMode: BuildMode.stockfishExpectimax,
        // 1 UCI thread per worker: parallelism comes from pool workers,
        // and >1 would reconfigure workers other features rely on.
        engineThreads: 1,
        minProbability: 0.02,
        evalDepth: config.probeEvalDepth,
        maiaElo: config.maiaElo,
        ourMultipv: 4,
        oppMaxChildren: 4,
        oppMassTarget: 0.80,
        // Tight node budget: keep it on depth, not opening breadth.
        openingWidthPlies: 0,
        verifyFinal: false,
        // The defaults (0..200, root-anchored) prune attacker follow-ups
        // that merely hold the raw eval — exactly the moves a trick's
        // punishment is made of. Widen; still root-anchored via relativeEval.
        minEvalCp: -200,
        maxEvalCp: 400,
      );

      try {
        final buildClock = Stopwatch()..start();
        final probeTree = await buildService.build(
          config: buildConfig,
          isCancelled: () =>
              _control.isCancelled || buildClock.elapsed > _probeTimeout,
          onProgress: (_) {},
        );
        if (_control.isCancelled) return;
        if (probeTree.root.children.isEmpty) continue;

        final fenMap = FenMap()..populate(probeTree.root);
        final eca = ExpectimaxCalculator(config: buildConfig, fenMap: fenMap);
        eca.calculate(probeTree);
        calculateTreeEase(probeTree);

        final lines = generateExpectimaxLines(
          probeTree.root,
          buildConfig,
          eca,
          topLines: 1,
          maxPlies: config.probePly,
          fenMap: fenMap,
        );

        // Practical value from the probe ROOT: probability-weighted over
        // all opponent replies plus the uncovered-mass tail — the top line
        // alone reflects only the most probable reply and overstates
        // tricks whose punished reply is the popular one.
        final int probeExpectedCp;
        if (probeTree.root.hasExpectimax) {
          probeExpectedCp = expectedCpFromWinProb(
            probeTree.root.expectimaxValue,
          );
        } else if (lines.isNotEmpty) {
          probeExpectedCp = lines.first.expectedEvalCp;
        } else {
          continue;
        }

        final metrics = candidate.metrics;
        final netGain = metrics.netGainCp(probeExpectedCp);
        if (netGain < config.minNetGainCp) continue;

        emit(
          AuditFinding(
            type: AuditFindingType.trickyMove,
            severity: netGain >= config.minNetGainCp * 2
                ? AuditSeverity.critical
                : AuditSeverity.warning,
            movePath: candidate.target.movePath,
            fen: candidate.target.fen,
            ourMove: candidate.san,
            // Only novelties get missingMove: it is what enables the
            // ephemeral board preview of a move the tree does not have.
            missingMove: candidate.isNovelty ? candidate.san : null,
            bestMove: candidate.bestSan,
            evalLossCp: metrics.objectiveCostCp.clamp(0, 1 << 20),
            positionEvalCp: _toWhite(metrics.candidateRawCp, attackerIsWhite),
            bestMoveEvalCp: _toWhite(metrics.bestRawCp, attackerIsWhite),
            expectedEvalCp: probeExpectedCp,
            practicalGapCp: metrics.practicalGapCp(probeExpectedCp),
            netGainCp: netGain,
            oppEase: probeTree.root.ease,
            isNovelty: candidate.isNovelty,
            exploitLine: [
              candidate.san,
              if (lines.isNotEmpty) ...lines.first.movesSan,
            ],
            cumulativeProbability: candidate.target.reach,
            transposesIntoRepertoire:
                candidate.isNovelty &&
                tree.doesMoveTranspose(candidate.target.fen, candidate.san),
            exploitScore: exploitScoreOf(
              cumProb: candidate.target.reach,
              gainCp: netGain,
            ),
          ),
        );
      } catch (e) {
        debugPrint('[HoleHunt] Probe failed after ${candidate.san}: $e');
      }
    }

    onProgress?.call(
      HoleHuntProgress(
        phase: HoleHuntPhase.probing,
        done: selected.length,
        total: selected.length,
        findingsCount: findingsCount(),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Attacker-perspective cp back to White-normalized (its own inverse).
  static int _toWhite(int attackerCp, bool attackerIsWhite) =>
      attackerIsWhite ? attackerCp : -attackerCp;

  Future<bool> _ensureMaia() async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      debugPrint('[HoleHunt] Trick probes skipped — Maia unavailable');
      return false;
    }
    try {
      await MaiaFactory.instance!.initialize();
      return true;
    } catch (e) {
      debugPrint('[HoleHunt] Trick probes skipped — Maia init failed: $e');
      return false;
    }
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
