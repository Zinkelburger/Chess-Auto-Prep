/// The hole hunt's probe pass: does a near-best attacker move actually pay?
///
/// A candidate that survived prescreening gets a short Maia expectimax build
/// of its own. The build answers the question the raw eval cannot: how much
/// the owner is expected to bleed from the resulting position, versus what
/// the candidate concedes objectively. A candidate whose practical value
/// beats the engine-best move's raw eval by [HoleHuntConfig.minNetGainCp] is
/// a trick.
///
/// Split out of the hunt service so the builds are injectable: [probe] takes
/// its tree from a [ProbeTreeBuilder], which a test supplies without running
/// a real engine. Candidate selection is `hole_scoring.dart`; the engine
/// discovery feeding it is `EnginePositionProbe`.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../chess_core/generation/build_tree_node.dart';
import '../../../models/opening_tree.dart';
import '../../../services/expectimax_line_service.dart';
import '../../../services/generation/eca_calculator.dart';
import '../../../services/generation/fen_map.dart';
import '../../../services/generation/generation_config.dart';
import '../../../services/generation/tree_ease.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../services/run_control.dart';
import '../../../utils/chess_utils.dart' as chess_utils;
import '../../../utils/ease_utils.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/services/exploit_ranking.dart';
import 'hole_hunt_config.dart';
import 'hole_scoring.dart';

/// How a probe gets its expectimax tree. Matches `TreeBuildService.build`,
/// whose extra optional arguments this pass does not use.
typedef ProbeTreeBuilder =
    Future<BuildTree> Function({
      required TreeBuildConfig config,
      required bool Function() isCancelled,
      required void Function(BuildProgress) onProgress,
    });

/// Progress within the pass: [done] of [total] candidates probed.
typedef ProbeProgressCallback = void Function(int done, int total);

class TrickProbe {
  TrickProbe({
    required this.tree,
    required this.config,
    required this.attackerIsWhite,
    required this.control,
    required ProbeTreeBuilder buildTree,
  }) : _buildTree = buildTree;

  /// Wall-clock budget per probe build, enforced through the build's own
  /// isCancelled hook so the builder unwinds cleanly instead of being
  /// orphaned by a thrown timeout.
  static const Duration probeTimeout = Duration(seconds: 60);

  /// A trick netting at least this multiple of the reporting floor is
  /// critical.
  static const int _criticalNetGainMultiple = 2;

  /// The repertoire being hunted, consulted for transpositions.
  final OpeningTree tree;
  final HoleHuntConfig config;

  /// The colour opposite the repertoire's own — the side playing the trick.
  final bool attackerIsWhite;

  /// The hunt's cooperative pause/cancel, checked between probes and inside
  /// each build.
  final RunControl control;

  final ProbeTreeBuilder _buildTree;

  /// True when Maia is installed and loads. Every probe is a Maia build, so
  /// the hunt settles this before spending engine time on the pass.
  static Future<bool> maiaIsReady() async {
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

  /// Probe the best of [candidates] within the budget, emitting one finding
  /// per confirmed trick. Stops early when the run is cancelled.
  Future<void> run(
    List<TrickCandidate> candidates, {
    required void Function(AuditFinding) emit,
    required ProbeProgressCallback onProgress,
  }) async {
    final selected = selectProbeCandidates(
      candidates,
      budget: config.probeBudget,
      windowCp: config.candidateWindowCp,
    );
    if (selected.isEmpty) return;

    for (var i = 0; i < selected.length; i++) {
      onProgress(i, selected.length);
      if (!await control.checkpoint()) return;

      final candidate = selected[i];
      try {
        final finding = await probe(candidate);
        if (control.isCancelled) return;
        if (finding != null) emit(finding);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[HoleHunt] Probe failed after ${candidate.san}: $e');
        }
      }
    }

    onProgress(selected.length, selected.length);
  }

  /// Build a short Maia expectimax tree after [candidate] and report it as a
  /// trick when its practical value beats the engine-best move's raw eval by
  /// [HoleHuntConfig.minNetGainCp]. Null when it does not, when the build
  /// produced nothing, or when the run was cancelled meanwhile.
  @visibleForTesting
  Future<AuditFinding?> probe(TrickCandidate candidate) async {
    final postFen = chess_utils.playUciMove(
      candidate.target.fen,
      candidate.uci,
    );
    if (postFen == null) return null;

    final buildConfig = buildConfigFor(
      postFen,
      attackerIsWhite: attackerIsWhite,
      config: config,
    );
    final buildClock = Stopwatch()..start();
    final probeTree = await _buildTree(
      config: buildConfig,
      isCancelled: () =>
          control.isCancelled || buildClock.elapsed > probeTimeout,
      onProgress: (_) {},
    );
    if (control.isCancelled) return null;
    if (probeTree.root.children.isEmpty) return null;

    final expectedCp = _practicalValueOf(probeTree, buildConfig);
    if (expectedCp == null) return null;

    final metrics = candidate.metrics;
    final netGain = metrics.netGainCp(expectedCp.cp);
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
      positionEvalCp: _toWhite(metrics.candidateRawCp),
      bestMoveEvalCp: _toWhite(metrics.bestRawCp),
      expectedEvalCp: expectedCp.cp,
      practicalGapCp: metrics.practicalGapCp(expectedCp.cp),
      netGainCp: netGain,
      oppEase: probeTree.root.ease,
      isNovelty: candidate.isNovelty,
      exploitLine: [candidate.san, ...expectedCp.continuationSan],
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

  /// Score [probeTree] and read the practical value off its ROOT:
  /// probability-weighted over all opponent replies plus the uncovered-mass
  /// tail. The top line alone reflects only the most probable reply and
  /// overstates tricks whose punished reply is the popular one. Null when
  /// the build produced nothing to read.
  ({int cp, List<String> continuationSan})? _practicalValueOf(
    BuildTree probeTree,
    TreeBuildConfig buildConfig,
  ) {
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
    final continuation = lines.isEmpty
        ? const <String>[]
        : lines.first.movesSan;

    if (probeTree.root.hasExpectimax) {
      return (
        cp: expectedCpFromWinProb(probeTree.root.expectimaxValue),
        continuationSan: continuation,
      );
    }
    if (lines.isNotEmpty) {
      return (cp: lines.first.expectedEvalCp, continuationSan: continuation);
    }
    return null;
  }

  /// Attacker-perspective cp back to White-normalized (its own inverse).
  int _toWhite(int attackerCp) => attackerIsWhite ? attackerCp : -attackerCp;

  /// The mini expectimax build behind one probe: a few plies deep on a tight
  /// node budget, modelling the owner with Maia at the configured rating.
  @visibleForTesting
  static TreeBuildConfig buildConfigFor(
    String postFen, {
    required bool attackerIsWhite,
    required HoleHuntConfig config,
  }) => TreeBuildConfig(
    startFen: postFen,
    playAsWhite: attackerIsWhite,
    maxPly: config.probePly,
    maxNodes: _nodesPerPly * config.probePly,
    buildMode: BuildMode.stockfishExpectimax,
    // 1 UCI thread per worker: parallelism comes from pool workers, and >1
    // would reconfigure workers other features rely on.
    engineThreads: 1,
    minProbability: _minReplyProbability,
    evalDepth: config.probeEvalDepth,
    maiaElo: config.maiaElo,
    ourMultipv: _branching,
    oppMaxChildren: _branching,
    oppMassTarget: _replyMassTarget,
    // Tight node budget: keep it on depth, not opening breadth.
    openingWidthPlies: 0,
    verifyFinal: false,
    // The defaults (0..200, root-anchored) prune attacker follow-ups that
    // merely hold the raw eval — exactly the moves a trick's punishment is
    // made of. Widen; still root-anchored via relativeEval.
    minEvalCp: _minEvalCp,
    maxEvalCp: _maxEvalCp,
  );

  static const int _nodesPerPly = 800;
  static const double _minReplyProbability = 0.02;
  static const int _branching = 4;
  static const double _replyMassTarget = 0.80;
  static const int _minEvalCp = -200;
  static const int _maxEvalCp = 400;
}
