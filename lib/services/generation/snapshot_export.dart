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
import '../../utils/findability.dart';
import 'eca_calculator.dart';
import 'engine_tail.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'line_extractor.dart';
import 'line_pruner.dart';
import 'pgn_export.dart';
import 'repertoire_selector.dart';
import 'trap_extractor.dart';
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

  /// Engine continuations keyed by leaf FEN, if the caller computed any.
  final Map<String, EngineTail> engineTails;

  const SnapshotExportRequest({
    required this.treeJson,
    required this.configJson,
    required this.prefix,
    required this.repertoireStartFen,
    this.stopAfterSelection = false,
    this.engineTails = const {},
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
  // The snapshot stores the config as the user set it; selection must see
  // the same root-anchored eval window the build used.
  final config = TreeBuildConfig.fromJson(
    request.configJson,
    startFen: tree.root.fen,
  ).anchoredToRoot(tree.root);

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
      engineTails: request.engineTails,
    ),
    selectedCount: selectedCount,
    totalNodes: tree.totalNodes,
    maxPly: tree.maxPlyReached,
  );
}

/// Extract lines from a post-selection tree and format them as PGN entries.
/// Mirrors the final pipeline's export loop in [GenerationSessionController].
/// [engineTails] is keyed by leaf FEN; a line whose leaf is present gets the
/// continuation hung off its final move. Computed by the caller because it
/// needs the engine and this function is isolate-pure.
/// The lines a snapshot exports: extracted, trap-filtered, coverage-pruned
/// and ranked — everything [extractSnapshotLines] does except turning them
/// into PGN text.  Split out so a caller that needs the lines themselves
/// (the master-improvement prober wants `ExtractedLine`, not movetext) gets
/// exactly the set that will be written, instead of re-deriving the policy
/// and drifting from it.
List<ExtractedLine> snapshotLines({
  required BuildTree tree,
  required TreeBuildConfig config,
  required FenMap fenMap,
}) {
  tree.sortAllChildren();
  tree.computeMetadata();

  final extractor = LineExtractor(config: config, fenMap: fenMap);
  var extractedLines = extractor.extract(tree);
  if (config.trapsOnly) {
    extractedLines = keepLinesThroughTraps(
      extractedLines,
      TrapExtractor(
        playAsWhite: config.playAsWhite,
        findabilityPRef: pRefForElo(config.maiaElo),
      ).extract(tree),
      (line) => line.movesSan,
    );
  }
  extractedLines = LinePruner.prune(
    extractedLines,
    targetCount: config.targetLineCount,
    coverageTarget: config.lineCoverageTarget,
  );
  if (config.rankLinesByImportance) {
    extractedLines.sort((a, b) => b.probability.compareTo(a.probability));
  }
  return extractedLines;
}

List<String> extractSnapshotLines({
  required BuildTree tree,
  required TreeBuildConfig config,
  required FenMap fenMap,
  required List<String> prefix,
  required String repertoireStartFen,
  Map<String, EngineTail> engineTails = const {},
}) {
  final extractedLines = snapshotLines(
    tree: tree,
    config: config,
    fenMap: fenMap,
  );

  final rootFen = prefix.isEmpty ? tree.root.fen : repertoireStartFen;
  return [
    for (var i = 0; i < extractedLines.length; i++)
      writeRepertoireLine(
        movesSan: [...prefix, ...extractedLines[i].movesSan],
        title: 'Generated Line ${i + 1}',
        line: extractedLines[i],
        isWhiteRepertoire: config.playAsWhite,
        rootFen: rootFen,
        detail: config.annotationDetail,
        annotationOffset: prefix.length,
        rankByImportance: config.rankLinesByImportance,
        engineTail: engineTails[extractedLines[i].leafFen],
      ),
  ];
}
