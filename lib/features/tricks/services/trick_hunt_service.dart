/// Trick hunt over a player's opening tree.
///
/// Walks the tree from the TRICKSTER's side (the color opposite the tree's
/// owner) and, at the most reachable trickster-to-move positions — leaves
/// included, which is how the hunt extends past the recorded games —
/// discovers near-best engine alternatives and probes each with a short
/// expectimax build. A candidate becomes a `trickyMove` finding when its
/// practical (expectimax) eval beats even the engine-best move's raw eval:
/// the opponent is expected to misplay against it by more than the trick
/// concedes objectively.
///
/// Like the hole hunt, findings carry an exploitScore (reach probability ×
/// net gain) and the report surfaces a handful of killer tricks.
library;

import 'dart:async';

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
import '../../../services/tree_build_service.dart';
import '../../../utils/chess_utils.dart' as chess_utils;
import '../../../utils/ease_utils.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../holes/services/hole_scoring.dart';
import 'trick_hunt_config.dart';
import 'trick_scoring.dart';
import '../../../utils/fen_utils.dart';

enum TrickHuntPhase { walking, discovery, probing }

/// Progress callback emitted periodically during a hunt.
typedef TrickHuntProgressCallback = void Function(TrickHuntProgress progress);

class TrickHuntProgress {
  final TrickHuntPhase phase;
  final int walked;
  final int walkTotal;
  final int discoveryDone;
  final int discoveryTotal;
  final int probesDone;
  final int probesTotal;
  final int findingsCount;

  const TrickHuntProgress({
    required this.phase,
    this.walked = 0,
    this.walkTotal = 0,
    this.discoveryDone = 0,
    this.discoveryTotal = 0,
    this.probesDone = 0,
    this.probesTotal = 0,
    this.findingsCount = 0,
  });

  /// The engine-free walk owns 0..0.05 of the bar, discovery 0.05..0.55,
  /// the probes 0.55..1.0.
  double get fraction {
    switch (phase) {
      case TrickHuntPhase.walking:
        final f = walkTotal > 0 ? walked / walkTotal : 0.0;
        return 0.05 * f.clamp(0.0, 1.0);
      case TrickHuntPhase.discovery:
        final f = discoveryTotal > 0 ? discoveryDone / discoveryTotal : 1.0;
        return 0.05 + 0.50 * f.clamp(0.0, 1.0);
      case TrickHuntPhase.probing:
        final f = probesTotal > 0 ? probesDone / probesTotal : 1.0;
        return 0.55 + 0.45 * f.clamp(0.0, 1.0);
    }
  }

  String get message {
    switch (phase) {
      case TrickHuntPhase.walking:
        return 'Walking $walked / $walkTotal positions';
      case TrickHuntPhase.discovery:
        return 'Discovery $discoveryDone / $discoveryTotal positions';
      case TrickHuntPhase.probing:
        return 'Probing $probesDone / $probesTotal candidates';
    }
  }
}

class TrickHuntService {
  final StockfishPool _pool = StockfishPool.instance;
  final EvalCache _evalCache = EvalCache.instance;

  bool _cancelled = false;
  bool _paused = false;

  /// True when the most recent hunt could not probe because Maia was
  /// unavailable. Surfaced as a note in the report panel.
  bool get probesSkipped => _probesSkipped;
  bool _probesSkipped = false;

  void cancel() => _cancelled = true;
  void pause() => _paused = true;
  void resume() => _paused = false;

  /// Run a full hunt over [tree].
  ///
  /// [playerIsWhite] is the color the tree's owner plays; the trickster is
  /// always the other color.
  Future<AuditResult> hunt({
    required OpeningTree tree,
    required bool playerIsWhite,
    required TrickHuntConfig config,
    TrickHuntProgressCallback? onProgress,
    void Function(AuditFinding)? onFinding,
  }) async {
    _cancelled = false;
    _paused = false;
    _probesSkipped = false;
    final stopwatch = Stopwatch()..start();
    final findings = <AuditFinding>[];
    final tricksterIsWhite = !playerIsWhite;

    int walked = 0;
    int discoveriesRun = 0;
    int probesRun = 0;

    void emit(AuditFinding f) {
      findings.add(f);
      onFinding?.call(f);
    }

    AuditResult buildResult() => AuditResult(
      findings: rankByExploitScore(findings),
      // AuditResult is shared with the audits; the counters here mean:
      // nodesChecked = positions walked, ourMoveNodesChecked = discovery
      // searches, leafNodesChecked = probe builds.
      nodesChecked: walked,
      ourMoveNodesChecked: discoveriesRun,
      opponentNodesChecked: 0,
      leafNodesChecked: probesRun,
      evalCacheMisses: discoveriesRun,
      elapsed: stopwatch.elapsed,
    );

    await _evalCache.init();

    // The whole feature is expectimax probes, so bail before spending any
    // engine time when Maia cannot model the opponent.
    if (!await _ensureMaia()) {
      _probesSkipped = true;
      stopwatch.stop();
      return buildResult();
    }

    // ── Stage A: engine-free walk (synchronous, near-instant) ───────────
    onProgress?.call(const TrickHuntProgress(phase: TrickHuntPhase.walking));
    final walk = collectTrickTargets(
      tree.root,
      playerIsWhite: playerIsWhite,
      maxPly: config.maxPly,
    );
    walked = walk.nodesWalked;

    // ── Stage B: MultiPV discovery on the most reachable targets ────────
    final targets = selectDiscoveryTargets(
      dedupTargets(walk.targets),
      minReachProb: config.minReachProb,
      maxNodes: config.maxDiscoveryNodes,
    );
    final candidates = <TrickCandidate>[];

    for (var i = 0; i < targets.length; i++) {
      if (_cancelled) break;
      while (_paused && !_cancelled) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_cancelled) break;

      onProgress?.call(
        TrickHuntProgress(
          phase: TrickHuntPhase.discovery,
          discoveryDone: i,
          discoveryTotal: targets.length,
        ),
      );

      final target = targets[i];
      try {
        final discovery = await _pool.discoverMoves(
          fen: target.fen,
          depth: config.discoveryDepth,
          multiPv: config.discoveryMultiPv,
          isWhiteToMove: isWhiteToMove(target.fen),
        );
        discoveriesRun++;
        if (discovery.lines.isEmpty) continue;

        _evalCache.putEvalCpWhiteSoon(
          target.fen,
          discovery.lines.first.effectiveCp,
          config.discoveryDepth,
        );

        final lines = <DiscoveredCandidate>[];
        for (final line in discovery.lines) {
          final san = chess_utils.uciToSanOrNull(target.fen, line.moveUci);
          if (san == null) continue;
          lines.add(
            DiscoveredCandidate(
              uci: line.moveUci,
              san: san,
              whiteCp: line.effectiveCp,
            ),
          );
        }
        if (lines.isEmpty) continue;

        candidates.addAll(
          selectCandidates(
            target: target,
            lines: lines,
            inTreeSans: target.node.children.keys.toSet(),
            tricksterIsWhite: tricksterIsWhite,
            windowCp: config.candidateWindowCp,
            maxPerNode: config.maxCandidatesPerNode,
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[TrickHunt] Discovery failed at ${target.fen}: $e');
        }
      }
    }

    // ── Stage C: expectimax probes ───────────────────────────────────────
    if (!_cancelled) {
      await _probePass(
        candidates: candidates,
        tree: tree,
        tricksterIsWhite: tricksterIsWhite,
        config: config,
        findingsCount: () => findings.length,
        onProgress: onProgress,
        emit: emit,
        onProbeDone: () => probesRun++,
      );
    }

    stopwatch.stop();
    final result = buildResult();
    onProgress?.call(
      TrickHuntProgress(
        phase: TrickHuntPhase.probing,
        probesDone: 1,
        probesTotal: 1,
        findingsCount: result.findings.length,
      ),
    );
    return result;
  }

  // ── Probe pass ─────────────────────────────────────────────────────────

  Future<void> _probePass({
    required List<TrickCandidate> candidates,
    required OpeningTree tree,
    required bool tricksterIsWhite,
    required TrickHuntConfig config,
    required int Function() findingsCount,
    required TrickHuntProgressCallback? onProgress,
    required void Function(AuditFinding) emit,
    required void Function() onProbeDone,
  }) async {
    final selected = selectProbeCandidates(
      candidates,
      budget: config.probeBudget,
      windowCp: config.candidateWindowCp,
    );
    if (selected.isEmpty) return;

    final buildService = TreeBuildService();
    final probeTimeout = Duration(seconds: config.probeTimeoutSeconds);

    for (var i = 0; i < selected.length; i++) {
      if (_cancelled) return;
      while (_paused && !_cancelled) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_cancelled) return;

      onProgress?.call(
        TrickHuntProgress(
          phase: TrickHuntPhase.probing,
          probesDone: i,
          probesTotal: selected.length,
          findingsCount: findingsCount(),
        ),
      );

      final candidate = selected[i];
      final postFen = chess_utils.playUciMove(
        candidate.target.fen,
        candidate.uci,
      );
      if (postFen == null) continue;

      final buildConfig = TreeBuildConfig(
        startFen: postFen,
        playAsWhite: tricksterIsWhite,
        maxPly: config.probePly,
        maxNodes: 800 * config.probePly,
        buildMode: BuildMode.stockfishExpectimax,
        // 1 UCI thread per worker — same reasoning as the trap pass:
        // parallelism comes from pool workers, and >1 would reconfigure
        // workers other features rely on.
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
        // The defaults (0..200, root-anchored) prune trickster follow-ups
        // that merely hold the raw eval — exactly the moves a trick's
        // punishment is made of. Widen; still root-anchored via relativeEval.
        minEvalCp: -200,
        maxEvalCp: 400,
      );

      try {
        final buildClock = Stopwatch()..start();
        final probeTree = await buildService.build(
          config: buildConfig,
          isCancelled: () => _cancelled || buildClock.elapsed > probeTimeout,
          onProgress: (_) {},
        );
        onProbeDone();
        if (_cancelled) return;
        if (probeTree.root.children.isEmpty) continue;

        final fenMap = FenMap()..populate(probeTree.root);
        final eca = ExpectimaxCalculator(config: buildConfig, fenMap: fenMap);
        eca.calculate(probeTree);
        eca.computeTrapScores(probeTree.root);
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
            positionEvalCp: _toWhite(metrics.candidateRawCp, tricksterIsWhite),
            bestMoveEvalCp: _toWhite(metrics.bestRawCp, tricksterIsWhite),
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
        debugPrint('[TrickHunt] Probe failed after ${candidate.san}: $e');
      }
    }

    onProgress?.call(
      TrickHuntProgress(
        phase: TrickHuntPhase.probing,
        probesDone: selected.length,
        probesTotal: selected.length,
        findingsCount: findingsCount(),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Trickster-perspective cp back to White-normalized (its own inverse).
  static int _toWhite(int tricksterCp, bool tricksterIsWhite) =>
      tricksterIsWhite ? tricksterCp : -tricksterCp;

  Future<bool> _ensureMaia() async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      debugPrint('[TrickHunt] Skipped — Maia unavailable');
      return false;
    }
    try {
      await MaiaFactory.instance!.initialize();
      return true;
    } catch (e) {
      debugPrint('[TrickHunt] Skipped — Maia init failed: $e');
      return false;
    }
  }
}
