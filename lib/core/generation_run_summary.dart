/// The one-sentence outcome of a finished generation run, as shown on the
/// job tile and the status line.
///
/// Pure composition over the run's results, kept apart from the pipeline so
/// the wording can be read and tested without an engine.
library;

import '../chess_core/generation/build_tree_node.dart';
import '../services/generation/course/chapter_titles.dart';
import '../services/generation/course/course_composer.dart';
import '../services/generation/generation_config.dart';
import '../utils/time_format.dart';
import 'generation_session_types.dart';

/// How many positions the best-effort post-build passes touched.
typedef EnrichmentCounts = ({
  int refutations,
  int alternatives,
  int improvements,
});

/// Compose the summary of a completed export.
///
/// [duplicatesSkipped] lines were already in the repertoire file and not
/// written again; [modelGameNote] explains a missing model-games section
/// (empty when there is nothing to explain); [bookStats] carries the
/// ChessDB hit counts of a book build; [finishedEarly] marks a run the user
/// stopped to export what existed so far.
String composeRunSummary({
  required BuildTree tree,
  required TreeAnalysis analysis,
  required ExtractedLines extracted,
  required TreeBuildConfig config,
  required Duration elapsed,
  required int duplicatesSkipped,
  required List<ChapterOutline> courseOutline,
  required EnrichmentCounts enrichment,
  required String modelGameNote,
  required BuildStats bookStats,
  required bool finishedEarly,
}) {
  final pruneNote = extracted.wasPruned
      ? ' (pruned from ${extracted.rawCount})'
      : '';
  final duplicateNote = duplicatesSkipped > 0
      ? ' $duplicatesSkipped line${duplicatesSkipped == 1 ? '' : 's'} '
            'already in the repertoire ${duplicatesSkipped == 1 ? 'was' : 'were'} '
            'not written again.'
      : '';
  final buffer = StringBuffer(
    '${tree.buildComplete ? 'Complete' : 'Incomplete search'} in '
    '${formatCompactDuration(elapsed)}: ${tree.totalNodes} nodes, '
    '${analysis.selectedCount} repertoire moves, '
    '${extracted.lines.length} lines$pruneNote'
    '${courseNote(courseOutline, enrichment)}.'
    '$duplicateNote${extracted.trapsOnlyNote}$modelGameNote',
  );
  if (tree.root.historyAware) {
    final root = tree.root;
    final label = config.isRollingSearch
        ? 'Fast policy estimate (approximate)'
        : 'Expected-score estimate';
    buffer.write(
      ' $label: ${root.expectimaxValue.toStringAsFixed(4)}; bounds '
      '[${root.valueLower.toStringAsFixed(4)}, '
      '${root.valueUpper.toStringAsFixed(4)}].',
    );
  }
  if (config.isChessDbBook) {
    buffer.write(' ${bookSourceNote(bookStats)}');
  }
  if (finishedEarly && config.runsVerification) {
    buffer.write(' Verification skipped (finished early).');
  }
  return buffer.toString();
}

/// ` in 7 chapters plus 6 model games`, or empty when the export was flat
/// and no enrichment pass added anything.
String courseNote(List<ChapterOutline> outline, EnrichmentCounts enrichment) {
  if (outline.isEmpty) return '';
  final chapters = outline.where((c) => c.kind == ChapterKind.lines).length;
  final games = outline
      .where((c) => c.kind == ChapterKind.modelGames)
      .fold(0, (sum, c) => sum + c.entryCount);
  final (:refutations, :alternatives, :improvements) = enrichment;
  if (chapters < 2 &&
      games == 0 &&
      refutations == 0 &&
      alternatives == 0 &&
      improvements == 0) {
    return '';
  }
  return [
    if (chapters >= 2) ' in $chapters chapters',
    if (games > 0) '${chapters >= 2 ? ' plus' : ' with'} $games model games',
    if (refutations > 0) ', $refutations punished replies',
    if (alternatives > 0) ', $alternatives refuted alternatives',
    if (improvements > 0) ', $improvements improvements on master games',
  ].join();
}

/// How much of a ChessDB book actually came from ChessDB.
///
/// A book built mostly by the engine fallback is a different artifact from
/// one the database wrote, and the difference is invisible in the PGN — so
/// it is said out loud rather than left to be inferred from the node count.
String bookSourceNote(BuildStats stats) {
  final db = stats.bookDbMoveHits;
  final engine = stats.bookEngineFallbacks;
  final total = db + engine;
  if (total == 0) return '';
  final share = (100 * db / total).round();
  final dead = stats.bookDeadEnds;
  return 'ChessDB named $db positions and the engine $engine ($share% '
      'ChessDB)'
      '${dead > 0 ? ', $dead lines ended with no move available' : ''}.';
}
