/// Value types passed into and out of the generation session controller.
///
/// Split out of `generation_session_controller.dart` by pure code motion;
/// re-exported from there so existing importers are unaffected.
library;

import '../models/build_tree_node.dart';
import '../services/generation/generation_config.dart';

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
