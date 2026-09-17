/// Turns repertoire PGN files into trainable [RepertoireLine]s.
///
/// Parsing only: which games are lines, what colour they train, what they
/// are called and which course chapter they belong to. Editing the files
/// those lines came from is [RepertoireFileEditor] (reached through
/// [RepertoireService.files]); chapter detection over header maps is
/// `course_chapter_headers.dart`.
library;

import 'package:chess_auto_prep/chess_core/pgn/repertoire_document_mutation.dart';

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/repertoire_line.dart';
import '../utils/chess_utils.dart';
import '../utils/pgn_comment_utils.dart';
import '../utils/training_markers.dart' show hasPuzzleStart;
import '../chess_core/pgn/course_chapter_headers.dart';
import '../chess_core/pgn/mainline_lexer.dart' as pgn;
import '../chess_core/pgn/pgn_text.dart' as pgn;
import 'repertoire_color_inference.dart';
import 'repertoire_file_editor.dart';
import '../chess_core/pgn/repertoire_line_ids.dart';
import 'storage/storage_factory.dart';
import 'storage/storage_service.dart';
import '../features/training/models/chapter_layout.dart' show ChapterSummary;

/// A game cut from a chapter file and parsed once: the parse tree, the raw
/// text it came from, and its position in the file.
///
/// Both products of a chapter load — the training lines and the opening tree
/// — are built from these, so a game is split and parsed exactly once.
typedef ParsedRepertoireGame = ({
  PgnGame<PgnNodeData> game,
  String text,
  int index,
});

/// The colour a file trains when nothing says otherwise.
const String _kDefaultColor = 'white';

/// Event titles the app writes itself, which say nothing about the line.
const Set<String> _kPlaceholderEvents = {'?', 'Repertoire Line', 'Edited Line'};

/// Hoisted: this ran once per game (or per edit) as a fresh `RegExp`.
final RegExp _cumProbInTextRe = RegExp(r'CumProb\s+([\d.]+)%');

/// How a file's games are titled: whether it is (part of) a course, which
/// header carries the chapter and which the line's own title.
class _ChapterLayout {
  const _ChapterLayout({
    required this.courseChapter,
    required this.chapterKey,
    required this.chapterTitles,
  });

  /// The whole file is one chapter (`// Chapter:` preamble); every line
  /// belongs to it.
  final String? courseChapter;

  /// The header the chapter titles live in, null when none groups the games.
  final String? chapterKey;

  /// One chapter per game, null when the file is not chapter-titled.
  final List<String?>? chapterTitles;

  /// A file that *is* one course chapter skips the search: its lines'
  /// titles repeat enough to look like chapters of their own, and the split
  /// that made it already pinned every line's name into [Event].
  factory _ChapterLayout.of(
    List<Map<String, String>> headersPerGame, {
    required String? courseChapter,
  }) {
    final chapterKey = courseChapter != null
        ? null
        : chapterHeaderKey(headersPerGame);
    return _ChapterLayout(
      courseChapter: courseChapter,
      chapterKey: chapterKey,
      chapterTitles: chapterKey == null
          ? null
          : detectHeaderChapters(headersPerGame, key: chapterKey),
    );
  }

  bool get isCourse => chapterTitles != null || courseChapter != null;

  String get titleKey => titleHeaderKeyFor(chapterKey);

  String? chapterOf(int gameOrdinal) =>
      courseChapter ?? chapterTitles?[gameOrdinal];
}

class RepertoireService {
  RepertoireService({this._storage});

  // Pure text parsing never resolves the legacy default. File callers can
  // supply the same storage owner as their outline/split workflow.
  final StorageService? _storage;

  /// The editor for the files these lines come from.
  RepertoireFileEditor get files => const RepertoireFileEditor();

  // One source per service: revisiting unchanged material avoids rebuilding
  // every move tree. Compare contents, not only mtime, so builder edits and
  // review-header writes are always picked up, even on coarse filesystems.
  ({
    String content,
    String? color,
    bool startingSide,
    bool infer,
    List<RepertoireLine> lines,
  })?
  _lastParse;

  /// Parses a repertoire PGN file and extracts all trainable lines.
  ///
  /// If [trainingColor] is provided ('white' or 'black') it is used directly;
  /// otherwise the colour is read from the file's `// Color:` comment.
  /// [colorFromStartingSide] derives each line's colour from its own start
  /// position instead (study puzzles: the solver is the side to move).
  /// [inferColorWhenUnknown] lets a file with neither read its side off its
  /// own move tree (see [inferTrainingColor]) instead of being assumed White.
  Future<List<RepertoireLine>> parseRepertoireFile(
    String filePath, {
    String? trainingColor,
    bool colorFromStartingSide = false,
    bool inferColorWhenUnknown = false,
  }) async {
    final content = await (_storage ?? StorageFactory.instance)
        .readRepertoirePgn(filePath);

    if (content == null) {
      throw Exception('Repertoire file not found: $filePath');
    }

    final cached = _lastParse;
    if (cached != null &&
        cached.content == content &&
        cached.color == trainingColor &&
        cached.startingSide == colorFromStartingSide &&
        cached.infer == inferColorWhenUnknown) {
      return List.of(cached.lines);
    }

    // The builder path already parses via compute(); the trainer parsed on the
    // UI isolate. A repertoire PGN is hundreds of KB / hundreds of games, each
    // fully replayed — run it off the UI isolate. A fresh (stateless) service
    // inside the isolate avoids capturing `this`.
    final lines = await Isolate.run(
      () => RepertoireService().parseRepertoirePgn(
        content,
        trainingColor: trainingColor,
        colorFromStartingSide: colorFromStartingSide,
        inferColorWhenUnknown: inferColorWhenUnknown,
      ),
    );
    // Cached line values must not share writable maps or move lists with
    // callers. The returned outer list remains freely sortable.
    final frozen = [
      for (final line in lines)
        RepertoireLine(
          id: line.id,
          sourcePath: line.sourcePath,
          sourceLineId: line.sourceLineId,
          name: line.name,
          moves: List.unmodifiable(line.moves),
          color: line.color,
          startPosition: line.startPosition,
          fullPgn: line.fullPgn,
          comments: Map.unmodifiable(line.comments),
          headers: Map.unmodifiable(line.headers),
          importance: line.importance,
          chapter: line.chapter,
          isModelGame: line.isModelGame,
          gameIndex: line.gameIndex,
        ),
    ];
    _lastParse = (
      content: content,
      color: trainingColor,
      startingSide: colorFromStartingSide,
      infer: inferColorWhenUnknown,
      lines: frozen,
    );
    return List.of(frozen);
  }

  /// The course chapters a chapter file carries in its game headers — the
  /// same grouping the trainer shows once the file is open (see
  /// [detectHeaderChapters]) — with the trainable lines each holds, in file
  /// order. Empty when the file is not chapter-titled.
  ///
  /// Headers only: nothing is replayed, so the chapter picker can list a
  /// 3 MB course without paying for a parse. Model games are left out of the
  /// counts because the trainer never drills them.
  Future<List<ChapterSummary>> courseChaptersInFile(String filePath) async {
    final content = await (_storage ?? StorageFactory.instance)
        .readRepertoirePgn(filePath);
    if (content == null || content.trim().isEmpty) return const [];
    return Isolate.run(() => RepertoireService().courseChaptersOf(content));
  }

  /// [courseChaptersInFile] over PGN text already in hand.
  List<ChapterSummary> courseChaptersOf(String content) {
    final headersPerGame = [
      for (final game in pgn.splitPgnIntoGames(content))
        pgn.extractHeaderBlock(game),
    ];
    final titles = detectHeaderChapters(headersPerGame);
    if (titles == null) return const [];
    final counts = <String, int>{};
    for (var i = 0; i < titles.length; i++) {
      final title = titles[i];
      if (title == null) continue;
      final trainable = isModelGameHeaders(headersPerGame[i]) ? 0 : 1;
      counts[title] = (counts[title] ?? 0) + trainable;
    }
    return [
      for (final entry in counts.entries)
        ChapterSummary(name: entry.key, lineCount: entry.value),
    ];
  }

  /// Parses repertoire PGN content and extracts trainable lines.
  ///
  /// [trainingColor] ('white' or 'black') is used when the caller already
  /// knows the side.  Otherwise the colour is read from the `// Color:`
  /// comment that every app-created repertoire file contains.
  /// Falls back to 'white' if neither source provides a colour.
  ///
  /// [colorFromStartingSide] overrides both: each game's colour is the side
  /// to move in its own start position ([FEN] header or standard start).
  /// Used for studies-as-puzzles, where the solver always moves first.
  ///
  /// [inferColorWhenUnknown] applies only when neither source answers — a
  /// third-party course export carries no `// Color:` comment. The side is
  /// then read off the move tree ([inferTrainingColor]) and only falls back
  /// to 'white' when the file's shape says nothing. Off by default so the
  /// callers that only walk moves (deviation checks, outlines) keep parsing
  /// exactly as before.
  List<RepertoireLine> parseRepertoirePgn(
    String pgnContent, {
    String? trainingColor,
    bool colorFromStartingSide = false,
    bool inferColorWhenUnknown = false,
  }) {
    pgnContent = pgn.stripBom(pgnContent);
    final declaredColor =
        trainingColor ?? pgn.extractRepertoireColor(pgnContent);
    return linesFromParsedGames(
      parseGames(pgn.splitPgnIntoGames(pgnContent)),
      declaredColor: declaredColor,
      courseChapter: pgn.extractCourseChapter(pgnContent),
      colorFromStartingSide: colorFromStartingSide,
      inferColorWhenUnknown: inferColorWhenUnknown,
    );
  }

  /// Parse each game text once.  Games that fail to parse are dropped (and
  /// logged in debug builds); [ParsedRepertoireGame.index] keeps every
  /// survivor's position in the original list.
  List<ParsedRepertoireGame> parseGames(List<String> games) {
    final parsed = <ParsedRepertoireGame>[];
    for (var gameIndex = 0; gameIndex < games.length; gameIndex++) {
      try {
        parsed.add((
          game: parsePgnGame(games[gameIndex]),
          text: games[gameIndex],
          index: gameIndex,
        ));
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error parsing game $gameIndex: $e');
        }
      }
    }
    return parsed;
  }

  /// The trainable lines of [parsedGames]; see [parseRepertoirePgn] for the
  /// colour rules.  [declaredColor] is the file's `// Color:` (or the
  /// caller's override), null when the file declares none.
  List<RepertoireLine> linesFromParsedGames(
    List<ParsedRepertoireGame> parsedGames, {
    required String? declaredColor,
    String? courseChapter,
    bool colorFromStartingSide = false,
    bool inferColorWhenUnknown = false,
  }) {
    final resolvedColor = declaredColor ?? _kDefaultColor;

    // Chapter titles are a whole-file property (does one of the player
    // headers group the games?), so games are parsed before any line is
    // built.
    final layout = _ChapterLayout.of([
      for (final p in parsedGames) p.game.headers,
    ], courseChapter: courseChapter);

    final lines = <RepertoireLine>[];
    for (var i = 0; i < parsedGames.length; i++) {
      final parsed = parsedGames[i];
      try {
        final line = _lineFromGame(
          parsed,
          layout: layout,
          chapter: layout.chapterOf(i),
          fileColor: resolvedColor,
          colorFromStartingSide: colorFromStartingSide,
        );
        if (line != null) lines.add(line);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error parsing game ${parsed.index}: $e');
        }
      }
    }

    final unique = _withUniqueIds(lines);

    // The colour is a whole-file property, so it can only be read off the
    // finished move tree — hence a second pass rather than a decision made
    // while each game is built.
    if (inferColorWhenUnknown &&
        declaredColor == null &&
        !colorFromStartingSide) {
      final inferred = inferTrainingColor(unique);
      if (inferred != null && inferred.colorName != resolvedColor) {
        return [
          for (final line in unique) line.copyWithColor(inferred.colorName),
        ];
      }
    }
    return unique;
  }

  /// One parsed game as a line, or null when it has no moves.
  RepertoireLine? _lineFromGame(
    ParsedRepertoireGame parsed, {
    required _ChapterLayout layout,
    required String? chapter,
    required String fileColor,
    required bool colorFromStartingSide,
  }) {
    final game = parsed.game;
    // One walk of the mainline serves the moves, the comments and the
    // puzzle marker; it used to be walked three times.
    final moveNodes = game.moves.mainline().toList(growable: false);
    if (moveNodes.isEmpty) return null;
    final mainlineMoves = [for (final node in moveNodes) node.san];
    final startPosition = extractStartPosition(game);

    final comments = <String, String>{};
    int? markerIndex;
    for (var i = 0; i < moveNodes.length; i++) {
      final nodeComments = moveNodes[i].comments;
      if (nodeComments == null || nodeComments.isEmpty) continue;
      final comment = nodeComments.join(' ').trim();
      if (comment.isEmpty) continue;
      comments[i.toString()] = comment;
      // A `[%tstart]` puzzle marker names the first move the solver
      // must find, so in per-chapter colour mode the solver is whoever
      // plays that move — not whoever moves first in the chapter. That
      // lets a full game saved from the standard start train as a
      // Black puzzle.
      if (markerIndex == null && hasPuzzleStart(comment)) markerIndex = i;
    }

    final startIsWhite = startPosition.turn == Side.white;
    final markerMoverIsWhite = markerIndex == null
        ? startIsWhite
        : (markerIndex.isEven ? startIsWhite : !startIsWhite);
    final color = colorFromStartingSide
        ? (markerMoverIsWhite ? 'white' : 'black')
        : fileColor;

    return RepertoireLine(
      id: repertoireLineIds.fromHeaders(
        game.headers,
        mainlineMoves,
        parsed.index,
      ),
      name: _lineName(game, mainlineMoves, parsed.index, layout: layout),
      moves: mainlineMoves,
      color: color,
      startPosition: startPosition,
      fullPgn: parsed.text,
      comments: comments,
      // The parse tree is discarded after this, so its header map is
      // ours to keep; copying it once per game bought nothing.
      headers: game.headers,
      importance: _extractImportance(game, parsed.text),
      chapter: chapter,
      isModelGame: _isModelGame(game.headers, layout: layout, chapter: chapter),
      gameIndex: parsed.index,
    );
  }

  /// Whether a game is illustration rather than a line to drill.
  ///
  /// In a chapter-titled export every repertoire line carries
  /// [Result "*"]; a game with a real result is a complete game the
  /// author included as illustration. Drilling forty moves of
  /// Bertok-Fischer is not training your repertoire, so it is marked
  /// the same way this app marks its own model games.
  static bool _isModelGame(
    Map<String, String> headers, {
    required _ChapterLayout layout,
    required String? chapter,
  }) =>
      isModelGameHeaders(headers) ||
      (layout.isCourse &&
          ((headers['Result'] ?? '*').trim() != '*' ||
              isModelGamesChapterTitle(chapter ?? '')));

  /// Chapter-titled games (Chessable exports) name the variation in the
  /// player header the chapter is not in; everything else keeps the
  /// Opening/Event naming.
  static String _lineName(
    PgnGame game,
    List<String> mainline,
    int index, {
    required _ChapterLayout layout,
  }) {
    var variationTitle = (game.headers[layout.titleKey] ?? '').trim();
    // With the chapter in [Event] the title spans both player headers:
    // the variation in [White], a sub-variation in [Black] when there
    // is one ("Fianchetto 9.Nd2 e6 — 10.Rb1 #11").
    if (layout.chapterKey == 'Event') {
      final sub = (game.headers['Black'] ?? '').trim();
      if (variationTitle.isNotEmpty &&
          !kIgnoredChapterTitles.contains(sub.toLowerCase())) {
        variationTitle = '$variationTitle — $sub';
      }
    }
    return layout.chapterTitles != null &&
            variationTitle.isNotEmpty &&
            variationTitle != '?'
        ? variationTitle
        : _generateLineName(game, mainline, index);
  }

  /// Guarantees every line in a file has a distinct id.
  ///
  /// The move-based fallback id ([RepertoireLineIds.stable]) is a truncated
  /// base64 of the moves, so two lines sharing a long opening prefix — the
  /// normal case in a repertoire — get the *same* id. Training progress is
  /// keyed by these ids and the file editors used to look games up by them,
  /// so a collision silently mixed two lines' histories and let a delete or
  /// rename land on the wrong game.
  ///
  /// The first line to claim an id keeps it, so ids that already exist in
  /// saved progress stay valid; every later collision is re-derived from a
  /// full hash of its moves and file position, which does not truncate.
  /// [lineIdsForGames] applies the same rule when editing a file, so the
  /// two always agree.
  List<RepertoireLine> _withUniqueIds(List<RepertoireLine> lines) {
    final seen = <String>{};
    var changed = false;
    final out = <RepertoireLine>[];
    for (final line in lines) {
      if (seen.add(line.id)) {
        out.add(line);
        continue;
      }
      changed = true;
      out.add(
        line.copyWithId(
          repertoireLineIds.resolveCollision(line.moves, line.gameIndex, seen),
        ),
      );
    }
    return changed ? out : lines;
  }

  Position extractStartPositionFromPgn(String pgnText) {
    try {
      return extractStartPosition(parsePgnGame(pgnText));
    } catch (_) {
      // Unparsable text has no start of its own.
      return Chess.initial;
    }
  }

  Position extractStartPosition(PgnGame game) {
    final fen = game.headers['FEN']?.trim();
    if (fen == null || fen.isEmpty) return Chess.initial;
    return tryParseFen(fen) ?? Chess.initial;
  }

  /// Extract cumulative line probability (0–1) from PGN headers or comments.
  static double? _extractImportance(PgnGame game, String gameText) {
    for (final key in const ['CumProb', 'Importance']) {
      final header = game.headers[key];
      if (header == null || header.isEmpty) continue;
      final parsed = _parseCumulativeProbPgnValue(header);
      if (parsed != null) return parsed;
    }

    // Two regex passes over the whole game text, per game, per load — only
    // worth running when the marker is actually there, which a plain
    // substring scan settles far faster than a regex.
    if (gameText.contains('CumProb')) {
      final cumProbMatch = _cumProbInTextRe.firstMatch(gameText);
      if (cumProbMatch != null) {
        final pct = double.tryParse(cumProbMatch.group(1)!);
        if (pct != null) return pct / 100.0;
      }
    }
    if (!gameText.contains('[%')) return null;
    return parseImportanceComment(gameText);
  }

  /// Parse `[CumProb "12.529%"]` or legacy `[Importance "0.125"]` header values.
  static double? _parseCumulativeProbPgnValue(String raw) {
    final trimmed = raw.trim();
    if (trimmed.endsWith('%')) {
      final pct = double.tryParse(trimmed.substring(0, trimmed.length - 1));
      if (pct != null) return pct / 100.0;
    }
    final parsed = double.tryParse(trimmed);
    if (parsed == null) return null;
    if (parsed <= 1.0) return parsed;
    return parsed / 100.0;
  }

  /// Generates a meaningful name for the repertoire line.
  static String _generateLineName(
    PgnGame game,
    List<String> mainline,
    int index,
  ) {
    final event = game.headers['Event'] ?? '';
    final opening = game.headers['Opening'] ?? '';
    // A study chapter (Lichess export or a study written here) says its own
    // name; its Event is "Study: Chapter", which would repeat the study on
    // every line.
    final chapterName = game.headers['ChapterName']?.trim() ?? '';

    if (chapterName.isNotEmpty) return chapterName;
    if (opening.isNotEmpty && opening != '?') return opening;
    if (event.isNotEmpty && !_kPlaceholderEvents.contains(event)) return event;
    if (mainline.isNotEmpty) return 'Line: ${mainline.take(3).join(' ')}';
    return 'Repertoire Line ${index + 1}';
  }

  /// The line id the trainer will assign to the [index]-th game of [pgnText].
  ///
  /// Lives here rather than on [RepertoireLineIds] because it has to *parse*
  /// first, and it parses through the same pipeline as the trainer so the
  /// two agree regardless of how the source serialized its headers. Returns
  /// null when [pgnText] does not parse.
  String? lineIdForGamePgn(String pgnText, int index) {
    final moves = pgn.mainlineSansOf(pgnText);
    if (moves.isEmpty) return null;
    return repertoireLineIds.fromHeaders(
      pgn.extractHeaderBlock(pgnText),
      moves,
      index,
    );
  }
}
