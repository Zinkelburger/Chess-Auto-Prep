/// Repertoire parsing and training service
/// Extracts trainable lines from PGN files and manages training sessions
library;

import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import '../models/repertoire_line.dart';
import '../models/repertoire_review_entry.dart' show RepertoireReviewEntry;
import '../utils/atomic_file.dart';
import '../utils/file_text_reader.dart';
import '../utils/pgn_comment_utils.dart';
import '../utils/training_markers.dart' show hasPuzzleStart;
import 'pgn_parsing_service.dart' as pgn;
import 'repertoire_color_inference.dart';
import 'repertoire_line_ids.dart';
import 'repertoire_pgn_text.dart';
import 'storage/storage_factory.dart';
import '../utils/chess_utils.dart';

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

// Hoisted: these ran once per game (or per edit) as fresh `RegExp`s.
final RegExp _cumProbInTextRe = RegExp(r'CumProb\s+([\d.]+)%');

class RepertoireService {
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
    final content = await StorageFactory.instance.readRepertoirePgn(filePath);

    if (content == null) {
      throw Exception('Repertoire file not found: $filePath');
    }

    // The builder path already parses via compute(); the trainer parsed on the
    // UI isolate. A repertoire PGN is hundreds of KB / hundreds of games, each
    // fully replayed — run it off the UI isolate. A fresh (stateless) service
    // inside the isolate avoids capturing `this`.
    return Isolate.run(
      () => RepertoireService().parseRepertoirePgn(
        content,
        trainingColor: trainingColor,
        colorFromStartingSide: colorFromStartingSide,
        inferColorWhenUnknown: inferColorWhenUnknown,
      ),
    );
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
      colorFromStartingSide: colorFromStartingSide,
      inferColorWhenUnknown: inferColorWhenUnknown,
    );
  }

  /// Parse each game text once.  Games that fail to parse are dropped (and
  /// logged in debug builds); [ParsedRepertoireGame.index] keeps every
  /// survivor's position in the original list.
  List<ParsedRepertoireGame> parseGames(List<String> games) {
    final parsed = <ParsedRepertoireGame>[];
    for (int gameIndex = 0; gameIndex < games.length; gameIndex++) {
      try {
        parsed.add((
          game: PgnGame.parsePgn(games[gameIndex]),
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
    bool colorFromStartingSide = false,
    bool inferColorWhenUnknown = false,
  }) {
    final lines = <RepertoireLine>[];
    final resolvedColor = declaredColor ?? 'white';

    // Chapter titles are a whole-file property (do the [White] headers group
    // the games?), so games are parsed before any line is built.
    final chapterTitles = detectHeaderChapters([
      for (final p in parsedGames) p.game.headers,
    ]);

    for (int i = 0; i < parsedGames.length; i++) {
      final game = parsedGames[i].game;
      final gameText = parsedGames[i].text;
      final gameIndex = parsedGames[i].index;
      final chapter = chapterTitles?[i];

      try {
        // One walk of the mainline serves the moves, the comments and the
        // puzzle marker; it used to be walked three times.
        final moveNodes = game.moves.mainline().toList(growable: false);
        if (moveNodes.isEmpty) continue;
        final mainlineMoves = [for (final node in moveNodes) node.san];

        final startPosition = extractStartPosition(game);

        final comments = <String, String>{};
        int? markerIndex;
        for (int i = 0; i < moveNodes.length; i++) {
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
            : resolvedColor;

        // Chapter-titled games (Chessable exports) name the variation in the
        // [Black] header; everything else keeps the Opening/Event naming.
        final variationTitle = (game.headers['Black'] ?? '').trim();
        final lineName =
            chapter != null &&
                variationTitle.isNotEmpty &&
                variationTitle != '?'
            ? variationTitle
            : _generateLineName(game, mainlineMoves, gameIndex);
        final lineId = _extractLineId(game, mainlineMoves, gameIndex);
        final importance = _extractImportance(game, gameText);

        lines.add(
          RepertoireLine(
            id: lineId,
            name: lineName,
            moves: mainlineMoves,
            color: color,
            startPosition: startPosition,
            fullPgn: gameText,
            comments: comments,
            // The parse tree is discarded after this, so its header map is
            // ours to keep; copying it once per game bought nothing.
            headers: game.headers,
            importance: importance,
            chapter: chapter,
            // In a chapter-titled export every repertoire line carries
            // [Result "*"]; a game with a real result is a complete game the
            // author included as illustration. Drilling forty moves of
            // Bertok-Fischer is not training your repertoire, so it is marked
            // the same way this app marks its own model games.
            isModelGame:
                isModelGameHeaders(game.headers) ||
                (chapterTitles != null &&
                    (game.headers['Result'] ?? '*').trim() != '*'),
            gameIndex: gameIndex,
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error parsing game $gameIndex: $e');
        }
        continue;
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

  /// The id each game in [games] resolves to — null for games that do not
  /// parse or have no moves — using exactly the rule of [parseRepertoirePgn],
  /// including collision resolution. This is what file edits must use to
  /// find a line by id.
  ///
  /// Reads the header block and lexes the mainline ([pgn.mainlineSansOf])
  /// instead of building each game's move tree with dartchess: an id needs
  /// the header id or the mainline SAN list, nothing more, and this runs over
  /// every game in the file on every rename, autosave and review rating.
  List<String?> lineIdsForGames(List<String> games) {
    final ids = List<String?>.filled(games.length, null);
    final seen = <String>{};
    for (var i = 0; i < games.length; i++) {
      final moves = pgn.mainlineSansOf(games[i]);
      if (moves.isEmpty) continue;
      final id = repertoireLineIds.fromHeaders(
        pgn.extractHeaderBlock(games[i]),
        moves,
        i,
      );
      ids[i] = seen.add(id)
          ? id
          : repertoireLineIds.resolveCollision(moves, i, seen);
    }
    return ids;
  }

  /// [lineIdsForGames] for the document at [filePath], memoised on the
  /// file's size and mtime.  An edit session issues a burst of lookups
  /// against a file that only changes when this service writes it, so a
  /// hit is the common case and a miss costs one lexing pass.
  Future<List<String?>> _lineIdsForFile(
    String filePath,
    io.FileStat stat,
    List<String> games,
  ) async {
    final cached = _lineIdCache[filePath];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified &&
        cached.gameCount == games.length) {
      return cached.ids;
    }
    final ids = lineIdsForGames(games);
    _lineIdCache[filePath] = _CachedLineIds(
      size: stat.size,
      modified: stat.modified,
      gameCount: games.length,
      ids: ids,
    );
    return ids;
  }

  /// One entry per edited file; bounded by the handful of chapters a
  /// session touches, and never larger than the on-disk repertoire.
  static final Map<String, _CachedLineIds> _lineIdCache = {};

  /// Detects chapter titles carried in game headers, the way Chessable
  /// course exports encode them: every game titles its chapter in [White]
  /// and its variation in [Black], with [Result] always "*".
  ///
  /// Returns one chapter name (or null) per game, or null when the file does
  /// not look chapter-titled. The guards keep real-game collections (decisive
  /// results, player names) and this app's own exports ([White "Me"],
  /// [Result "1-0"]) from producing bogus chapters.
  List<String?>? detectHeaderChapters(
    List<Map<String, String>> headersPerGame,
  ) {
    const ignoredTitles = {'', '?', 'me', 'opponent', 'white', 'black', 'n.n.'};

    var titled = 0;
    var selfDescribed = false;
    final counts = <String, int>{};
    final chapters = <String?>[];
    for (final headers in headersPerGame) {
      final white = (headers['White'] ?? '').trim();
      final result = (headers['Result'] ?? '*').trim();
      final isChapterTitle =
          result == '*' && !ignoredTitles.contains(white.toLowerCase());
      chapters.add(isChapterTitle ? white : null);
      if (isChapterTitle) {
        titled++;
        counts[white] = (counts[white] ?? 0) + 1;
      }
      selfDescribed = selfDescribed || isModelGameHeaders(headers);
    }

    // Chapter-style only when titles actually group games: more than one
    // chapter, at least one with multiple games, covering most of the file.
    if (counts.length < 2) return null;
    // ModelGame* tags only exist in this app's own course exports, so a file
    // carrying them needs no guessing — and a small course can legitimately
    // hold one line and one model game.
    if (!selfDescribed && !counts.values.any((c) => c >= 2)) return null;
    if (titled * 2 < headersPerGame.length) return null;
    return chapters;
  }

  Position extractStartPositionFromPgn(String pgnText) {
    try {
      final game = PgnGame.parsePgn(pgnText);
      return extractStartPosition(game);
    } catch (_) {
      return Chess.initial;
    }
  }

  Position extractStartPosition(PgnGame game) {
    final fen = game.headers['FEN']?.trim();
    if (fen == null || fen.isEmpty) {
      return Chess.initial;
    }

    return tryParseFen(fen) ?? Chess.initial;
  }

  /// Extract cumulative line probability (0–1) from PGN headers or comments.
  double? _extractImportance(PgnGame game, String gameText) {
    final cumProbHeader = game.headers['CumProb'];
    if (cumProbHeader != null && cumProbHeader.isNotEmpty) {
      final parsed = _parseCumulativeProbPgnValue(cumProbHeader);
      if (parsed != null) return parsed;
    }

    final legacyHeader = game.headers['Importance'];
    if (legacyHeader != null && legacyHeader.isNotEmpty) {
      final parsed = _parseCumulativeProbPgnValue(legacyHeader);
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
  double? _parseCumulativeProbPgnValue(String raw) {
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

  /// Generates a meaningful name for the repertoire line
  String _generateLineName(PgnGame game, List<String> mainline, int index) {
    final event = game.headers['Event'] ?? '';
    final opening = game.headers['Opening'] ?? '';

    if (opening.isNotEmpty && opening != '?') {
      return opening;
    } else if (event.isNotEmpty &&
        event != '?' &&
        event != 'Repertoire Line' &&
        event != 'Edited Line') {
      return event;
    } else if (mainline.isNotEmpty) {
      return 'Line: ${mainline.take(3).join(' ')}';
    } else {
      return 'Repertoire Line ${index + 1}';
    }
  }

  /// Splits a PGN document into its `//` preamble and its games, exactly as
  /// [pgn.splitPgnIntoGames] indexes them.
  ///
  /// The trailing space in `'[Event '` is load-bearing and the reason this
  /// agrees with the parser at all: a bare `[Event` prefix also matches
  /// `[EventDate "…"]`, which every Chessable export carries, and cutting
  /// there split each game in two. Every index-addressed edit
  /// ([readGameTextAt], [deleteGameAt], [updateGameTitleAt], [moveGame]) then
  /// landed on the wrong half of the wrong game.
  ({String preamble, List<String> games}) _splitPgnDocumentPreservingPreamble(
    String content,
  ) {
    content = pgn.stripBom(content);
    final preambleLines = <String>[];
    final games = <String>[];
    var gameStart = -1;

    // One pass over line starts; a game is a substring between two `[Event `
    // lines, right-trimmed as the line-joining version produced it.
    var lineStart = 0;
    while (lineStart <= content.length) {
      var lineEnd = content.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = content.length;

      if (_startsWithEventTag(content, lineStart, lineEnd)) {
        if (gameStart >= 0) {
          final text = content.substring(gameStart, lineStart).trimRight();
          if (text.isNotEmpty) games.add(text);
        }
        gameStart = lineStart;
      } else if (gameStart < 0) {
        final line = content.substring(lineStart, lineEnd);
        if (line.trim().isNotEmpty) preambleLines.add(line);
      }
      lineStart = lineEnd + 1;
    }
    if (gameStart >= 0) {
      final text = content.substring(gameStart).trimRight();
      if (text.isNotEmpty) games.add(text);
    }

    return (preamble: preambleLines.join('\n').trimRight(), games: games);
  }

  /// Whether the line `[start, end)` is `[Event ` after optional blanks.
  static bool _startsWithEventTag(String content, int start, int end) {
    var i = start;
    while (i < end) {
      final c = content.codeUnitAt(i);
      if (c != 0x20 && c != 0x09 && c != 0x0D) break;
      i++;
    }
    return content.startsWith('[Event ', i);
  }

  /// Extract a stable line identifier, preferring a PGN header if present.
  String _extractLineId(PgnGame game, List<String> moves, int index) =>
      repertoireLineIds.fromHeaders(game.headers, moves, index);

  /// The line id the trainer will assign to the [index]-th game of [pgn].
  ///
  /// Lives here rather than on [RepertoireLineIds] because it has to *parse*
  /// first, and it parses through the same pipeline as the trainer so the
  /// two agree regardless of how the source serialized its headers. Returns
  /// null when [pgn] does not parse.
  String? lineIdForGamePgn(String pgnText, int index) {
    final moves = pgn.mainlineSansOf(pgnText);
    if (moves.isEmpty) return null;
    return repertoireLineIds.fromHeaders(
      pgn.extractHeaderBlock(pgnText),
      moves,
      index,
    );
  }

  /// Reassemble a PGN document from preamble + game list.
  /// Loads the PGN document at [filePath], locates the game for [lineId],
  /// lets [mutate] modify the mutable games list (given the match index),
  /// then writes the result back atomically. Returns false if the file or
  /// line is missing.
  ///
  /// [gameIndex] is the caller's [RepertoireLine.gameIndex] when it has one:
  /// the game there is used directly when it still resolves to [lineId],
  /// which it does unless the file changed under us.  Ids are otherwise
  /// looked up through the per-file cache ([_lineIdsForFile]), so neither
  /// path parses a move tree.
  Future<bool> _editLineInFile(
    String filePath,
    String lineId,
    void Function(List<String> games, int matchIndex) mutate, {
    int? gameIndex,
  }) async {
    final file = io.File(filePath);
    if (!await file.exists()) return false;

    final stat = await file.stat();
    final content = await readTextFile(file);
    final document = _splitPgnDocumentPreservingPreamble(content);
    final games = List<String>.from(document.games);

    final ids = await _lineIdsForFile(filePath, stat, games);
    final matchIndex =
        gameIndex != null &&
            gameIndex >= 0 &&
            gameIndex < ids.length &&
            ids[gameIndex] == lineId
        ? gameIndex
        : ids.indexOf(lineId);
    if (matchIndex < 0) return false;

    mutate(games, matchIndex);

    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      expectedContent: content,
    );
    return true;
  }

  Future<bool> updateLineTitle(
    String filePath,
    String lineId,
    String newTitle, {
    int? gameIndex,
  }) {
    return _editLineInFile(filePath, lineId, gameIndex: gameIndex, (
      games,
      matchIndex,
    ) {
      games[matchIndex] = withEventTitle(games[matchIndex], newTitle);
    });
  }

  /// Replaces the full PGN content of an existing line identified by [lineId].
  ///
  /// This is the in-place edit counterpart of [updateLineTitle].  The caller
  /// provides the complete new PGN text (headers + move text) which replaces
  /// the old game entry on disk.
  Future<bool> updateLineContent(
    String filePath,
    String lineId,
    String newGamePgn, {
    int? gameIndex,
  }) {
    return _editLineInFile(filePath, lineId, gameIndex: gameIndex, (
      games,
      matchIndex,
    ) {
      games[matchIndex] = mergeMissingHeaders(
        games[matchIndex],
        newGamePgn.trimRight(),
      );
    });
  }

  /// Removes a game identified by [lineId] from the PGN file on disk.
  Future<bool> deleteLine(String filePath, String lineId, {int? gameIndex}) {
    return _editLineInFile(filePath, lineId, gameIndex: gameIndex, (
      games,
      matchIndex,
    ) {
      games.removeAt(matchIndex);
    });
  }

  /// Removes every game whose position in the file is in [gameIndexes], in
  /// one read and one write. Returns how many games went.
  ///
  /// Index-addressed for the reason [readGameTextAt] gives: the move-based
  /// line id truncates and collides for lines sharing a long prefix, so
  /// deleting several by id can take out the wrong games. It also matters
  /// that this is one write — trimming a generated course drops hundreds of
  /// lines at once, and doing that a game at a time rewrites (and reloads)
  /// the file hundreds of times.
  Future<int> deleteLinesAt(String filePath, Set<int> gameIndexes) async {
    if (gameIndexes.isEmpty) return 0;
    final document = await readPgnDocument(filePath);
    if (document == null) return 0;
    final kept = <String>[];
    for (var i = 0; i < document.games.length; i++) {
      if (!gameIndexes.contains(i)) kept.add(document.games[i]);
    }
    final removed = document.games.length - kept.length;
    if (removed == 0) return 0;
    await writePgnDocument(
      filePath,
      preamble: document.preamble,
      games: kept,
      expectedContent: document.originalContent,
    );
    return removed;
  }

  /// The full PGN text of the [gameIndex]-th game in the file, or null when
  /// the file or the game is missing.
  ///
  /// Index-addressed rather than id-addressed on purpose: the move-based line
  /// id truncates and collides for lines sharing a long prefix, so an id
  /// lookup can return the wrong game. [RepertoireLine.gameIndex] is exact.
  Future<String?> readGameTextAt(String filePath, int gameIndex) async {
    final document = await readPgnDocument(filePath);
    if (document == null) return null;
    if (gameIndex < 0 || gameIndex >= document.games.length) return null;
    return document.games[gameIndex];
  }

  /// The whole document at [filePath]: its `//` preamble and every game as
  /// raw text, indexed the way [RepertoireLine.gameIndex] is. Null when the
  /// file does not exist.
  ///
  /// Exists so a caller that needs *every* game (splitting a chapter, say)
  /// reads and cuts the file once instead of once per game.
  Future<({String preamble, List<String> games, String originalContent})?>
  readPgnDocument(String filePath) async {
    final file = io.File(filePath);
    if (!await file.exists()) return null;
    final content = await readTextFile(file);
    final document = _splitPgnDocumentPreservingPreamble(content);
    return (
      preamble: document.preamble,
      games: document.games,
      originalContent: content,
    );
  }

  /// Writes [games] under [preamble] as a complete PGN document, replacing
  /// whatever is at [filePath]. Same layout as every other write here, so a
  /// file this produces is indistinguishable from one the editors touched.
  Future<void> writePgnDocument(
    String filePath, {
    required String preamble,
    required List<String> games,
    bool createOnly = false,
    String? expectedContent,
  }) async {
    await writeTextFileAtomically(
      io.File(filePath),
      reassemblePgnDocument(preamble.trimRight(), games),
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }

  /// Edits the [gameIndex]-th game in place. Returns false when out of range.
  Future<bool> _editGameAt(
    String filePath,
    int gameIndex,
    void Function(List<String> games) mutate,
  ) async {
    final file = io.File(filePath);
    if (!await file.exists()) return false;
    final content = await readTextFile(file);
    final document = _splitPgnDocumentPreservingPreamble(content);
    if (gameIndex < 0 || gameIndex >= document.games.length) return false;
    final games = List<String>.from(document.games);
    mutate(games);
    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      expectedContent: content,
    );
    return true;
  }

  Future<bool> deleteGameAt(String filePath, int gameIndex) =>
      _editGameAt(filePath, gameIndex, (games) => games.removeAt(gameIndex));

  Future<bool> updateGameTitleAt(
    String filePath,
    int gameIndex,
    String newTitle,
  ) => _editGameAt(filePath, gameIndex, (games) {
    games[gameIndex] = withEventTitle(games[gameIndex], newTitle);
  });

  /// Appends [gameTexts] to the chapter at [filePath], creating the file when
  /// it does not exist. Each text is one complete PGN game.
  Future<void> appendGameTexts(String filePath, List<String> gameTexts) async {
    if (gameTexts.isEmpty) return;
    final file = io.File(filePath);
    final existed = await file.exists();
    final content = existed ? await readTextFile(file) : '';
    final document = _splitPgnDocumentPreservingPreamble(content);
    final games = [
      ...document.games,
      for (final t in gameTexts)
        if (t.trim().isNotEmpty) t.trim(),
    ];
    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      createOnly: !existed,
      expectedContent: existed ? content : null,
    );
  }

  /// Moves the [gameIndex]-th game of [fromPath] to the end of [toPath]:
  /// appended to the destination first, then removed from the source, so a
  /// failure between the two can leave a duplicate but never a lost line.
  /// Returns false when the game was not found.
  Future<bool> moveGame({
    required String fromPath,
    required int gameIndex,
    required String toPath,
  }) async {
    if (p.equals(fromPath, toPath)) return true;
    final text = await readGameTextAt(fromPath, gameIndex);
    if (text == null) return false;
    await appendGameTexts(toPath, [text]);
    return deleteGameAt(fromPath, gameIndex);
  }

  /// Writes spaced-repetition metadata into PGN headers for a specific line.
  /// Headers used: [LastReview], [Difficulty], [Interval], [DueDate],
  /// [PassCount], [FailCount]. Unknown headers are ignored by standard PGN
  /// parsers, making this forward/backward compatible.
  Future<bool> updateLineReviewHeaders(
    String filePath,
    String lineId, {
    required DateTime? lastReview,
    required double difficulty,
    required double intervalDays,
    required DateTime? dueDate,
    required int passCount,
    required int failCount,
  }) {
    return _editLineInFile(filePath, lineId, (games, matchIndex) {
      games[matchIndex] = gameWithReviewHeaders(
        games[matchIndex],
        lastReview: lastReview,
        difficulty: difficulty,
        intervalDays: intervalDays,
        dueDate: dueDate,
        passCount: passCount,
        failCount: failCount,
      );
    });
  }

  /// Bulk counterpart of [updateLineReviewHeaders]: rewrites the review
  /// headers of every line in [entriesByLineId] with a single read and one
  /// atomic write. A per-line loop over [updateLineReviewHeaders] would
  /// reread and rewrite the whole file once per line.
  Future<bool> updateManyLineReviewHeaders(
    String filePath,
    Map<String, RepertoireReviewEntry> entriesByLineId,
  ) async {
    if (entriesByLineId.isEmpty) return true;
    final file = io.File(filePath);
    if (!await file.exists()) return false;

    final stat = await file.stat();
    final content = await readTextFile(file);
    final document = _splitPgnDocumentPreservingPreamble(content);
    final games = List<String>.from(document.games);

    // Resolve every id in one pass; looking each entry up separately would
    // make the bulk write quadratic in exactly the case it exists to make
    // cheap.
    final idsByIndex = await _lineIdsForFile(filePath, stat, games);
    final indexById = <String, int>{};
    for (var i = 0; i < idsByIndex.length; i++) {
      final id = idsByIndex[i];
      if (id != null) indexById.putIfAbsent(id, () => i);
    }

    bool anyMatched = false;
    for (final entry in entriesByLineId.entries) {
      final matchIndex = indexById[entry.key];
      if (matchIndex == null) continue;
      final e = entry.value;
      games[matchIndex] = gameWithReviewHeaders(
        games[matchIndex],
        lastReview: e.lastReviewedUtc,
        difficulty: e.difficulty,
        intervalDays: e.intervalDays,
        dueDate: e.dueDateUtc,
        passCount: e.passCount,
        failCount: e.failCount,
      );
      anyMatched = true;
    }
    if (!anyMatched) return false;

    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      expectedContent: content,
    );
    return true;
  }

  /// Appends [san] after [pathFromRoot] in the best-matching game, or adds a
  /// new game when no exact prefix match exists.
  Future<({bool success, String updatedContent})> appendMoveAtPath(
    String filePath,
    List<String> pathFromRoot,
    String san, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  }) async {
    final result = await appendMovesAtPath(
      filePath,
      pathFromRoot,
      [san],
      startingFen: startingFen,
      isWhiteRepertoire: isWhiteRepertoire,
    );
    return (success: result.success, updatedContent: result.updatedContent);
  }

  /// Appends [newSans] after [pathFromRoot]: onto the game whose mainline is
  /// exactly [pathFromRoot] when there is one, else as a new game holding
  /// the whole line.  One read, one lexing pass, one atomic write for
  /// however many plies — a build-by-playing commit used to do all three
  /// once per ply.
  ///
  /// Equivalent to calling [appendMoveAtPath] once per ply: after the first
  /// append the game's mainline is the extended prefix, so every later ply
  /// lands on the same game.  [snapshots] holds the document as it would
  /// have stood after each ply (the last one is [updatedContent]), so a
  /// caller keeping per-ply undo history has the same states the per-ply
  /// writes produced — assembled in memory, never written.
  Future<({bool success, String updatedContent, List<String> snapshots})>
  appendMovesAtPath(
    String filePath,
    List<String> pathFromRoot,
    List<String> newSans, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  }) async {
    final file = io.File(filePath);
    if (!await file.exists()) {
      return (success: false, updatedContent: '', snapshots: const <String>[]);
    }

    final content = await readTextFile(file);
    if (newSans.isEmpty) {
      return (
        success: true,
        updatedContent: content,
        snapshots: const <String>[],
      );
    }
    final document = _splitPgnDocumentPreservingPreamble(content);
    final games = List<String>.from(document.games);

    // The mainline is all that decides a match, and lexing it is a fraction
    // of building each game's move tree.
    final exactMatchIndex = games.indexWhere(
      (game) => listEquals(pgn.mainlineSansOf(game), pathFromRoot),
    );

    final snapshots = <String>[];
    var prefix = pathFromRoot;
    for (final san in newSans) {
      if (exactMatchIndex >= 0) {
        games[exactMatchIndex] = appendSanToGamePgn(
          games[exactMatchIndex],
          prefix,
          san,
        );
      } else if (prefix.length == pathFromRoot.length) {
        games.add(
          buildMinimalGamePgn(
            [...pathFromRoot, san],
            startingFen: startingFen,
            isWhiteRepertoire: isWhiteRepertoire,
          ),
        );
      } else {
        games[games.length - 1] = appendSanToGamePgn(games.last, prefix, san);
      }
      prefix = [...prefix, san];
      snapshots.add(reassemblePgnDocument(document.preamble, games));
    }

    final updated = snapshots.last;
    await writeTextFileAtomically(file, updated, expectedContent: content);
    return (success: true, updatedContent: updated, snapshots: snapshots);
  }
}

/// The ids of one file's games, valid while the file's stat is unchanged.
class _CachedLineIds {
  const _CachedLineIds({
    required this.size,
    required this.modified,
    required this.gameCount,
    required this.ids,
  });

  final int size;
  final DateTime modified;
  final int gameCount;
  final List<String?> ids;
}
