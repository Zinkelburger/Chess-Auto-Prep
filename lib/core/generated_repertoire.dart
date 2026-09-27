/// Generated tree with its shared position and trap indexes.
///
/// Derived state is computed once when the generation session adopts a tree;
/// position and line views use the same tree, FEN map and trap index.
library;

import '../features/traps/services/trap_index_service.dart';
import '../chess_core/generation/build_tree_node.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/trap_extractor.dart';
import '../utils/findability.dart';

class GeneratedRepertoire {
  /// The cooked tree (ease, expectimax, trap scores, repertoire selection all
  /// applied). Treated as immutable by consumers.
  final BuildTree tree;

  /// Whether this repertoire is from the side-to-move's (White's) perspective.
  final bool playAsWhite;

  /// Transposition table over the tree (canonical-FEN → first-expanded node).
  final FenMap fenMap;

  /// Trap index built from the in-memory tree (O(1) by FEN, O(n) per line).
  final TrapIndexService traps;

  /// Config snapshot the tree was built with (may be null for legacy trees).
  final TreeBuildConfig? config;

  /// On-demand expectimax probes rooted at positions [tree] never reached.
  /// Part of the [fenMap] used by position views, but not the trap index,
  /// which describes the repertoire the build chose.
  final List<BuildTree> probes;

  const GeneratedRepertoire({
    required this.tree,
    required this.playAsWhite,
    required this.fenMap,
    required this.traps,
    this.config,
    this.probes = const [],
  });

  /// Every tree in the database, main tree first.
  List<BuildTree> get allTrees => [tree, ...probes];

  /// The same repertoire with a different probe set.
  ///
  /// [traps] describes [tree] alone, so only
  /// [fenMap] needs rebuilding when the separate probes change. The caller
  /// must use [fromTree] instead if it changed the main tree's evals or
  /// grafted new children into it.
  GeneratedRepertoire withProbes(List<BuildTree> newProbes) {
    return GeneratedRepertoire(
      tree: tree,
      playAsWhite: playAsWhite,
      fenMap: _mapOver(tree, newProbes),
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
    for (final probe in probes) {
      if (probe.configSnapshot['bounded_database'] == true) {
        fenMap.overlay(probe.root);
      }
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
    final extracted = TrapExtractor(
      playAsWhite: playAsWhite,
      findabilityPRef: config != null ? pRefForElo(config.maiaElo) : null,
    ).extract(tree);
    final traps = TrapIndexService(extracted);

    return GeneratedRepertoire(
      tree: tree,
      playAsWhite: playAsWhite,
      fenMap: fenMap,
      traps: traps,
      config: config,
      probes: List.unmodifiable(probes),
    );
  }
}
