/// Value types passed into and out of the generation session controller.
library;

import 'dart:async';
import '../utils/movetext_builder.dart';

import '../features/documents/models/pgn_document.dart';
import '../chess_core/generation/build_tree_node.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/line_extractor.dart';
import '../services/generation/line_pruner.dart';

/// Everything a generation run needs, captured at start time so the run is
/// independent of any widget lifecycle.
class GenerationRequest {
  final TreeBuildConfig config;

  /// Display name captured with the source, never read from a mutable screen.
  final String jobLabel;

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

  /// Source-bound artifact selection captured by the saved-partial card.
  final String? artifactGeneration;

  /// Awaited once after source publication. The host adopts the committed
  /// document under its captured chapter session, before another run starts.
  final FutureOr<void> Function(PgnSnapshot saved) onPublished;

  /// Move sequences (from the repertoire's start, as [lineKey] strings) the
  /// repertoire file already holds.  A generated line that matches one is
  /// not written again: the export appends to the file, so without this a
  /// second build into the same chapter doubled every line.
  final Set<String> existingLineKeys;

  /// An on-demand expectimax probe: build the tree and fold it into the
  /// repertoire's expectimax database, then stop — no verification, no
  /// lines, no PGN. See `GenerationSessionController.computeExpectimax`.
  final bool expectimaxOnly;

  const GenerationRequest({
    required this.config,
    required this.jobLabel,
    required this.repertoireFilePath,
    required this.buildRootFen,
    required this.lineMovePrefix,
    required this.repertoireStartFen,
    required this.onPublished,
    this.existingTree,
    this.artifactGeneration,
    this.existingLineKeys = const {},
    this.expectimaxOnly = false,
  });

  /// A probe into [target]'s repertoire database, rooted at [buildRootFen]
  /// after [lineMovePrefix]: nothing is exported, so no lines are reported.
  GenerationRequest.expectimaxProbe({
    required this.config,
    required ExpectimaxProbeTarget target,
    required this.buildRootFen,
    required this.lineMovePrefix,
  }) : jobLabel =
           'Expectimax · ${lineMovePrefix.isEmpty ? 'start position' : buildNumberedMovetext(lineMovePrefix)}',
       repertoireFilePath = target.repertoireFilePath,
       repertoireStartFen = target.repertoireStartFen,
       onPublished = _ignorePublication,
       existingTree = null,
       artifactGeneration = null,
       existingLineKeys = const {},
       expectimaxOnly = true;

  static void _ignorePublication(PgnSnapshot saved) {}

  /// The identity of a line for duplicate detection: its SAN moves from the
  /// repertoire start, space-joined.
  static String lineKey(List<String> moves) => moves.join(' ');

  /// SAN prefix (from the repertoire root) that exported lines must carry.
  ///
  /// A fresh build uses [lineMovePrefix].  A resumed build trusts the prefix
  /// recorded on the saved tree — the board may have moved since the build
  /// was paused.  A legacy partial tree without a recorded prefix can only
  /// resume from the exact position it was built from; throws [StateError]
  /// otherwise.
  List<String> resolveLinePrefix() {
    final tree = existingTree;
    if (tree == null) return lineMovePrefix;
    if (tree.startMoves.isNotEmpty) {
      return tree.startMoves
          .split(' ')
          .where((m) => m.isNotEmpty)
          .toList(growable: false);
    }
    if (tree.root.fen == buildRootFen) return lineMovePrefix;
    throw StateError(
      'Cannot resume: the paused build started from a different position. '
      'Navigate to that position first, or discard the paused build.',
    );
  }
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

  /// Lines too close to a kept line to earn an entry, keyed by the kept
  /// line they hang off.  The export writes them as sidelines rather than
  /// losing the reply they carry — see [LineDiversity].
  final Map<String, List<FoldedLine>> folds;

  /// Sentence fragment appended to the run summary when "only traps" ran.
  final String trapsOnlyNote;

  const ExtractedLines({
    required this.lines,
    required this.rawCount,
    required this.trapsOnlyNote,
    this.folds = const {},
  });

  bool get wasPruned => lines.length < rawCount;

  /// How many lines the export carries as a sideline instead of an entry.
  int get foldedCount => folds.values.fold(0, (sum, list) => sum + list.length);
}

/// Where an on-demand expectimax probe is rooted: the repertoire it belongs
/// to and the moves from that repertoire's start to the position, plus the
/// one move to play first when the user asked for a specific move.
class ExpectimaxProbeTarget {
  const ExpectimaxProbeTarget({
    required this.repertoireFilePath,
    required this.repertoireStartFen,
    required this.movesFromStart,
    required this.plies,
    required this.playAsWhite,
    this.moveSan,
    this.engineThreads,
    this.engineMoves = 4,
    this.maiaCoverage = .60,
  });

  final String repertoireFilePath;
  final String repertoireStartFen;
  final List<String> movesFromStart;

  /// "Compute this move": the probe is rooted after this SAN move.
  final String? moveSan;

  /// Half-moves to explore below the root.
  final int plies;
  final bool playAsWhite;
  final int? engineThreads;
  final int engineMoves;
  final double maiaCoverage;

  /// The moves from the repertoire start to the probe root, [moveSan]
  /// included.
  List<String> get moves => [...movesFromStart, ?moveSan];

  /// Settings for evaluating the single position at [fen]: the form
  /// defaults with the requested cores and no verification.
  TreeBuildConfig movePvConfig(String fen) => TreeBuildConfig.formDefaults(
    startFen: fen,
    playAsWhite: playAsWhite,
  ).copyWith(engineThreads: engineThreads, verifyFinal: false);

  /// Settings for a probe rooted at [fen], derived from [base] (the last
  /// build's config, or the form defaults) with everything that is not about
  /// scoring the position switched off: no line export, no verification, no
  /// master-game download, no skeleton, and the ChessDB API only when
  /// [enableChessDbApi] allows it.
  TreeBuildConfig probeConfig({
    required TreeBuildConfig base,
    required String fen,
    required bool enableChessDbApi,
  }) => base.copyWith(
    startFen: fen,
    playAsWhite: playAsWhite,
    maxPly: plies,
    boundedDatabase: true,
    ourMultipv: engineMoves.clamp(1, 20),
    oppMassTarget: maiaCoverage.clamp(.01, 1),
    searchAlgorithm: SearchAlgorithm.pure,
    // Coverage answers and master extensions belong to line planning.
    // A position search observes the depth the user asked for.
    coverMinProb: 0,
    masterDepthBonusPlies: 0,
    engineThreads: engineThreads == null
        ? null
        : clampEngineThreads(engineThreads!),
    timeBudgetMinutes: 0,
    buildMode: BuildMode.stockfishExpectimax,
    pgnFilePaths: const [],
    verifyFinal: false,
    trapsOnly: false,
    rootReplyExclude: const [],
    setupMoves: '',
    skeletonPlan: const SkeletonPlan(),
    downloadMasterGamesIfMissing: false,
    enableChessDbApi: enableChessDbApi,
  );
}
