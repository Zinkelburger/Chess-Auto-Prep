/// Final verification pass — deep engine re-check of the selected repertoire.
///
/// Every move the selector marked `isRepertoireMove` was chosen using
/// build-time evals (Stockfish at `evalDepth`, or external DB evals of mixed
/// depth).  This pass re-evaluates the chosen moves at
/// [TreeBuildConfig.resolvedVerifyDepth] and demotes any move whose deep eval
/// loses more than `maxEvalLossCp` against the best deep-checked sibling,
/// then re-runs expectimax + selection.  The exported repertoire therefore
/// carries a guarantee: no selected move loses more than the threshold at
/// the verification depth.
///
/// Verification changes evals and selection only — it never adds or removes
/// tree nodes, so coverage guarantees from the build are preserved.
library;

import '../../models/build_tree_node.dart';
import '../engine/stockfish_pool.dart';
import 'eca_calculator.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'repertoire_selector.dart';

/// A repertoire move replaced because its deep eval failed the threshold.
class VerificationDemotion {
  /// Position (our turn) where the selection changed.
  final String fen;
  final int ply;
  final String oldSan;
  final String newSan;

  /// Deep evals from our perspective.
  final int oldDeepCpUs;
  final int newDeepCpUs;

  VerificationDemotion({
    required this.fen,
    required this.ply,
    required this.oldSan,
    required this.newSan,
    required this.oldDeepCpUs,
    required this.newDeepCpUs,
  });

  @override
  String toString() =>
      'ply $ply: $oldSan (${oldDeepCpUs}cp deep) → $newSan '
      '(${newDeepCpUs}cp deep)';
}

class VerificationReport {
  final int movesChecked;
  final int evalsRun;
  final int passes;
  final int verifyDepth;
  final List<VerificationDemotion> demotions;

  /// False when the engine was unavailable or the pass was cancelled —
  /// the guarantee does NOT hold for unchecked moves.
  final bool completed;

  /// Repertoire move count after the final re-selection (unchanged when no
  /// demotions occurred).
  final int selectedCount;

  VerificationReport({
    required this.movesChecked,
    required this.evalsRun,
    required this.passes,
    required this.verifyDepth,
    required this.demotions,
    required this.completed,
    required this.selectedCount,
  });

  String get summary => completed
      ? 'Verified $movesChecked repertoire moves at depth $verifyDepth — '
          '${demotions.isEmpty ? 'all passed' : '${demotions.length} demoted and re-selected'}'
      : 'Verification incomplete ($movesChecked moves checked)';
}

class RepertoireVerifier {
  final TreeBuildConfig config;
  final StockfishPool pool;

  /// Deep evals already run this session, keyed by FEN (STM-relative cp).
  /// Lets re-verification after a demotion pass reuse earlier results.
  final Map<String, int> _deepCpStm = {};

  static const int _maxPasses = 3;

  RepertoireVerifier({required this.config, StockfishPool? pool})
      : pool = pool ?? StockfishPool.instance;

  Future<VerificationReport> verify(
    BuildTree tree, {
    required FenMap fenMap,
    required ExpectimaxCalculator ecaCalc,
    bool Function()? isCancelled,
    Future<void> Function()? pauseGate,
    void Function(String status)? onStatus,
  }) async {
    final depth = config.resolvedVerifyDepth;
    final demotions = <VerificationDemotion>[];
    final checkedFens = <String>{};
    int evalsRun = 0;
    int passes = 0;
    int selectedCount = -1;
    bool cancelled = false;

    bool stop() => cancelled = cancelled || (isCancelled?.call() ?? false);

    if (pool.workerCount == 0) {
      return VerificationReport(
        movesChecked: 0,
        evalsRun: 0,
        passes: 0,
        verifyDepth: depth,
        demotions: const [],
        completed: false,
        selectedCount: -1,
      );
    }

    for (var pass = 1; pass <= _maxPasses; pass++) {
      passes = pass;
      final spine = _collectRepertoireOurNodes(tree, fenMap);
      if (spine.isEmpty) break;

      // Deep-eval every chosen move (batched, deduplicated, cached).
      final chosenFens = <String>{};
      for (final node in spine) {
        final chosen = _chosenChild(node);
        if (chosen != null && !_deepCpStm.containsKey(chosen.fen)) {
          chosenFens.add(chosen.fen);
        }
      }
      await pauseGate?.call();
      if (stop()) break;
      onStatus?.call(
        'Verifying ${spine.length} repertoire moves at depth $depth '
        '(pass $pass)...',
      );
      evalsRun += await _deepEvalMany(chosenFens.toList(), depth);
      if (stop()) break;

      var demoted = false;
      for (final node in spine) {
        await pauseGate?.call();
        if (stop()) break;
        final chosen = _chosenChild(node);
        if (chosen == null) continue;
        checkedFens.add(chosen.fen);

        final chosenDeepStm = _deepCpStm[chosen.fen];
        if (chosenDeepStm == null) continue; // eval failed; keep shallow
        chosen.engineEvalCp = chosenDeepStm;
        final chosenUs = chosen.evalForUs(config.playAsWhite);

        // Cheap accept: even trusting every sibling's (optimistic) shallow
        // eval, none beats the deep-checked choice by more than the
        // threshold.
        var bestAltUs = -kVerifyInf;
        for (final sib in node.children) {
          if (identical(sib, chosen) || !sib.hasEngineEval) continue;
          final us = sib.evalForUs(config.playAsWhite);
          if (us > bestAltUs) bestAltUs = us;
        }
        if (bestAltUs - chosenUs <= config.maxEvalLossCp) continue;

        // Suspect: deep-check the siblings before judging.
        final sibFens = [
          for (final sib in node.children)
            if (!identical(sib, chosen) && !_deepCpStm.containsKey(sib.fen))
              sib.fen,
        ];
        evalsRun += await _deepEvalMany(sibFens, depth);
        if (stop()) break;

        BuildTreeNode? bestSib;
        var bestSibUs = -kVerifyInf;
        for (final sib in node.children) {
          if (identical(sib, chosen)) continue;
          final deepStm = _deepCpStm[sib.fen];
          if (deepStm == null) continue;
          sib.engineEvalCp = deepStm;
          final us = sib.evalForUs(config.playAsWhite);
          if (us > bestSibUs) {
            bestSibUs = us;
            bestSib = sib;
          }
        }

        if (bestSib != null && bestSibUs - chosenUs > config.maxEvalLossCp) {
          demotions.add(VerificationDemotion(
            fen: node.fen,
            ply: node.ply,
            oldSan: chosen.moveSan,
            newSan: bestSib.moveSan,
            oldDeepCpUs: chosenUs,
            newDeepCpUs: bestSibUs,
          ));
          demoted = true;
        }
      }

      if (cancelled) break;

      if (!demoted) {
        // Every selected move deep-checked and within threshold: done.
        break;
      }

      // Deep evals are now on the nodes — recompute values and re-select,
      // then verify the (possibly new) spine on the next pass.
      onStatus?.call('Re-selecting after ${demotions.length} demotions...');
      _clearSelection(tree.root);
      ecaCalc.calculate(tree);
      final selector = RepertoireSelector(
        config: config,
        ecaCalc: ecaCalc,
        fenMap: fenMap,
      );
      selectedCount = selector.select(tree);
    }

    return VerificationReport(
      movesChecked: checkedFens.length,
      evalsRun: evalsRun,
      passes: passes,
      verifyDepth: depth,
      demotions: demotions,
      completed: !cancelled,
      selectedCount: selectedCount,
    );
  }

  static const int kVerifyInf = 1 << 20;

  BuildTreeNode? _chosenChild(BuildTreeNode node) {
    for (final child in node.children) {
      if (child.isRepertoireMove) return child;
    }
    return null;
  }

  /// Our-turn nodes with a selected repertoire move, walked along the
  /// current selection (transposition-aware, cycle-guarded).
  List<BuildTreeNode> _collectRepertoireOurNodes(
    BuildTree tree,
    FenMap fenMap,
  ) {
    final result = <BuildTreeNode>[];
    final visited = <String>{};

    void walk(BuildTreeNode node) {
      final resolved = resolveTransposition(node, fenMap);
      if (resolved.children.isEmpty) return;
      if (!visited.add(canonicalizeFen(resolved.fen))) return;

      final isOurMove = resolved.isWhiteToMove == config.playAsWhite;
      if (isOurMove) {
        final chosen = _chosenChild(resolved);
        if (chosen != null) {
          result.add(resolved);
          walk(chosen);
        }
      } else {
        for (final child in resolved.children) {
          walk(child);
        }
      }
    }

    walk(tree.root);
    return result;
  }

  Future<int> _deepEvalMany(List<String> fens, int depth) async {
    if (fens.isEmpty) return 0;
    final results = await pool.evaluateMany(fens, depth);
    for (var i = 0; i < fens.length; i++) {
      _deepCpStm[fens[i]] = results[i].effectiveCp;
    }
    return fens.length;
  }

  void _clearSelection(BuildTreeNode node) {
    node.isRepertoireMove = false;
    for (final child in node.children) {
      _clearSelection(child);
    }
  }
}
