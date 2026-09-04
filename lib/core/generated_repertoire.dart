/// Immutable bundle of a generated repertoire tree and **all** artifacts
/// derived from it.
///
/// This is the single source of truth produced by [GenerationSessionController]
/// the moment a tree is built. Every view (eval-tree graph, lines browser,
/// traps browser) reads from one instance, so they can never disagree about
/// the tree, its transposition map, or its traps.
///
/// See `docs/REFACTOR_PLAN.md` §1.2 — derived state is computed once, here,
/// never inside widget lifecycle callbacks.
library;

import '../features/eval_tree/adapters/eval_tree_snapshot_adapter.dart';
import '../features/eval_tree/models/eval_tree_snapshot.dart';
import '../features/eval_tree/services/eval_tree_line_metrics.dart';
import '../features/traps/services/trap_index_service.dart';
import '../models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/trap_extractor.dart';
import '../utils/findability.dart';

class GeneratedRepertoire {
  /// The cooked tree (ease, expectimax, trap scores, repertoire selection all
  /// applied). Treated as immutable by consumers.
  final BuildTree tree;

  /// Whether this repertoire is from the side-to-move's (White's) perspective.
  final bool playAsWhite;

  /// Transposition table over the tree (canonical-FEN → first-expanded node).
  final FenMap fenMap;

  /// Flattened, display-ready snapshot for the eval-tree graph.
  final EvalTreeSnapshot snapshot;

  /// Per-line metric cache derived from [snapshot].
  final EvalTreeLineMetricsCache metricsCache;

  /// Trap index built from the in-memory tree (O(1) by FEN, O(n) per line).
  final TrapIndexService traps;

  /// Config snapshot the tree was built with (may be null for legacy trees).
  final TreeBuildConfig? config;

  /// On-demand expectimax probes rooted at positions [tree] never reached.
  /// Part of the [fenMap] — the expectimax pane finds them there — but not
  /// of the graph snapshot or the trap index, which describe the repertoire
  /// the build chose.
  final List<BuildTree> probes;

  const GeneratedRepertoire({
    required this.tree,
    required this.playAsWhite,
    required this.fenMap,
    required this.snapshot,
    required this.metricsCache,
    required this.traps,
    this.config,
    this.probes = const [],
  });

  /// Every tree in the database, main tree first.
  List<BuildTree> get allTrees => [tree, ...probes];

  /// The same repertoire with a different probe set.
  ///
  /// [snapshot], [metricsCache] and [traps] describe [tree] alone — probes are
  /// deliberately not part of the graph or the trap index (see [probes]) — so
  /// a probe landing cannot invalidate them. Only [fenMap] spans the whole
  /// database.
  ///
  /// Going back through [fromTree] for this, which is what the probe path used
  /// to do, redid all four: a full flatten of the build's own tree, the metric
  /// pass over that snapshot, and a full trap extraction, every time a probe
  /// was added — none of which could produce a different answer.
  GeneratedRepertoire withProbes(List<BuildTree> newProbes) {
    return GeneratedRepertoire(
      tree: tree,
      playAsWhite: playAsWhite,
      fenMap: _mapOver(tree, newProbes),
      snapshot: snapshot,
      metricsCache: metricsCache,
      traps: traps,
      config: config,
      probes: List.unmodifiable(newProbes),
    );
  }

  /// Transposition map over the whole database, main tree first so a position
  /// both hold resolves to the build's own node.
  static FenMap _mapOver(BuildTree tree, List<BuildTree> probes) {
    final fenMap = FenMap()..populate(tree.root);
    for (final probe in probes) {
      fenMap.populate(probe.root);
    }
    return fenMap..freeze();
  }

  /// Derive every artifact from [tree] exactly once.
  ///
  /// The tree must already be cooked (expectimax + trap scores computed) for
  /// the trap index to be populated; an uncooked tree simply yields an empty
  /// trap index.
  factory GeneratedRepertoire.fromTree(
    BuildTree tree, {
    required bool playAsWhite,
    TreeBuildConfig? config,
    List<BuildTree> probes = const [],
  }) {
    final fenMap = _mapOver(tree, probes);
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: playAsWhite,
    );
    final metricsCache = EvalTreeLineMetricsCache.fromSnapshot(snapshot);
    final extracted = TrapExtractor(
      playAsWhite: playAsWhite,
      findabilityPRef: config != null ? pRefForElo(config.maiaElo) : null,
    ).extract(tree);
    final traps = TrapIndexService(extracted);

    return GeneratedRepertoire(
      tree: tree,
      playAsWhite: playAsWhite,
      fenMap: fenMap,
      snapshot: snapshot,
      metricsCache: metricsCache,
      traps: traps,
      config: config,
      probes: List.unmodifiable(probes),
    );
  }
}
