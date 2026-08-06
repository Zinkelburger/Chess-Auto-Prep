/// Assembling planned chapters, named variations, and model games into the
/// PGN games that get written to disk.
///
/// Chapters are encoded the way published course exports do it — `[White]`
/// names the chapter, `[Black]` names the variation, and `[Result]` stays
/// `*` — which is the format `RepertoireService.detectHeaderChapters` already
/// reads.  Every line therefore remains its own game, so training, browsing
/// and line-level statistics are unchanged; only the grouping is new.
library;

import '../../../constants/chess_constants.dart';
import '../../../models/repertoire_line.dart'
    show
        kModelGameBlackEloTag,
        kModelGameBlackTag,
        kModelGameDateTag,
        kModelGameEventTag,
        kModelGameResultTag,
        kModelGameWhiteEloTag,
        kModelGameWhiteTag;
import '../../../utils/fen_utils.dart';
import '../export/move_annotation.dart';
import '../export/pgn_game_writer.dart';
import '../generation_config.dart';
import '../line_extractor.dart';
import 'chapter_planner.dart';
import 'chapter_titles.dart';
import 'model_game_selector.dart';
import 'refutation_prober.dart';

// ── Output ───────────────────────────────────────────────────────────────

/// One PGN game in the composed course.
class CourseEntry {
  /// Full SAN moves from the repertoire's start position.
  final List<String> movesSan;

  final String chapterName;
  final String variationName;
  final String pgn;

  /// Moves written as a sideline showing how the line's last move is
  /// punished, empty when it needs no punishing.  Carried here so callers and
  /// tests can see what was attached without re-parsing [pgn].
  final List<String> refutation;

  /// Moves the line does *not* play, each written as a sideline showing why —
  /// the natural move we pass over, the try the opponent should avoid.
  final List<String> refutedAlternatives;

  const CourseEntry({
    required this.movesSan,
    required this.chapterName,
    required this.variationName,
    required this.pgn,
    this.refutation = const [],
    this.refutedAlternatives = const [],
  });
}

/// A chapter as it appears in the finished file — for the run summary and
/// for tests that care about structure rather than text.
class ChapterOutline {
  final String name;
  final int entryCount;
  final ChapterKind kind;

  const ChapterOutline({
    required this.name,
    required this.entryCount,
    required this.kind,
  });
}

class ComposedCourse {
  final String title;
  final List<CourseEntry> entries;
  final List<ChapterOutline> outline;

  const ComposedCourse({
    required this.title,
    required this.entries,
    required this.outline,
  });

  int get lineChapterCount =>
      outline.where((c) => c.kind == ChapterKind.lines).length;

  int get modelGameCount => outline
      .where((c) => c.kind == ChapterKind.modelGames)
      .fold(0, (sum, c) => sum + c.entryCount);

  String toPgn() => entries.map((e) => e.pgn).join('\n');
}

// ── Composer ─────────────────────────────────────────────────────────────

class CourseComposer {
  CourseComposer({
    required this.config,
    required this.namer,
    required this.repertoireStartFen,
    required this.repertoirePrefix,
    this.repertoireName,
  });

  final TreeBuildConfig config;
  final CourseNamer namer;

  /// Position the exported games start from — the repertoire file's root, not
  /// the build root, since the prefix moves are part of every line.
  final String repertoireStartFen;

  /// Moves from [repertoireStartFen] to the build root.
  final List<String> repertoirePrefix;

  final String? repertoireName;

  /// Punishing continuations for lines that end on a losing reply, keyed by
  /// the position they start from.  Set for the duration of [compose].
  RefutationMap _refutations = const {};

  /// Refuted moves the book leaves out, keyed by the position they are played
  /// in.  Set for the duration of [compose].
  AlternativeMap _alternatives = const {};

  ComposedCourse compose({
    required List<ExtractedLine> lines,
    List<ModelGame> modelGames = const [],
    RefutationMap refutations = const {},
    AlternativeMap alternatives = const {},
  }) {
    _refutations = refutations;
    _alternatives = alternatives;
    final title = namer.courseTitle(fallback: repertoireName);
    final groups = config.organizeIntoChapters
        ? ChapterPlanner(
            maxLines: config.maxLinesPerChapter,
            minLines: config.minLinesPerChapter,
          ).plan(lines)
        : [ChapterGroup(prefixSan: const [], lines: lines)];

    final titles = namer.nameChapters(groups);
    final entries = <CourseEntry>[];
    final outline = <ChapterOutline>[];

    for (var c = 0; c < groups.length; c++) {
      final group = groups[c];
      final chapter = titles[c];
      // Strip the "3. " prefix before comparing against variation names, so a
      // variation is not renamed just because it echoes its chapter's index.
      final variationNames = namer.variationNames(
        group,
        chapterBaseName: _withoutIndex(chapter.name),
      );

      for (var i = 0; i < group.lines.length; i++) {
        entries.add(
          _lineEntry(
            group: group,
            lineIndex: i,
            chapter: chapter,
            variationName: variationNames[i],
            courseTitle: title,
          ),
        );
      }
      outline.add(
        ChapterOutline(
          name: chapter.name,
          entryCount: group.lines.length,
          kind: ChapterKind.lines,
        ),
      );
    }

    if (modelGames.isNotEmpty) {
      final chapter = ChapterTitle(
        index: groups.length + 1,
        name: '${groups.length + 1}. Model games',
        kind: ChapterKind.modelGames,
      );
      for (final game in modelGames) {
        entries.add(_modelGameEntry(game, chapter, title));
      }
      outline.add(
        ChapterOutline(
          name: chapter.name,
          entryCount: modelGames.length,
          kind: ChapterKind.modelGames,
        ),
      );
    }

    return ComposedCourse(title: title, entries: entries, outline: outline);
  }

  // ── Entries ────────────────────────────────────────────────────────────

  CourseEntry _lineEntry({
    required ChapterGroup group,
    required int lineIndex,
    required ChapterTitle chapter,
    required String variationName,
    required String courseTitle,
  }) {
    final line = group.lines[lineIndex];
    final moves = [...repertoirePrefix, ...line.movesSan];
    final alternatives = _alternativesFor(line);

    return CourseEntry(
      refutation: _refutationFor(line),
      refutedAlternatives: [for (final a in alternatives.values) a.san],
      movesSan: moves,
      chapterName: chapter.name,
      variationName: variationName,
      pgn: writePgnGame(
        PgnGameSpec(
          headers: {
            'Event': courseTitle,
            'White': chapter.name,
            'Black': variationName,
            'Result': '*',
            'Annotator': 'Chess Auto Prep',
            if (chapter.eco != null) 'ECO': chapter.eco!,
            // Read back by RepertoireService as the line's importance.
            if (config.rankLinesByImportance)
              'CumProb': _percent(line.probability),
            // Belt and braces: when a course has only one chapter the header
            // grouping is not detected, and the line name falls back to
            // [Opening].
            'Opening': variationName,
          },
          movesSan: moves,
          annotations: line.moveAnnotations,
          annotationOffset: repertoirePrefix.length,
          startFen: repertoireStartFen,
          rootWhiteToMove: isWhiteToMove(repertoireStartFen),
          startMoveNumber: namer.startMoveNumber,
          variations: _sidelines(moves, line, alternatives),
        ),
        detail: config.annotationDetail,
      ),
    );
  }

  /// The engine's punishment of the reply this line ends on, or empty.
  List<String> _refutationFor(ExtractedLine line) {
    final fen = line.leafFen;
    if (fen == null) return const [];
    return _refutations[fen] ?? const [];
  }

  /// Refuted alternatives along [line], keyed by the index of the move they
  /// replace.  A position is only asked about once per line even when the
  /// line returns to it.
  Map<int, RefutedAlternative> _alternativesFor(ExtractedLine line) {
    final out = <int, RefutedAlternative>{};
    for (final choice in line.choices) {
      final found = _alternatives[choice.fenBefore];
      if (found != null) out[choice.moveIndex] = found;
    }
    return out;
  }

  /// Every sideline this line carries, keyed by the mainline move it hangs
  /// off: what the moves we skipped run into, and — last, so the line reads
  /// forwards — how the reply it ends on is punished.
  ///
  /// The punishment repeats the move it hangs off, which is how PGN writes a
  /// continuation rather than an alternative: the reader clicks the move and
  /// walks into what it runs into.  The mainline still ends where the
  /// repertoire ends, so nothing here becomes trainable.
  Map<int, List<PgnSideline>> _sidelines(
    List<String> moves,
    ExtractedLine line,
    Map<int, RefutedAlternative> alternatives,
  ) {
    if (moves.isEmpty) return const {};
    final out = <int, List<PgnSideline>>{};

    for (final entry in alternatives.entries) {
      final index = repertoirePrefix.length + entry.key;
      if (index >= moves.length) continue;
      final alternative = entry.value;
      (out[index] ??= []).add(
        PgnSideline([
          alternative.sanWithNag,
          ...alternative.continuation,
        ], comment: _alternativeComment(alternative)),
      );
    }

    final refutation = _refutationFor(line);
    if (refutation.isNotEmpty) {
      (out[moves.length - 1] ??= []).add(
        PgnSideline([moves.last, ...refutation]),
      );
    }
    return out;
  }

  /// What a refuted move costs, as the same `[%...]` token the mainline uses
  /// for everything else — and only when the export carries metrics at all.
  String? _alternativeComment(RefutedAlternative alternative) =>
      config.annotationDetail.emitsMetrics
      ? '[%loss ${(alternative.lossCp / 100).toStringAsFixed(2)}]'
      : null;

  CourseEntry _modelGameEntry(
    ModelGame game,
    ChapterTitle chapter,
    String courseTitle,
  ) {
    final record = game.record;
    final variationName = _modelGameLabel(game);

    return CourseEntry(
      movesSan: record.movesSan,
      chapterName: chapter.name,
      variationName: variationName,
      pgn: writePgnGame(
        PgnGameSpec(
          headers: {
            'Event': courseTitle,
            'White': chapter.name,
            'Black': variationName,
            // A course chapter is study material, not a result-bearing game:
            // "*" is what keeps header-based chapter detection working.  The
            // real game data is preserved under unambiguous ModelGame* tags.
            'Result': '*',
            'Annotator': 'Chess Auto Prep',
            'Opening': variationName,
            kModelGameWhiteTag: record.white,
            kModelGameBlackTag: record.black,
            kModelGameResultTag: record.outcome?.pgnToken ?? '*',
            if (record.event.isNotEmpty) kModelGameEventTag: record.event,
            if (record.date.isNotEmpty) kModelGameDateTag: record.date,
            if (record.whiteElo > 0)
              kModelGameWhiteEloTag: '${record.whiteElo}',
            if (record.blackElo > 0)
              kModelGameBlackEloTag: '${record.blackElo}',
          },
          movesSan: record.movesSan,
          startFen: _modelGameStartFen,
          rootWhiteToMove: isWhiteToMove(_modelGameStartFen),
          startMoveNumber: fullMoveNumber(_modelGameStartFen),
        ),
        detail: MoveAnnotationDetail.none,
      ),
    );
  }

  /// Retained games are scanned from the *build* root, so that is where their
  /// movetext starts — not the repertoire root the lines use.  Numbering has
  /// to follow it too, or a build started mid-game renumbers every model game.
  late final String _modelGameStartFen = config.startFen.isEmpty
      ? kStandardStartFen
      : config.startFen;

  // ── Text helpers ───────────────────────────────────────────────────────

  /// `Kasparov, G – Karpov, A, Linares 1993 (1-0)`.
  String _modelGameLabel(ModelGame game) {
    final record = game.record;
    final occasion = [
      if (record.event.isNotEmpty && record.event != '?') record.event,
      if (record.year != null) '${record.year}',
    ].join(' ');
    final result = record.outcome?.pgnToken;
    return [
      record.playersLabel,
      if (occasion.isNotEmpty) ', $occasion',
      if (result != null) ' ($result)',
    ].join();
  }

  static String _percent(double fraction) =>
      '${(fraction * 100).toStringAsFixed(3)}%';

  static final _indexPrefix = RegExp(r'^\d+\.\s*');

  static String _withoutIndex(String chapterName) =>
      chapterName.replaceFirst(_indexPrefix, '');
}
