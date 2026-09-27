/// Assembling planned chapters, named variations, and model games into the
/// PGN games that get written to disk.
///
/// Chapters are encoded the way published course exports do it — `[White]`
/// names the chapter, `[Black]` names the variation, and `[Result]` stays
/// `*` — which is the format `RepertoireService.detectHeaderChapters` already
/// reads.  Every line therefore remains its own game, so training, browsing
/// and line-level statistics are unchanged; only the grouping is new.
library;

import '../../../utils/fen_utils.dart';
import '../export/move_annotation.dart';
import '../export/pgn_game_writer.dart';
import '../generation_config.dart';
import '../engine_tail.dart';
import '../line_extractor.dart';
import '../line_pruner.dart';
import 'chapter_planner.dart';
import 'chapter_titles.dart';
import 'model_game_selector.dart';
import 'model_game_writer.dart';
import 'master_improvements.dart';
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

/// The finished course: every entry in file order plus its chapter outline.
class ComposedCourse {
  final String title;
  final List<CourseEntry> entries;
  final List<ChapterOutline> outline;

  /// The model games again, as *games*: real `White`/`Black`/`Result`
  /// headers and the same annotated movetext, for a companion
  /// run-local `model_games.pgn` a PGN viewer opens as a game collection.
  /// Inside the course they travel as a chapter with study headers (see
  /// [ModelGameWriter.chapterPgn]); this is the other shape.
  final List<String> modelGamePgns;

  const ComposedCourse({
    required this.title,
    required this.entries,
    required this.outline,
    this.modelGamePgns = const [],
  });

  String modelGamesPgn() => modelGamePgns.join('\n');

  int get lineChapterCount =>
      outline.where((c) => c.kind == ChapterKind.lines).length;

  int get modelGameCount => outline
      .where((c) => c.kind == ChapterKind.modelGames)
      .fold(0, (sum, c) => sum + c.entryCount);

  String toPgn() => entries.map((e) => e.pgn).join('\n');
}

// ── Composer ─────────────────────────────────────────────────────────────

/// What the post-build passes found, gathered for one [CourseComposer.compose]
/// call so the entry writers read from one immutable value instead of
/// composer fields that change between calls.
class _Enrichments {
  const _Enrichments({
    required this.refutations,
    required this.alternatives,
    required this.engineTails,
    required this.improvements,
    required this.folds,
  });

  /// Punishing continuations for lines that end on a losing reply, keyed by
  /// the position they start from.
  final RefutationMap refutations;

  /// Refuted moves the book leaves out, keyed by the position they are
  /// played in.
  final AlternativeMap alternatives;

  /// Engine continuations for lines cut at the ply cap, keyed by leaf FEN.
  final Map<String, EngineTail> engineTails;

  /// Where the repertoire improves on master practice, keyed by the position
  /// the improvement is played in.
  final ImprovementMap improvements;

  /// Lines too close to a kept line to earn an entry, keyed by the entry
  /// they hang off.
  final Map<String, List<FoldedLine>> folds;
}

/// Turns extracted lines and their enrichments into a [ComposedCourse].
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

  ComposedCourse compose({
    required List<ExtractedLine> lines,
    Map<String, List<FoldedLine>> folds = const {},
    List<ModelGame> modelGames = const [],
    RefutationMap refutations = const {},
    AlternativeMap alternatives = const {},
    Map<String, EngineTail> engineTails = const {},
    ImprovementMap improvements = const {},
  }) {
    final enrichments = _Enrichments(
      refutations: refutations,
      alternatives: alternatives,
      engineTails: engineTails,
      improvements: improvements,
      folds: folds,
    );
    final title = namer.courseTitle(fallback: repertoireName);
    final groups = _planChapters(lines);
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
            line: group.lines[i],
            chapter: chapter,
            variationName: variationNames[i],
            courseTitle: title,
            enrichments: enrichments,
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

    final modelGamePgns = <String>[];
    if (modelGames.isNotEmpty) {
      final chapterName = '${groups.length + 1}. Model games';
      final writer = ModelGameWriter(
        config: config,
        improvements: improvements,
      );
      for (final game in modelGames) {
        final variationName = writer.label(game);
        entries.add(
          CourseEntry(
            // "from the repertoire's start position", like every other
            // entry — the plies before the build root belong to the root,
            // not the entry.
            movesSan: game.movesFromRoot,
            chapterName: chapterName,
            variationName: variationName,
            pgn: writer.chapterPgn(
              game,
              courseTitle: title,
              chapterName: chapterName,
              variationName: variationName,
            ),
          ),
        );
        modelGamePgns.add(writer.standalonePgn(game, courseTitle: title));
      }
      outline.add(
        ChapterOutline(
          name: chapterName,
          entryCount: modelGames.length,
          kind: ChapterKind.modelGames,
        ),
      );
    }

    return ComposedCourse(
      title: title,
      entries: entries,
      outline: outline,
      modelGamePgns: modelGamePgns,
    );
  }

  /// Cut [lines] into chapters, or keep them as one flat group when the
  /// config asks for no chapters.
  List<ChapterGroup> _planChapters(List<ExtractedLine> lines) {
    if (!config.organizeIntoChapters) {
      return [ChapterGroup(prefixSan: const [], lines: lines)];
    }
    return ChapterPlanner(
      maxLines: config.maxLinesPerChapter,
      minLines: config.minLinesPerChapter,
      // Chapter prefixes are relative to the build root; the ECO book is
      // keyed from the repertoire file's start position, so the lookup needs
      // both halves of the path.
      ecoOf: config.chaptersByEco
          ? (movesSan) => namer.namer.label([...repertoirePrefix, ...movesSan])
          : null,
    ).plan(lines);
  }

  // ── Entries ────────────────────────────────────────────────────────────

  CourseEntry _lineEntry({
    required ExtractedLine line,
    required ChapterTitle chapter,
    required String variationName,
    required String courseTitle,
    required _Enrichments enrichments,
  }) {
    // The prepared part of the line — what selection and expectimax vouch
    // for. Sidelines index into this, so it has to be computed before the
    // engine tail extends the movetext past it.
    final prepared = [...repertoirePrefix, ...line.movesSan];
    final tail = _engineTailFor(line, enrichments);
    final moves = [...prepared, if (tail != null) ...tail.movesSan];
    final alternatives = _alternativesFor(line, enrichments);
    final improvements = improvementsAlong(line, enrichments.improvements);
    final refutation = _refutationFor(line, enrichments);
    final eco = chapter.eco;

    return CourseEntry(
      refutation: refutation,
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
            'ECO': ?eco,
            // Read back by RepertoireService as the line's importance.
            if (config.rankLinesByImportance)
              'CumProb': _percent(line.probability),
            // Belt and braces: when a course has only one chapter the header
            // grouping is not detected, and the line name falls back to
            // [Opening].
            'Opening': variationName,
          },
          movesSan: moves,
          annotations: [
            // Padded to the prepared move count first: annotations may be
            // shorter than the moves they describe, and appending the tail's
            // onto a short list would slide its note onto an earlier move.
            ..._padded(
              annotationsWithImprovements(line, improvements),
              line.movesSan.length,
            ),
            if (tail != null) ..._tailAnnotations(tail),
          ],
          annotationOffset: repertoirePrefix.length,
          startFen: repertoireStartFen,
          rootWhiteToMove: isWhiteToMove(repertoireStartFen),
          startMoveNumber: namer.startMoveNumber,
          variations: _sidelines(
            prepared,
            line,
            alternatives: alternatives,
            improvements: improvements,
            refutation: refutation,
            folds: enrichments.folds,
          ),
        ),
        detail: config.annotationDetail,
      ),
    );
  }

  /// The engine continuation past this line's cut-off, or null when the
  /// engine had nothing to add or the line ends by transposing elsewhere.
  static EngineTail? _engineTailFor(
    ExtractedLine line,
    _Enrichments enrichments,
  ) {
    final fen = line.leafFen;
    if (fen == null || line.isTransposition) return null;
    return enrichments.engineTails[fen];
  }

  /// The engine's punishment of the reply this line ends on, or empty.
  static List<String> _refutationFor(
    ExtractedLine line,
    _Enrichments enrichments,
  ) {
    final fen = line.leafFen;
    if (fen == null) return const [];
    return enrichments.refutations[fen] ?? const [];
  }

  /// Refuted alternatives along [line], keyed by the index of the move they
  /// replace.  A position is only asked about once per line even when the
  /// line returns to it.
  static Map<int, RefutedAlternative> _alternativesFor(
    ExtractedLine line,
    _Enrichments enrichments,
  ) {
    final out = <int, RefutedAlternative>{};
    for (final choice in line.choices) {
      final found = enrichments.alternatives[choice.fenBefore];
      if (found != null) out[choice.moveIndex] = found;
    }
    return out;
  }

  /// Every sideline this line carries, keyed by the mainline move it hangs
  /// off: what the moves we skipped run into, the master move we improve on,
  /// and — last, so the line reads forwards — how the reply it ends on is
  /// punished.
  ///
  /// The punishment repeats the move it hangs off, which is how PGN writes a
  /// continuation rather than an alternative: the reader clicks the move and
  /// walks into what it runs into.  The mainline still ends where the
  /// repertoire ends, so nothing here becomes trainable.
  Map<int, List<PgnSideline>> _sidelines(
    List<String> moves,
    ExtractedLine line, {
    required Map<int, RefutedAlternative> alternatives,
    required Map<int, MasterImprovement> improvements,
    required List<String> refutation,
    required Map<String, List<FoldedLine>> folds,
  }) {
    if (moves.isEmpty) return const {};
    final out = <int, List<PgnSideline>>{};

    // The master move we improve on, with how the cited game went on from
    // it — clickable evidence for the note on our move.
    for (final entry in improvements.entries) {
      final index = repertoirePrefix.length + entry.key;
      if (index >= moves.length) continue;
      final imp = entry.value;
      (out[index] ??= []).add(
        PgnSideline([
          imp.masterSan,
          ...imp.continuation,
        ], comment: imp.sidelineComment),
      );
    }

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

    for (final entry in _foldedSidelines(line, moves.length, folds).entries) {
      (out[entry.key] ??= []).addAll(entry.value);
    }

    if (refutation.isNotEmpty) {
      (out[moves.length - 1] ??= []).add(
        PgnSideline([moves.last, ...refutation]),
      );
    }

    return out;
  }

  /// The lines folded into [line], written as variations off the move where
  /// each one parts from it.
  ///
  /// Two shapes, and the difference is not cosmetic — PGN reads a variation
  /// as *instead of* the move it hangs off:
  ///
  /// - The usual case, the fold leaves mid-line: the variation starts with
  ///   the folded line's own move at that ply, so it reads "instead …".
  /// - The fold runs past the end of its host: there is no move to replace,
  ///   so the variation repeats the host's last move and continues from it,
  ///   the same trick [_sidelines] uses for a refutation.
  ///
  /// Only the first [moveCount] plies (the prepared ones) are addressable. A
  /// fold cannot land on the engine tail — it is indexed against the host's
  /// own moves — but the bound is checked rather than assumed, because an
  /// out-of-range key would silently attach the sideline to the wrong move.
  Map<int, List<PgnSideline>> _foldedSidelines(
    ExtractedLine line,
    int moveCount,
    Map<String, List<FoldedLine>> folds,
  ) {
    final folded = folds[LinePruner.lineKey(line.movesSan)];
    if (folded == null || folded.isEmpty) return const {};

    final out = <int, List<PgnSideline>>{};
    for (final fold in folded) {
      final ply = fold.divergePly;
      final moves = fold.line.movesSan;
      if (ply <= 0 || ply >= moves.length) continue;

      final int index;
      final List<String> sidelineMoves;
      if (ply < line.movesSan.length) {
        index = repertoirePrefix.length + ply;
        sidelineMoves = moves.sublist(ply);
      } else {
        // The fold continues the host rather than diverging from it.
        index = repertoirePrefix.length + line.movesSan.length - 1;
        sidelineMoves = [line.movesSan.last, ...moves.sublist(ply)];
      }
      if (index < 0 || index >= moveCount) continue;
      (out[index] ??= []).add(
        PgnSideline(sidelineMoves, comment: _foldComment(fold)),
      );
    }
    return out;
  }

  /// Why a folded line is a note rather than an entry.
  ///
  /// It says "not drilled" because that is the one thing the reader cannot
  /// see from the movetext: everything here is real preparation, it is just
  /// too close to the mainline above to be worth quizzing separately.
  String? _foldComment(FoldedLine fold) {
    if (!config.annotationDetail.explanations) return null;
    const base = 'Same idea as the mainline';
    // A reach that rounds to 0.0% says nothing; "rare" is the honest reading
    // of it, and a third decimal place would only look precise.
    final percent = fold.line.probability * 100;
    if (percent < 0.05) return '$base — rare, read not drilled';
    return '$base — ${percent.toStringAsFixed(1)}% of games, read not drilled';
  }

  /// [annotations] grown to [length] with empty entries, so anything appended
  /// after it lines up with the move it belongs to.
  static List<MoveAnnotation> _padded(
    List<MoveAnnotation> annotations,
    int length,
  ) => annotations.length >= length
      ? annotations
      : [
          ...annotations,
          for (var i = annotations.length; i < length; i++) MoveAnnotation.none,
        ];

  /// Annotations for the engine continuation: a note on the first move
  /// saying where preparation stopped, then nothing. The moves themselves are
  /// part of the line — they get trained like any other — but the reader (and
  /// anyone reviewing the file later) should be able to see which of them the
  /// build actually vouched for.
  static List<MoveAnnotation> _tailAnnotations(EngineTail tail) => [
    MoveAnnotation(
      note:
          'Engine continuation from here at depth ${tail.depth} — best play, '
          'not prepared theory',
    ),
    for (var i = 1; i < tail.movesSan.length; i++) MoveAnnotation.none,
  ];

  /// What a refuted move costs, as the same `[%...]` token the mainline uses
  /// for everything else — and only when the export carries metrics at all.
  String? _alternativeComment(RefutedAlternative alternative) =>
      config.annotationDetail.emitsMetrics
      ? '[%loss ${(alternative.lossCp / 100).toStringAsFixed(2)}]'
      : null;

  // ── Text helpers ───────────────────────────────────────────────────────

  static String _percent(double fraction) =>
      '${(fraction * 100).toStringAsFixed(3)}%';

  static final _indexPrefix = RegExp(r'^\d+\.\s*');

  static String _withoutIndex(String chapterName) =>
      chapterName.replaceFirst(_indexPrefix, '');
}
