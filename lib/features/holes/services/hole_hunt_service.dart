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
import 'dart:math' as math;

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
import '../../../utils/chess_utils.dart' as chess_utils;
import '../../../utils/ease_utils.dart';
import '../../../utils/fen_utils.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../audit/services/engine_position_probe.dart';
import '../../audit/services/exploit_ranking.dart';
import '../../audit/services/repertoire_walk.dart';
import 'hole_hunt_config.dart';
import 'hole_scoring.dart';

enum HoleHuntPhase { walking, leaves, probing }

/// Progress callback emitted periodically during a hunt.
typedef HoleHuntProgressCallback = void Function(HoleHuntProgress progress);

class HoleHuntProgress {
  const HoleHuntProgress({
    required this.phase,
    this.done = 0,
    this.total = 0,
    this.findingsCount = 0,
  });

  final HoleHuntPhase phase;

  /// Units of the current phase: positions walked, leaves discovered, or
  /// candidates probed.
  final int done;
  final int total;
  final int findingsCount;

  /// The walk owns 0..0.6 of the bar, leaf discovery 0.6..0.7, the probes
  /// 0.7..1.0. An empty later phase reads as done, not as stuck.
  double get fraction => switch (phase) {
    HoleHuntPhase.walking => 0.6 * _phaseFraction(whenEmpty: 0.0),
    HoleHuntPhase.leaves => 0.6 + 0.1 * _phaseFraction(whenEmpty: 1.0),
    HoleHuntPhase.probing => 0.7 + 0.3 * _phaseFraction(whenEmpty: 1.0),
  };

  double _phaseFraction({required double whenEmpty}) =>
      (total > 0 ? done / total : whenEmpty).clamp(0.0, 1.0);

  String get message => switch (phase) {
    HoleHuntPhase.walking => 'Walking $done / $total positions',
    HoleHuntPhase.leaves => 'Discovery $done / $total leaves',
    HoleHuntPhase.probing => 'Probing $done / $total candidates',
  };
}

class HoleHuntService {
  HoleHuntService({StockfishPool? pool, EvalCache? evalCache})
    : _probe = EnginePositionProbe(pool: pool, evalCache: evalCache);

  /// At most this many trick candidates per position enter the probe pool,
  /// so one hot position cannot eat the whole probe budget. An in-tree move
  /// inside the window is always kept in addition.
  static const int _maxCandidatesPerNode = 3;

  /// Wall-clock budget per probe build; enforced via the build's own
  /// isCancelled hook so the builder unwinds cleanly instead of being
  /// orphaned by a thrown timeout.
  static const Duration _probeTimeout = Duration(seconds: 60);

  /// An uncovered attacker move worth at least this much is critical; one
  /// that at least holds the balance is a warning; the rest are notes.
  static const int _criticalAttackerCp = 100;

  /// A trick netting at least this multiple of the reporting floor is
  /// critical.
  static const int _criticalNetGainMultiple = 2;

  final EnginePositionProbe _probe;

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
    _probe.stats.reset();
    _probesSkipped = false;
    _lastCandidateCount = 0;
    final stopwatch = Stopwatch()..start();
    final findings = <AuditFinding>[];
    final attackerIsWhite = !isWhiteRepertoire;
    final wantTricks = config.probeBudget > 0;
    final trickWork = _TrickWork();
    int attackerNodes = 0;
    int ownerNodes = 0;
    int leafNodes = 0;

    await _probe.init();

    void emit(AuditFinding finding) {
      findings.add(finding);
      onFinding?.call(finding);
    }

    // ── Pass 1: BFS walk ─────────────────────────────────────────────────
    // Inverted attenuation vs the audit: the attacker steers (probability
    // 1); the owner chooses among their alternatives.
    final walk = RepertoireWalk(
      start: tree.root,
      maxPly: config.maxPly,
      attenuatingSideIsWhite: isWhiteRepertoire,
      control: _control,
    );
    await walk.run(
      onProgress: (_) => onProgress?.call(
        HoleHuntProgress(
          phase: HoleHuntPhase.walking,
          done: walk.visited,
          total: walk.totalNodes,
          findingsCount: findings.length,
        ),
      ),
      visit: (entry) async {
        final isOwnerTurn = entry.whiteToMove == isWhiteRepertoire;
        if (entry.isLeaf) {
          leafNodes++;
          if (wantTricks && !isOwnerTurn) trickWork.registerLeaf(entry);
        } else if (isOwnerTurn) {
          ownerNodes++;
          await _checkOwnerMoves(entry, isWhiteRepertoire, config, emit);
        } else {
          attackerNodes++;
          await _checkAttackerNode(
            entry,
            attackerIsWhite: attackerIsWhite,
            tree: tree,
            config: config,
            emit: emit,
            trickWork: wantTricks ? trickWork : null,
          );
        }
      },
    );

    // ── Pass 2: trick search — leaf discovery, then expectimax probes ────
    if (wantTricks && trickWork.hasWork && !_control.isCancelled) {
      // Every probe is a Maia expectimax build, so settle the model before
      // spending any more engine time.
      if (!await _ensureMaia()) {
        _probesSkipped = true;
      } else {
        await _discoverLeaves(
          trickWork,
          attackerIsWhite: attackerIsWhite,
          config: config,
          findingsCount: () => findings.length,
          onProgress: onProgress,
        );
        _lastCandidateCount = trickWork.candidates.length;
        if (!_control.isCancelled) {
          await _probePass(
            trickWork.candidates,
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
      nodesChecked: walk.visited,
      ourMoveNodesChecked: attackerNodes,
      opponentNodesChecked: ownerNodes,
      leafNodesChecked: leafNodes,
      evalCacheHits: _probe.stats.hits,
      evalCacheMisses: _probe.stats.misses,
      elapsed: stopwatch.elapsed,
    );
  }

  Future<List<DiscoveredCandidate>> _discover(
    String fen,
    HoleHuntConfig config, {
    bool countAsLookup = false,
  }) => _probe.discover(
    fen,
    depth: config.discoveryDepth,
    multiPv: config.discoveryMultiPv,
    countAsLookup: countAsLookup,
  );

  // ── Attacker nodes: uncovered strong moves + trick candidates ──────────

  Future<void> _checkAttackerNode(
    RepertoireWalkEntry entry, {
    required bool attackerIsWhite,
    required OpeningTree tree,
    required HoleHuntConfig config,
    required void Function(AuditFinding) emit,
    required _TrickWork? trickWork,
  }) async {
    final node = entry.node;
    // Registered before discovery so a transposition reached again later
    // folds its reach into this target whatever the engine says here.
    final target = trickWork?.register(entry);
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

        final gainCp = math.max(0, attackerCp) + config.outOfBookBonusCp;
        emit(
          AuditFinding(
            type: AuditFindingType.uncoveredStrongMove,
            severity: attackerCp >= _criticalAttackerCp
                ? AuditSeverity.critical
                : attackerCp >= 0
                ? AuditSeverity.warning
                : AuditSeverity.info,
            movePath: entry.movePath,
            fen: node.fen,
            missingMove: line.san,
            positionEvalCp: line.whiteCp,
            bestMoveEvalCp: bestWhiteCp,
            cumulativeProbability: entry.cumulativeProbability,
            transposesIntoRepertoire: tree.doesMoveTranspose(
              node.fen,
              line.san,
            ),
            exploitScore: exploitScoreOf(
              cumProb: entry.cumulativeProbability,
              gainCp: gainCp,
            ),
          ),
        );
      }

      if (target != null) {
        trickWork!.candidates.addAll(
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

  Future<void> _checkOwnerMoves(
    RepertoireWalkEntry entry,
    bool isWhiteRepertoire,
    HoleHuntConfig config,
    void Function(AuditFinding) emit,
  ) async {
    final node = entry.node;
    try {
      final lines = await _discover(node.fen, config, countAsLookup: true);
      if (lines.isEmpty) return;

      final best = lines.first;
      int ownerLossOf(int whiteCp) =>
          isWhiteRepertoire ? best.whiteCp - whiteCp : whiteCp - best.whiteCp;

      for (final MapEntry(key: repSan, value: child) in node.children.entries) {
        final repUci = chess_utils.sanToUci(node.fen, repSan);
        if (repUci == null) continue;

        final repWhiteCp = await _probe.evalAfterMove(
          node.fen,
          repUci,
          lines: lines,
          depth: config.discoveryDepth,
        );
        if (repWhiteCp == null) continue;
        if (ownerLossOf(repWhiteCp) < config.refutationThresholdCp) continue;

        // Deep single-PV verification on the position after the move —
        // yields both a trustworthy eval and the concrete refutation line.
        final verified = await _probe.verify(
          child.fen,
          depth: config.verifyDepth,
        );
        final verifiedLoss = ownerLossOf(verified.whiteCp);
        // Shallow-search artifact guard: the deep search must confirm at
        // least half the claimed loss.
        if (verifiedLoss < config.refutationThresholdCp / 2) continue;

        emit(
          AuditFinding(
            type: AuditFindingType.refutation,
            severity: AuditSeverity.critical,
            movePath: [...entry.movePath, repSan],
            fen: node.fen,
            ourMove: repSan,
            bestMove: best.san,
            evalLossCp: verifiedLoss,
            positionEvalCp: verified.whiteCp,
            bestMoveEvalCp: best.whiteCp,
            exploitLine: chess_utils.uciPvToSan(child.fen, verified.pv),
            cumulativeProbability: entry.cumulativeProbability,
            exploitScore: exploitScoreOf(
              cumProb: entry.cumulativeProbability,
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
  }

  // ── Leaf discovery: candidates past the recorded games ─────────────────

  Future<void> _discoverLeaves(
    _TrickWork trickWork, {
    required bool attackerIsWhite,
    required HoleHuntConfig config,
    required int Function() findingsCount,
    required HoleHuntProgressCallback? onProgress,
  }) async {
    final selected = selectTopTargets(trickWork.leaves, config.probeBudget);
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
        trickWork.candidates.addAll(
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

  Future<void> _probePass(
    List<TrickCandidate> candidates, {
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
      try {
        final finding = await _probeCandidate(
          candidate,
          buildService: buildService,
          tree: tree,
          attackerIsWhite: attackerIsWhite,
          config: config,
        );
        if (_control.isCancelled) return;
        if (finding != null) emit(finding);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[HoleHunt] Probe failed after ${candidate.san}: $e');
        }
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

  /// Build a short Maia expectimax tree after [candidate] and report it as
  /// a trick when its practical value beats the engine-best move's raw eval
  /// by [HoleHuntConfig.minNetGainCp]. Null when it does not, when the
  /// build produced nothing, or when the run was cancelled meanwhile.
  Future<AuditFinding?> _probeCandidate(
    TrickCandidate candidate, {
    required TreeBuildService buildService,
    required OpeningTree tree,
    required bool attackerIsWhite,
    required HoleHuntConfig config,
  }) async {
    final postFen = chess_utils.playUciMove(
      candidate.target.fen,
      candidate.uci,
    );
    if (postFen == null) return null;

    final buildConfig = _probeBuildConfig(
      postFen,
      attackerIsWhite: attackerIsWhite,
      config: config,
    );
    final buildClock = Stopwatch()..start();
    final probeTree = await buildService.build(
      config: buildConfig,
      isCancelled: () =>
          _control.isCancelled || buildClock.elapsed > _probeTimeout,
      onProgress: (_) {},
    );
    if (_control.isCancelled) return null;
    if (probeTree.root.children.isEmpty) return null;

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

    // Practical value from the probe ROOT: probability-weighted over all
    // opponent replies plus the uncovered-mass tail — the top line alone
    // reflects only the most probable reply and overstates tricks whose
    // punished reply is the popular one.
    final int probeExpectedCp;
    if (probeTree.root.hasExpectimax) {
      probeExpectedCp = expectedCpFromWinProb(probeTree.root.expectimaxValue);
    } else if (lines.isNotEmpty) {
      probeExpectedCp = lines.first.expectedEvalCp;
    } else {
      return null;
    }

    final metrics = candidate.metrics;
    final netGain = metrics.netGainCp(probeExpectedCp);
    if (netGain < config.minNetGainCp) return null;

    return AuditFinding(
      type: AuditFindingType.trickyMove,
      severity: netGain >= config.minNetGainCp * _criticalNetGainMultiple
          ? AuditSeverity.critical
          : AuditSeverity.warning,
      movePath: candidate.target.movePath,
      fen: candidate.target.fen,
      ourMove: candidate.san,
      // Only novelties get missingMove: it is what enables the ephemeral
      // board preview of a move the tree does not have.
      missingMove: candidate.isNovelty ? candidate.san : null,
      bestMove: candidate.bestSan,
      evalLossCp: math.max(0, metrics.objectiveCostCp),
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
    );
  }

  /// The mini expectimax build behind one probe: a few plies deep on a tight
  /// node budget, modelling the owner with Maia at the configured rating.
  static TreeBuildConfig _probeBuildConfig(
    String postFen, {
    required bool attackerIsWhite,
    required HoleHuntConfig config,
  }) => TreeBuildConfig(
    startFen: postFen,
    playAsWhite: attackerIsWhite,
    maxPly: config.probePly,
    maxNodes: _probeNodesPerPly * config.probePly,
    buildMode: BuildMode.stockfishExpectimax,
    // 1 UCI thread per worker: parallelism comes from pool workers, and >1
    // would reconfigure workers other features rely on.
    engineThreads: 1,
    minProbability: _probeMinReplyProbability,
    evalDepth: config.probeEvalDepth,
    maiaElo: config.maiaElo,
    ourMultipv: _probeBranching,
    oppMaxChildren: _probeBranching,
    oppMassTarget: _probeReplyMassTarget,
    // Tight node budget: keep it on depth, not opening breadth.
    openingWidthPlies: 0,
    verifyFinal: false,
    // The defaults (0..200, root-anchored) prune attacker follow-ups that
    // merely hold the raw eval — exactly the moves a trick's punishment is
    // made of. Widen; still root-anchored via relativeEval.
    minEvalCp: _probeMinEvalCp,
    maxEvalCp: _probeMaxEvalCp,
  );

  static const int _probeNodesPerPly = 800;
  static const double _probeMinReplyProbability = 0.02;
  static const int _probeBranching = 4;
  static const double _probeReplyMassTarget = 0.80;
  static const int _probeMinEvalCp = -200;
  static const int _probeMaxEvalCp = 400;

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Attacker-perspective cp back to White-normalized (its own inverse).
  static int _toWhite(int attackerCp, bool attackerIsWhite) =>
      attackerIsWhite ? attackerCp : -attackerCp;

  Future<bool> _ensureMaia() async {
    final maia = MaiaFactory.isAvailable ? MaiaFactory.instance : null;
    if (maia == null) {
      debugPrint('[HoleHunt] Trick probes skipped — Maia unavailable');
      return false;
    }
    try {
      await maia.initialize();
      return true;
    } catch (e) {
      debugPrint('[HoleHunt] Trick probes skipped — Maia init failed: $e');
      return false;
    }
  }
}

/// The trick search's input, gathered during the walk: attacker-to-move
/// positions (deduplicated across transpositions), the leaves among them
/// awaiting discovery, and the candidate moves found so far.
class _TrickWork {
  /// A position reached twice sums its reach onto the first-seen target.
  final Map<String, TrickTarget> _byFen = {};

  /// Attacker-to-move leaves, discovered after the walk under the probe
  /// budget rather than one by one inside it.
  final List<TrickTarget> leaves = [];

  final List<TrickCandidate> candidates = [];

  bool get hasWork => leaves.isNotEmpty || candidates.isNotEmpty;

  /// The trick target for [entry], or null when the position was already
  /// seen (its reach has been added to the existing target).
  TrickTarget? register(RepertoireWalkEntry entry) {
    final key = normalizeFen(entry.fen);
    final existing = _byFen[key];
    if (existing != null) {
      existing.reach = (existing.reach + entry.cumulativeProbability).clamp(
        0.0,
        1.0,
      );
      return null;
    }
    return _byFen[key] = TrickTarget(
      node: entry.node,
      movePath: entry.movePath,
      reach: entry.cumulativeProbability,
    );
  }

  void registerLeaf(RepertoireWalkEntry entry) {
    final target = register(entry);
    if (target != null) leaves.add(target);
  }
}
