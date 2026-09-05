/// Re-evaluation for legacy saved trees; Pure uses uniform-depth construction.
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
      ? 'Rechecked $movesChecked moves against saved candidates at depth $verifyDepth — '
            '${demotions.isEmpty ? 'all passed' : '${demotions.length} demoted and re-selected'}'
      : 'Verification incomplete ($movesChecked moves checked)';
}

/// Uniform re-evaluation of an existing legacy tree. This can only certify
/// the saved candidate set; it cannot recover actions the old builder omitted.
/// Pure trees must be rebuilt at the desired depth so their legal action
/// admission test is performed at that depth too.
class RepertoireVerifier {
  final TreeBuildConfig config;
  final StockfishPool pool;
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
    if (tree.root.historyAware) {
      throw StateError('Rebuild Pure at the desired engine depth.');
    }
    final depth = config.resolvedVerifyDepth;
    final nodes = <BuildTreeNode>[];
    final previous = <BuildTreeNode, BuildTreeNode>{};
    void collect(BuildTreeNode n) {
      if (n.parent != null || n.hasEngineEval) nodes.add(n);
      final selected = n.children.where((c) => c.isRepertoireMove).firstOrNull;
      if (selected != null) previous[n] = selected;
      for (final c in n.children) {
        collect(c);
      }
    }

    collect(tree.root);
    final values = <String, int>{};
    var completed = pool.workerCount > 0;
    onStatus?.call('Re-evaluating the complete saved tree at depth $depth...');
    if (completed) {
      for (final node in nodes) {
        await pauseGate?.call();
        if (isCancelled?.call() ?? false) {
          completed = false;
          break;
        }
        if (values.containsKey(node.fen)) continue;
        final result = await pool.evaluateFen(node.fen, depth);
        if (result.depth < depth && result.scoreMate == null) {
          completed = false;
          break;
        }
        values[node.fen] = result.effectiveCp;
      }
    }
    completed = completed && !(isCancelled?.call() ?? false);
    var count = -1;
    final demotions = <VerificationDemotion>[];
    if (completed) {
      // Commit together: cancellation cannot leave mixed old/new evals.
      for (final node in nodes) {
        node.engineEvalCp = values[node.fen];
      }
      ecaCalc.calculate(
        tree,
      ); // Always refresh, including when nothing is demoted.
      count = RepertoireSelector(
        config: config,
        ecaCalc: ecaCalc,
        fenMap: fenMap,
      ).select(tree);
      for (final entry in previous.entries) {
        final selected = entry.key.children
            .where((c) => c.isRepertoireMove)
            .firstOrNull;
        if (selected != null && !identical(selected, entry.value)) {
          demotions.add(
            VerificationDemotion(
              fen: entry.key.fen,
              ply: entry.key.ply,
              oldSan: entry.value.moveSan,
              newSan: selected.moveSan,
              oldDeepCpUs: entry.value.evalForUs(config.playAsWhite),
              newDeepCpUs: selected.evalForUs(config.playAsWhite),
            ),
          );
        }
      }
    }
    return VerificationReport(
      movesChecked: completed ? previous.length : 0,
      evalsRun: values.length,
      passes: completed ? 1 : 0,
      verifyDepth: depth,
      demotions: demotions,
      completed: completed,
      selectedCount: count,
    );
  }
}
