/// Mid-run snapshot export — runs the pure post-build phases (ease,
/// expectimax, selection, line extraction, PGN formatting) on a serialized
/// copy of the in-progress tree so lines can be exported while the build
/// keeps running.
///
/// [runSnapshotExport] is isolate-safe: it touches no engine, storage, or
/// UI state, so callers run it via `Isolate.run` and the main isolate never
/// blocks on the tree walks.  The verified-export path stops after selection
/// and returns the selected tree as JSON; the caller then runs the engine
/// verification pass on the main isolate (where the Stockfish pool lives)
/// and finishes with [extractSnapshotLines].
library;

import '../../models/build_tree_node.dart';
import '../../utils/fen_utils.dart';
import 'eca_calculator.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'line_extractor.dart';
import 'pgn_export.dart';
import 'repertoire_selector.dart';
import 'tree_ease.dart';
import 'tree_my_ease.dart';
import 'tree_serialization.dart';

class SnapshotExportRequest {
  /// Serialized [BuildTree] (v4 JSON) captured from the live build.
  final String treeJson;
  final Map<String, dynamic> configJson;

  /// SAN prefix from the repertoire root to the tree root.
  final List<String> prefix;

  /// The repertoire's starting position, for the PGN `[FEN]` header when
  /// [prefix] is non-empty.
  final String repertoireStartFen;

  /// True for verified exports: stop after selection and return the tree
  /// as JSON so the caller can run the engine pass before extraction.
  final bool stopAfterSelection;

  const SnapshotExportRequest({
    required this.treeJson,
    required this.configJson,
    required this.prefix,
    required this.repertoireStartFen,
    this.stopAfterSelection = false,
  });
}

class SnapshotExportResult {
  /// Complete PGN entries, one per extracted line.  Empty when
  /// [SnapshotExportRequest.stopAfterSelection] was set.
  final List<String> pgnEntries;

  /// Post-selection tree JSON, only for the stop-after-selection path.
  final String? selectedTreeJson;

  final int selectedCount;
  final int totalNodes;
  final int maxPly;

  const SnapshotExportResult({
    required this.pgnEntries,
    this.selectedTreeJson,
    required this.selectedCount,
    required this.totalNodes,
    required this.maxPly,
  });
}

/// Deserialize, run ease/expectimax/selection, and either extract lines or
/// return the selected tree for verification.  Top-level and pure so it can
/// run via `Isolate.run`.
SnapshotExportResult runSnapshotExport(SnapshotExportRequest request) {
  final tree = deserializeTree(request.treeJson);
  final config = TreeBuildConfig.fromJson(
    request.configJson,
    startFen: tree.root.fen,
  );

  calculateTreeEase(tree);
  final fenMap = FenMap()..populate(tree.root);
  final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
  ecaCalc.calculate(tree);
  ecaCalc.computeTrapScores(tree.root);
  ecaCalc.calculateCplValues(tree.root);
  calculateMyEase(tree, playAsWhite: config.playAsWhite);
  final selector = RepertoireSelector(
    config: config,
    ecaCalc: ecaCalc,
    fenMap: fenMap,
  );
  final selectedCount = selector.select(tree);

  if (request.stopAfterSelection) {
    return SnapshotExportResult(
      pgnEntries: const [],
      selectedTreeJson: serializeTree(tree),
      selectedCount: selectedCount,
      totalNodes: tree.totalNodes,
      maxPly: tree.maxPlyReached,
    );
  }

  return SnapshotExportResult(
    pgnEntries: extractSnapshotLines(
      tree: tree,
      config: config,
      fenMap: fenMap,
      prefix: request.prefix,
      repertoireStartFen: request.repertoireStartFen,
    ),
    selectedCount: selectedCount,
    totalNodes: tree.totalNodes,
    maxPly: tree.maxPlyReached,
  );
}

/// Extract lines from a post-selection tree and format them as PGN entries.
/// Mirrors the final pipeline's export loop in [GenerationSessionController].
List<String> extractSnapshotLines({
  required BuildTree tree,
  required TreeBuildConfig config,
  required FenMap fenMap,
  required List<String> prefix,
  required String repertoireStartFen,
}) {
  tree.sortAllChildren();
  tree.computeMetadata();

  final extractor = LineExtractor(config: config, fenMap: fenMap);
  final extractedLines = extractor.extract(tree);
  if (config.rankLinesByImportance) {
    extractedLines.sort((a, b) => b.probability.compareTo(a.probability));
  }

  final rootFen = prefix.isEmpty ? tree.root.fen : repertoireStartFen;
  final rootWhiteToMove = isWhiteToMove(rootFen);
  final entries = <String>[];
  for (int i = 0; i < extractedLines.length; i++) {
    final line = extractedLines[i];
    entries.add(buildRepertoirePgnEntry(
      moves: [...prefix, ...line.movesSan],
      title: 'Generated Line ${i + 1}',
      cumulativeProb: line.probability,
      finalEvalCp: line.leafEvalCp ?? 0,
      isWhiteRepertoire: config.playAsWhite,
      rootFen: rootFen,
      rootWhiteToMove: rootWhiteToMove,
      pruneReason: line.leafPruneReason,
      pruneEvalCp: line.leafPruneEvalCp,
      lineAnnotations: line.moveAnnotations,
      prefixMoveCount: prefix.length,
      rankByImportance: config.rankLinesByImportance,
      annotateMoveProbabilities: config.annotateMoveProbabilities,
      annotateMaiaOnly: config.annotateMaiaOnly,
    ));
  }
  return entries;
}
