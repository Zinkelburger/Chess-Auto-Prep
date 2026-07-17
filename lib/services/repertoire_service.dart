/// Repertoire parsing and training service
/// Extracts trainable lines from PGN files and manages training sessions
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import '../models/repertoire_line.dart';
import '../utils/atomic_file.dart';
import '../utils/file_text_reader.dart';
import '../utils/pgn_comment_utils.dart';
import 'pgn_parsing_service.dart' as pgn;
import 'storage/storage_factory.dart';

class RepertoireService {
  /// Parses a repertoire PGN file and extracts all trainable lines.
  ///
  /// If [trainingColor] is provided ('white' or 'black') it is used directly;
  /// otherwise the colour is read from the file's `// Color:` comment.
  /// [colorFromStartingSide] derives each line's colour from its own start
  /// position instead (study puzzles: the solver is the side to move).
  Future<List<RepertoireLine>> parseRepertoireFile(
    String filePath, {
    String? trainingColor,
    bool colorFromStartingSide = false,
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
  List<RepertoireLine> parseRepertoirePgn(
    String pgnContent, {
    String? trainingColor,
    bool colorFromStartingSide = false,
  }) {
    pgnContent = pgn.stripBom(pgnContent);
    final lines = <RepertoireLine>[];
    final resolvedColor =
        trainingColor ?? pgn.extractRepertoireColor(pgnContent) ?? 'white';

    final games = pgn.splitPgnIntoGames(pgnContent);

    for (int gameIndex = 0; gameIndex < games.length; gameIndex++) {
      final gameText = games[gameIndex];

      try {
        final game = PgnGame.parsePgn(gameText);

        final mainlineMoves = game.moves
            .mainline()
            .map((node) => node.san)
            .toList();

        if (mainlineMoves.isEmpty) continue;

        final startPosition = extractStartPosition(game);
        final color = colorFromStartingSide
            ? (startPosition.turn == Side.white ? 'white' : 'black')
            : resolvedColor;

        final comments = <String, String>{};
        final moveNodes = game.moves.mainline().toList();
        for (int i = 0; i < moveNodes.length; i++) {
          final node = moveNodes[i];
          if (node.comments != null && node.comments!.isNotEmpty) {
            final comment = node.comments!.join(' ').trim();
            if (comment.isNotEmpty) {
              comments[i.toString()] = comment;
            }
          }
        }

        final variations = <String>[];
        _extractVariations(game.moves, variations);

        final lineName = _generateLineName(game, gameIndex);
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
            variations: variations,
            headers: Map<String, String>.from(game.headers),
            importance: importance,
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error parsing game $gameIndex: $e');
        }
        continue;
      }
    }

    return lines;
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

    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return Chess.initial;
    }
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

    final cumProbMatch = RegExp(r'CumProb\s+([\d.]+)%').firstMatch(gameText);
    if (cumProbMatch != null) {
      final pct = double.tryParse(cumProbMatch.group(1)!);
      if (pct != null) return pct / 100.0;
    }

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
  String _generateLineName(PgnGame game, int index) {
    final event = game.headers['Event'] ?? '';
    final opening = game.headers['Opening'] ?? '';

    if (opening.isNotEmpty && opening != '?') {
      return opening;
    } else if (event.isNotEmpty &&
        event != '?' &&
        event != 'Repertoire Line' &&
        event != 'Edited Line') {
      return event;
    } else {
      final moves = game.moves
          .mainline()
          .take(3)
          .map((node) => node.san)
          .toList();
      if (moves.isNotEmpty) {
        return 'Line: ${moves.join(' ')}';
      } else {
        return 'Repertoire Line ${index + 1}';
      }
    }
  }

  /// Recursively extracts variation strings for reference
  void _extractVariations(PgnNode<PgnNodeData> moves, List<String> variations) {
    for (int i = 1; i < moves.children.length; i++) {
      final variation = _variationToSanString(moves.children[i]);
      if (variation.isNotEmpty) {
        variations.add(variation);
      }
    }

    if (moves.children.isNotEmpty) {
      _extractVariations(moves.children.first, variations);
    }
  }

  String _variationToSanString(PgnChildNode<PgnNodeData> startNode) {
    final sans = <String>[startNode.data.san];
    var current = startNode;

    while (current.children.isNotEmpty) {
      current = current.children.first;
      sans.add(current.data.san);
    }

    return sans.join(' ');
  }

  ({String preamble, List<String> games}) _splitPgnDocumentPreservingPreamble(
    String content,
  ) {
    content = pgn.stripBom(content);
    final lines = content.split('\n');
    final preambleLines = <String>[];
    final games = <String>[];
    var currentGame = <String>[];
    var seenGame = false;

    void flushCurrentGame() {
      final gameText = currentGame.join('\n').trimRight();
      if (gameText.isNotEmpty) {
        games.add(gameText);
      }
      currentGame = <String>[];
    }

    for (final line in lines) {
      final trimmed = line.trim();

      if (!seenGame) {
        if (trimmed.startsWith('[Event')) {
          seenGame = true;
          currentGame.add(line);
        } else if (trimmed.isNotEmpty) {
          preambleLines.add(line);
        }
        continue;
      }

      if (trimmed.startsWith('[Event') && currentGame.isNotEmpty) {
        flushCurrentGame();
        currentGame.add(line);
        continue;
      }

      currentGame.add(line);
    }

    flushCurrentGame();

    return (preamble: preambleLines.join('\n').trimRight(), games: games);
  }

  /// Extract a stable line identifier, preferring a PGN header if present.
  String _extractLineId(PgnGame game, List<String> moves, int index) =>
      lineIdFromHeaders(game.headers, moves, index);

  /// The line id the trainer assigns to a game: a `LineID`/`Id`/… header when
  /// present, else the stable move-based fallback.  Callers that want to
  /// target a specific line (e.g. "Train this chapter") must derive the id
  /// this way — the header-blind [generateLineId] silently mismatches any
  /// PGN that carries such a header.
  String lineIdFromHeaders(
    Map<String, String> headers,
    List<String> moves,
    int index,
  ) {
    final headerId =
        headers['LineID'] ??
        headers['LineId'] ??
        headers['Id'] ??
        headers['Line'] ??
        headers['Guid'];

    if (headerId != null && headerId.trim().isNotEmpty) {
      return headerId.trim();
    }

    // Stable fallback based on moves so it persists across sessions.
    return _generateStableLineId(moves, index);
  }

  /// The line id the trainer will assign to the [index]-th game of [pgn].
  /// Parses [pgn] through the same pipeline as the trainer ([PgnGame.parsePgn]
  /// + [_extractLineId]) so the two agree regardless of how the source
  /// serialized its headers.  Returns null when [pgn] doesn't parse.
  String? lineIdForGamePgn(String pgn, int index) {
    try {
      final game = PgnGame.parsePgn(pgn);
      final moves = game.moves.mainline().map((n) => n.san).toList();
      return _extractLineId(game, moves, index);
    } catch (_) {
      return null;
    }
  }

  /// Public access to generate a stable line ID from moves.
  String generateLineId(List<String> moves, int index) =>
      _generateStableLineId(moves, index);

  /// Find the index of the game matching [lineId] within [games].
  int? _findGameIndexByLineId(List<String> games, String lineId) {
    for (int i = 0; i < games.length; i++) {
      try {
        final game = PgnGame.parsePgn(games[i]);
        final moves = game.moves.mainline().map((n) => n.san).toList();
        final id = _extractLineId(game, moves, i);
        if (id == lineId) return i;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Reassemble a PGN document from preamble + game list.
  String _reassembleDocument(String preamble, List<String> games) {
    final sections = <String>[if (preamble.isNotEmpty) preamble, ...games];
    return '${sections.join('\n\n').trimRight()}\n';
  }

  String _generateStableLineId(List<String> moves, int index) {
    final raw = base64Url.encode(utf8.encode('${moves.join(' ')}|$index'));
    final trimmed = raw.replaceAll('=', '');
    return 'line_${trimmed.length > 22 ? trimmed.substring(0, 22) : trimmed}';
  }

  /// Creates training questions from repertoire lines for a specific color
  List<TrainingQuestion> createTrainingQuestions(
    List<RepertoireLine> lines, {
    String? colorFilter,
  }) {
    final questions = <TrainingQuestion>[];

    for (final line in lines) {
      if (colorFilter != null && line.color != colorFilter) {
        continue;
      }

      for (int moveIndex = 0; moveIndex < line.moves.length; moveIndex++) {
        final isWhiteMove = moveIndex % 2 == 0;
        final shouldIncludeMove =
            (line.color == 'white' && isWhiteMove) ||
            (line.color == 'black' && !isWhiteMove);

        if (shouldIncludeMove) {
          try {
            questions.add(line.createTrainingQuestion(moveIndex));
          } catch (e) {
            if (kDebugMode) {
              debugPrint(
                'Error creating training question for ${line.name} '
                'move $moveIndex: $e',
              );
            }
          }
        }
      }
    }

    return questions;
  }

  /// Filters training questions based on difficulty or position type
  List<TrainingQuestion> filterQuestions(
    List<TrainingQuestion> questions, {
    int? maxMoveDepth,
    bool? openingOnly,
  }) {
    var filtered = questions;

    if (maxMoveDepth != null) {
      filtered = filtered.where((q) => q.moveIndex < maxMoveDepth).toList();
    }

    if (openingOnly == true) {
      filtered = filtered
          .where((q) => q.moveIndex < 20)
          .toList(); // First 10 moves per side
    }

    return filtered;
  }

  /// Shuffles questions for training variety
  List<TrainingQuestion> shuffleQuestions(List<TrainingQuestion> questions) {
    final shuffled = List<TrainingQuestion>.from(questions);
    shuffled.shuffle();
    return shuffled;
  }

  /// Updates the [Event] header (title) for a specific line in a PGN file.
  ///
  /// Finds the game matching [lineId] by re-parsing the file, then rewrites
  /// the [Event] header with [newTitle].
  /// Loads the PGN document at [filePath], locates the game for [lineId], lets
  /// [mutate] modify the mutable games list (given the match index), then writes
  /// the result back atomically. Returns false if the file or line is missing.
  Future<bool> _editLineInFile(
    String filePath,
    String lineId,
    void Function(List<String> games, int matchIndex) mutate,
  ) async {
    final file = io.File(filePath);
    if (!await file.exists()) return false;

    final content = await readTextFile(file);
    final document = _splitPgnDocumentPreservingPreamble(content);
    final games = List<String>.from(document.games);

    final matchIndex = _findGameIndexByLineId(games, lineId);
    if (matchIndex == null) return false;

    mutate(games, matchIndex);

    await writeTextFileAtomically(
      file,
      _reassembleDocument(document.preamble, games),
    );
    return true;
  }

  Future<bool> updateLineTitle(
    String filePath,
    String lineId,
    String newTitle,
  ) {
    return _editLineInFile(filePath, lineId, (games, matchIndex) {
      final gameText = games[matchIndex];
      final eventRegex = RegExp(r'\[Event\s+"[^"]*"\]');
      games[matchIndex] = eventRegex.hasMatch(gameText)
          ? gameText.replaceFirst(eventRegex, '[Event "$newTitle"]')
          : '[Event "$newTitle"]\n$gameText';
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
    String newGamePgn,
  ) {
    return _editLineInFile(filePath, lineId, (games, matchIndex) {
      games[matchIndex] = _mergeMissingHeaders(
        games[matchIndex],
        newGamePgn.trimRight(),
      );
    });
  }

  /// The PGN editor serializes only the standard headers, so carry over any
  /// header the old game had that the new text lacks (LineID, review
  /// metadata, CumProb, …). Dropping LineID would orphan the line: every
  /// later lookup by id — rename, autosave, delete — silently fails.
  String _mergeMissingHeaders(String oldGame, String newGame) {
    final keyPattern = RegExp(r'^\[(\w+)\s+"[^"]*"\]$');

    List<String> headerLines(String game) {
      final result = <String>[];
      for (final line in game.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          if (result.isNotEmpty) break;
          continue;
        }
        if (keyPattern.hasMatch(trimmed)) {
          result.add(trimmed);
        } else {
          break;
        }
      }
      return result;
    }

    final newKeys = headerLines(
      newGame,
    ).map((h) => keyPattern.firstMatch(h)!.group(1)!).toSet();
    final missing = headerLines(oldGame)
        .where((h) => !newKeys.contains(keyPattern.firstMatch(h)!.group(1)!))
        .toList();
    if (missing.isEmpty) return newGame;

    final lines = newGame.split('\n');
    var lastHeader = -1;
    for (int i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (keyPattern.hasMatch(trimmed)) {
        lastHeader = i;
      } else if (trimmed.isNotEmpty) {
        break;
      }
    }
    if (lastHeader == -1) {
      lines.insertAll(0, [...missing, '']);
    } else {
      lines.insertAll(lastHeader + 1, missing);
    }
    return lines.join('\n');
  }

  /// Removes a game identified by [lineId] from the PGN file on disk.
  Future<bool> deleteLine(String filePath, String lineId) {
    return _editLineInFile(filePath, lineId, (games, matchIndex) {
      games.removeAt(matchIndex);
    });
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
      final gameText = games[matchIndex];
      final headerPattern = RegExp(r'^\[(\w+)\s+"([^"]*)"\]', multiLine: true);
      final headers = <String, String>{};
      String moveText = '';

      final lines = gameText.split('\n');
      bool pastHeaders = false;
      final moveLines = <String>[];

      for (final line in lines) {
        final trimmed = line.trim();
        if (!pastHeaders && headerPattern.hasMatch(trimmed)) {
          final match = headerPattern.firstMatch(trimmed)!;
          headers[match.group(1)!] = match.group(2)!;
        } else {
          pastHeaders = true;
          moveLines.add(line);
        }
      }
      moveText = moveLines.join('\n').trim();

      String fmtDate(DateTime? d) =>
          d == null ? '' : d.toUtc().toIso8601String();
      headers['LastReview'] = fmtDate(lastReview);
      headers['Difficulty'] = difficulty.toStringAsFixed(2);
      headers['Interval'] = intervalDays.toStringAsFixed(2);
      headers['DueDate'] = fmtDate(dueDate);
      headers['PassCount'] = passCount.toString();
      headers['FailCount'] = failCount.toString();

      final buffer = StringBuffer();
      const standardOrder = [
        'Event',
        'Site',
        'Date',
        'Round',
        'White',
        'Black',
        'Result',
        'FEN',
        'SetUp',
        'ECO',
        'Opening',
        'LineID',
        'LineId',
        'Id',
        'Line',
        'Guid',
      ];
      final written = <String>{};
      for (final key in standardOrder) {
        if (headers.containsKey(key)) {
          buffer.writeln('[$key "${headers[key]}"]');
          written.add(key);
        }
      }
      for (final entry in headers.entries) {
        if (!written.contains(entry.key)) {
          buffer.writeln('[${entry.key} "${entry.value}"]');
        }
      }
      buffer.writeln();
      buffer.write(moveText);

      games[matchIndex] = buffer.toString().trimRight();
    });
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
    final file = io.File(filePath);
    if (!await file.exists()) {
      return (success: false, updatedContent: '');
    }

    final content = await readTextFile(file);
    final document = _splitPgnDocumentPreservingPreamble(content);
    final games = List<String>.from(document.games);

    int? exactMatchIndex;
    for (int i = 0; i < games.length; i++) {
      try {
        final game = PgnGame.parsePgn(games[i]);
        final moves = game.moves.mainline().map((n) => n.san).toList();
        if (_listEquals(moves, pathFromRoot)) {
          exactMatchIndex = i;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    if (exactMatchIndex != null) {
      games[exactMatchIndex] = appendSanToGamePgn(
        games[exactMatchIndex],
        pathFromRoot,
        san,
      );
    } else {
      final fullPath = [...pathFromRoot, san];
      games.add(
        buildMinimalGamePgn(
          fullPath,
          startingFen: startingFen,
          isWhiteRepertoire: isWhiteRepertoire,
        ),
      );
    }

    final sections = <String>[];
    if (document.preamble.isNotEmpty) {
      sections.add(document.preamble);
    }
    sections.addAll(games);
    final updated = '${sections.join('\n\n').trimRight()}\n';
    await writeTextFileAtomically(file, updated);
    return (success: true, updatedContent: updated);
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _formatNextSan(List<String> existingMoves, String san) {
    final nextIndex = existingMoves.length;
    if (nextIndex.isEven) {
      return '${(nextIndex ~/ 2) + 1}. $san';
    }
    return san;
  }

  String appendSanToGamePgn(
    String gameText,
    List<String> existingMoves,
    String san,
  ) {
    final lines = gameText.split('\n');
    final moveLines = <String>[];
    final headerLines = <String>[];
    final headerPattern = RegExp(r'^\[(\w+)\s+"([^"]*)"\]');

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (headerPattern.hasMatch(trimmed)) {
        headerLines.add(line);
      } else {
        moveLines.add(trimmed);
      }
    }

    final moveText = moveLines.join(' ').trim();
    final suffix = _formatNextSan(existingMoves, san);
    final updatedMoveText = moveText.isEmpty ? suffix : '$moveText $suffix';

    return [...headerLines, '', updatedMoveText].join('\n');
  }

  String buildMinimalGamePgn(
    List<String> moves, {
    String? startingFen,
    required bool isWhiteRepertoire,
  }) {
    final headers = <String>[
      '[Event "Repertoire Line"]',
      '[Date "${DateTime.now().toIso8601String().split('T')[0]}"]',
      '[White "${isWhiteRepertoire ? 'Me' : 'Opponent'}"]',
      '[Black "${isWhiteRepertoire ? 'Opponent' : 'Me'}"]',
      '[Result "1-0"]',
    ];

    if (startingFen != null && startingFen.trim().isNotEmpty) {
      headers.add('[FEN "$startingFen"]');
      headers.add('[SetUp "1"]');
    }

    final moveText = _movesToPgnMoveText(moves);
    return [...headers, '', moveText].join('\n');
  }

  static String _movesToPgnMoveText(List<String> moves) {
    if (moves.isEmpty) return '';
    final sb = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      if (i.isEven) sb.write('${(i ~/ 2) + 1}. ');
      sb.write(moves[i]);
      if (i < moves.length - 1) sb.write(' ');
    }
    return sb.toString();
  }
}
