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
import '../engine_tail.dart';
import '../line_extractor.dart';
import '../line_pruner.dart';
import 'chapter_planner.dart';
import 'chapter_titles.dart';
import 'model_game_selector.dart';
import 'master_improvements.dart';
import 'opening_namer.dart' show formatMoveReference;
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

  /// The model games again, as *games*: real `White`/`Black`/`Result`
  /// headers and the same annotated movetext, for a companion
  /// `<title>_model_games.pgn` a PGN viewer opens as a game collection.
  /// Inside the course they travel as a chapter with study headers (see
  /// [CourseComposer._modelGameEntry]); this is the other shape.
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
  Map<String, EngineTail> _engineTails = const {};

  /// Refuted moves the book leaves out, keyed by the position they are played
  /// in.  Set for the duration of [compose].
  AlternativeMap _alternatives = const {};

  /// Where the repertoire improves on master practice, keyed by the position
  /// the improvement is played in.  Set for the duration of [compose].
  ImprovementMap _improvements = const {};

  /// Lines too close to a kept line to earn an entry, keyed by the entry
  /// they hang off.  Set for the duration of [compose].
  Map<String, List<FoldedLine>> _folds = const {};

  ComposedCourse compose({
    required List<ExtractedLine> lines,
    Map<String, List<FoldedLine>> folds = const {},
    List<ModelGame> modelGames = const [],
    RefutationMap refutations = const {},
    AlternativeMap alternatives = const {},
    Map<String, EngineTail> engineTails = const {},
    ImprovementMap improvements = const {},
  }) {
    _refutations = refutations;
    _folds = folds;
    _alternatives = alternatives;
    _engineTails = engineTails;
    _improvements = improvements;
    final title = namer.courseTitle(fallback: repertoireName);
    final groups = config.organizeIntoChapters
        ? ChapterPlanner(
            maxLines: config.maxLinesPerChapter,
            minLines: config.minLinesPerChapter,
            // Chapter prefixes are relative to the build root; the ECO book
            // is keyed from the repertoire file's start position, so the
            // lookup needs both halves of the path.
            ecoOf: config.chaptersByEco
                ? (movesSan) =>
                      namer.namer.label([...repertoirePrefix, ...movesSan])
                : null,
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

    final modelGamePgns = <String>[];
    if (modelGames.isNotEmpty) {
      final chapter = ChapterTitle(
        index: groups.length + 1,
        name: '${groups.length + 1}. Model games',
        kind: ChapterKind.modelGames,
      );
      for (final game in modelGames) {
        entries.add(_modelGameEntry(game, chapter, title));
        modelGamePgns.add(_modelGameStandalonePgn(game, title));
      }
      outline.add(
        ChapterOutline(
          name: chapter.name,
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

  // ── Entries ────────────────────────────────────────────────────────────

  CourseEntry _lineEntry({
    required ChapterGroup group,
    required int lineIndex,
    required ChapterTitle chapter,
    required String variationName,
    required String courseTitle,
  }) {
    final line = group.lines[lineIndex];
    // The prepared part of the line — what selection and expectimax vouch
    // for. Sidelines index into this, so it has to be computed before the
    // engine tail extends the movetext past it.
    final prepared = [...repertoirePrefix, ...line.movesSan];
    final tail = line.leafFen == null || line.isTransposition
        ? null
        : _engineTails[line.leafFen!];
    final moves = [...prepared, if (tail != null) ...tail.movesSan];
    final alternatives = _alternativesFor(line);
    final improvements = _improvementsFor(line);

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
          variations: _sidelines(prepared, line, alternatives, improvements),
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

  /// Improvements on master practice along [line], keyed by the index of our
  /// move that improves.  Shared with the snapshot export.
  Map<int, MasterImprovement> _improvementsFor(ExtractedLine line) =>
      improvementsAlong(line, _improvements);

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
    ExtractedLine line,
    Map<int, RefutedAlternative> alternatives,
    Map<int, MasterImprovement> improvements,
  ) {
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

    for (final entry in _foldedSidelines(line, moves.length).entries) {
      (out[entry.key] ??= []).addAll(entry.value);
    }

    final refutation = _refutationFor(line);
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
  /// Only [prepared] plies are addressable. A fold cannot land on the engine
  /// tail — it is indexed against the host's own moves — but the bound is
  /// checked rather than assumed, because an out-of-range key would silently
  /// attach the sideline to the wrong move.
  Map<int, List<PgnSideline>> _foldedSidelines(
    ExtractedLine line,
    int moveCount,
  ) {
    final folded = _folds[LinePruner.lineKey(line.movesSan)];
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
    if (!config.annotationDetail.emitsAnything) return null;
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
  List<MoveAnnotation> _tailAnnotations(EngineTail tail) => [
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

  CourseEntry _modelGameEntry(
    ModelGame game,
    ChapterTitle chapter,
    String courseTitle,
  ) {
    final record = game.record;
    final variationName = _modelGameLabel(game);

    return CourseEntry(
      // "from the repertoire's start position", like every other entry —
      // the plies before the build root belong to the root, not the entry.
      movesSan: game.movesFromRoot,
      chapterName: chapter.name,
      variationName: variationName,
      pgn: _writeModelGame(game, {
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
        if (record.whiteElo > 0) kModelGameWhiteEloTag: '${record.whiteElo}',
        if (record.blackElo > 0) kModelGameBlackEloTag: '${record.blackElo}',
      }, result: '*'),
    );
  }

  /// The same game as a real game record for the companion file.
  String _modelGameStandalonePgn(ModelGame game, String courseTitle) {
    final record = game.record;
    final result = record.outcome?.pgnToken ?? '*';
    return _writeModelGame(game, {
      'Event': record.event.isEmpty ? '?' : record.event,
      'Site': '?',
      'Date': record.date.isEmpty ? '????.??.??' : record.date,
      'Round': '?',
      'White': record.white,
      'Black': record.black,
      'Result': result,
      if (record.whiteElo > 0) 'WhiteElo': '${record.whiteElo}',
      if (record.blackElo > 0) 'BlackElo': '${record.blackElo}',
      'Annotator': 'Chess Auto Prep',
      'Repertoire': courseTitle,
    }, result: result);
  }

  /// Movetext shared by both shapes of a model game: the game's moves, and
  /// at the move where it leaves the repertoire, what the repertoire does
  /// instead — a comment ("Our repertoire: 10...Qb6 — improves on 10...Nf6
  /// (+0.35)") and our mainline as a variation off that move, or, when the
  /// opponent left first, the replies we prepare.
  String _writeModelGame(
    ModelGame game,
    Map<String, String> headers, {
    required String result,
  }) {
    final startFen = _modelGameStartFen;
    final rootWhiteToMove = isWhiteToMove(startFen);
    final startMoveNumber = fullMoveNumber(startFen);
    // The movetext has to start where [startFen] does.  A build rooted
    // mid-opening writes its model games from that root, so the plies the
    // game spent reaching it are already on the board and must not be
    // written again — `1. d4` under a Benko FEN header is not a legal game.
    final movesSan = game.movesFromRoot;

    final annotations = <MoveAnnotation>[];
    final variations = <int, List<PgnSideline>>{};
    final d = game.departure;
    if (d != null && d.index < movesSan.length) {
      final note = _departureNote(
        d,
        rootWhiteToMove: rootWhiteToMove,
        startMoveNumber: startMoveNumber,
      );
      if (note != null) {
        annotations.addAll(
          List.filled(d.index, const MoveAnnotation(), growable: true),
        );
        annotations.add(MoveAnnotation(note: note));
      }
      if (d.kind == DepartureKind.ours && d.repertoireLine.isNotEmpty) {
        variations[d.index] = [PgnSideline(d.repertoireLine)];
      }
    }

    return writePgnGame(
      PgnGameSpec(
        headers: headers,
        movesSan: movesSan,
        annotations: annotations,
        variations: variations,
        startFen: startFen,
        rootWhiteToMove: rootWhiteToMove,
        startMoveNumber: startMoveNumber,
        result: result,
      ),
      // `likelihood` rather than `none`: it writes notes and nothing else
      // here (model games carry no metrics), and `none` would drop the note.
      detail: MoveAnnotationDetail.likelihood,
    );
  }

  String? _departureNote(
    ModelGameDeparture d, {
    required bool rootWhiteToMove,
    required int startMoveNumber,
  }) {
    String ref(String san) => formatMoveReference(
      san,
      d.index,
      rootWhiteToMove: rootWhiteToMove,
      startMoveNumber: startMoveNumber,
    );
    switch (d.kind) {
      case DepartureKind.ours:
        final ours = d.repertoireSan;
        if (ours == null) return null;
        final improvement = _improvements[d.fenBefore];
        final improves =
            improvement != null &&
            improvement.ourSan == ours &&
            improvement.masterSan == d.gameSan;
        final b = StringBuffer('Our repertoire: ${ref(ours)}');
        if (improves) {
          final pawns = (improvement.gainCp / 100).toStringAsFixed(2);
          b.write(' — improves on ${ref(d.gameSan)} (+$pawns)');
        }
        return b.toString();
      case DepartureKind.opponent:
        if (d.preparedReplies.isEmpty) return null;
        final prepared = d.preparedReplies.map(ref).join(', ');
        return 'Outside the repertoire — prepared here: $prepared';
    }
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
