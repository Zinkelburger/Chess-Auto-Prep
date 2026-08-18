/// Value types passed into and out of the generation session controller.
///
/// Split out of `generation_session_controller.dart` by pure code motion;
/// re-exported from there so existing importers are unaffected.
library;

import '../models/build_tree_node.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/line_extractor.dart';

/// One exported line from a completed generation run.
class GeneratedLineExport {
  /// Full SAN move list from the repertoire's starting position.
  final List<String> moves;
  final String title;
  final String pgn;

  const GeneratedLineExport({
    required this.moves,
    required this.title,
    required this.pgn,
  });
}

/// Everything a generation run needs, captured at start time so the run is
/// independent of any widget lifecycle.
class GenerationRequest {
  final TreeBuildConfig config;

  /// Repertoire PGN file the generated lines are appended to.
  final String repertoireFilePath;

  /// Position the tree is built from (the current board position).
  final String buildRootFen;

  /// SAN moves from the repertoire's starting position to [buildRootFen].
  /// Exported lines are prefixed with these so they replay from the
  /// repertoire root.
  final List<String> lineMovePrefix;

  /// The repertoire's own starting position (standard FEN when the
  /// repertoire starts from the initial position).  Used for the PGN
  /// `[FEN]` header when [lineMovePrefix] is non-empty.
  final String repertoireStartFen;

  /// Partial tree to resume, or null for a fresh build.
  final BuildTree? existingTree;

  /// Called once with every exported line after the PGN file is written.
  final void Function(List<GeneratedLineExport> lines) onLinesSaved;

  const GenerationRequest({
    required this.config,
    required this.repertoireFilePath,
    required this.buildRootFen,
    required this.lineMovePrefix,
    required this.repertoireStartFen,
    required this.onLinesSaved,
    this.existingTree,
  });
}

/// What Phase 2 produces: the scored tree's derived structures plus the
/// counts the run summary and debug dump report.
///
/// Exists so the phase methods hand each other a named result instead of
/// sharing a dozen locals inside one long pipeline method.
class TreeAnalysis {
  final FenMap fenMap;
  final ExpectimaxCalculator ecaCalc;
  final int easeCount;
  final int ecaCount;

  /// Repertoire moves marked by the selector. Mutable because Phase 2.5
  /// verification may demote moves and revise the count.
  int selectedCount;

  TreeAnalysis({
    required this.fenMap,
    required this.ecaCalc,
    required this.easeCount,
    required this.ecaCount,
    required this.selectedCount,
  });
}

/// What Phase 3 produces: the lines to export, plus what was dropped getting
/// there so the summary can explain the shortfall.
class ExtractedLines {
  /// Lines surviving the trap filter, similarity pruning, and ranking.
  final List<ExtractedLine> lines;

  /// How many lines existed before similarity pruning.
  final int rawCount;

  /// Sentence fragment appended to the run summary when "only traps" ran.
  final String trapsOnlyNote;

  const ExtractedLines({
    required this.lines,
    required this.rawCount,
    required this.trapsOnlyNote,
  });

  bool get wasPruned => lines.length < rawCount;
}
