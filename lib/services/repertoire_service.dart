/// Repertoire parsing and training service
/// Extracts trainable lines from PGN files and manages training sessions
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import '../models/repertoire_line.dart';
import 'storage/storage_factory.dart';

class RepertoireService {
  /// Parses a repertoire PGN file and extracts all trainable lines
  Future<List<RepertoireLine>> parseRepertoireFile(String filePath) async {
    // filePath is expected to be a key or filename for StorageService
    // On desktop it might be a full path, but readRepertoirePgn handles both logic
    // via StorageService implementations.
    final content = await StorageFactory.instance.readRepertoirePgn(filePath);
    
    if (content == null) {
      throw Exception('Repertoire file not found: $filePath');
    }

    return parseRepertoirePgn(content);
  }

  /// Parses repertoire PGN content and extracts trainable lines
  List<RepertoireLine> parseRepertoirePgn(String pgnContent) {
    final lines = <RepertoireLine>[];
    final defaultTrainingColor = _extractRepertoireColor(pgnContent);

    // Split PGN into individual games/sections
    final games = _splitPgnIntoGames(pgnContent);

    for (int gameIndex = 0; gameIndex < games.length; gameIndex++) {
      final gameText = games[gameIndex];

      try {
        // Parse the PGN game
        final game = PgnGame.parsePgn(gameText);

        // Extract mainline moves (this excludes variations in parentheses)
        final mainlineMoves = game.moves.mainline().map((node) => node.san).toList();

        if (mainlineMoves.isEmpty) continue;

        final trainingColor = _determineTrainingColor(
          game,
          defaultTrainingColor: defaultTrainingColor,
        );

        // Extract comments from the parsed game
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

        // Extract variation main lines for reference.
        final variations = <String>[];
        _extractVariations(game.moves, variations);

        // Create the repertoire line
        final lineName = _generateLineName(game, gameIndex);
        final lineId = _extractLineId(game, mainlineMoves, gameIndex);
        final startPosition = extractStartPosition(game);

        lines.add(RepertoireLine(
          id: lineId,
          name: lineName,
          moves: mainlineMoves,
          color: trainingColor,
          startPosition: startPosition,
          fullPgn: gameText,
          comments: comments,
          variations: variations,
        ));

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

  String? _extractRepertoireColor(String content) {
    final lines = content.split('\n');

    for (int i = 0; i < lines.length && i < 20; i++) {
      final line = lines[i].trim();
      if (line.startsWith('// Color:')) {
        final color = line.substring(9).trim().toLowerCase();
        if (color == 'white' || color == 'black') {
          return color;
        }
      }

      if (line.startsWith('[Event ')) {
        break;
      }
    }

    return null;
  }

  String _determineTrainingColor(
    PgnGame game, {
    String? defaultTrainingColor,
  }) {
    final whitePlayer = game.headers['White'] ?? '';
    final blackPlayer = game.headers['Black'] ?? '';

    if (_looksLikeTrainingSide(blackPlayer)) {
      return 'black';
    }
    if (_looksLikeTrainingSide(whitePlayer)) {
      return 'white';
    }

    return defaultTrainingColor ?? 'black';
  }

  bool _looksLikeTrainingSide(String playerName) {
    final lower = playerName.toLowerCase();
    return lower.contains('me') ||
        lower.contains('repertoire') ||
        lower.contains('training');
  }

  /// Splits PGN content into individual games
  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');

    String currentGame = '';
    bool inGame = false;

    for (final line in lines) {
      final trimmedLine = line.trim();

      // Skip comment-only lines at the top level
      if (trimmedLine.startsWith('//') && !inGame) {
        continue;
      }

      if (trimmedLine.startsWith('[Event')) {
        if (inGame && currentGame.trim().isNotEmpty) {
          games.add(currentGame);
        }
        currentGame = '$line\n';
        inGame = true;
      } else if (inGame) {
        currentGame += '$line\n';
      } else if (trimmedLine.isNotEmpty) {
        // Handle PGN without headers (just moves)
        if (!inGame) {
          currentGame = '[Event "Repertoire Line"]\n[White "Training"]\n[Black "Me"]\n\n';
          inGame = true;
        }
        currentGame += '$line\n';
      }
    }

    if (inGame && currentGame.trim().isNotEmpty) {
      games.add(currentGame);
    }

    return games;
  }

  /// Generates a meaningful name for the repertoire line
  String _generateLineName(PgnGame game, int index) {
    final event = game.headers['Event'] ?? '';
    final opening = game.headers['Opening'] ?? '';

    if (opening.isNotEmpty && opening != '?') {
      return opening;
    } else if (event.isNotEmpty && event != '?' && event != 'Repertoire Line' && event != 'Edited Line') {
      return event;
    } else {
      // Generate name from first few moves
      final moves = game.moves.mainline().take(3).map((node) => node.san).toList();
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

    return (
      preamble: preambleLines.join('\n').trimRight(),
      games: games,
    );
  }

  /// Extract a stable line identifier, preferring a PGN header if present.
  String _extractLineId(PgnGame game, List<String> moves, int index) {
    final headerId = game.headers['LineID'] ??
        game.headers['LineId'] ??
        game.headers['Id'] ??
        game.headers['Line'] ??
        game.headers['Guid'];

    if (headerId != null && headerId.trim().isNotEmpty) {
      return headerId.trim();
    }

    // Stable fallback based on moves so it persists across sessions.
    return _generateStableLineId(moves, index);
  }

  /// Public access to generate a stable line ID from moves.
  String generateLineId(List<String> moves, int index) =>
      _generateStableLineId(moves, index);

  String _generateStableLineId(List<String> moves, int index) {
    final raw = base64Url.encode(utf8.encode('${moves.join(' ')}|$index'));
    final trimmed = raw.replaceAll('=', '');
    return 'line_${trimmed.length > 22 ? trimmed.substring(0, 22) : trimmed}';
  }

  /// Creates training questions from repertoire lines for a specific color
  List<TrainingQuestion> createTrainingQuestions(
    List<RepertoireLine> lines,
    {String? colorFilter}
  ) {
    final questions = <TrainingQuestion>[];

    for (final line in lines) {
      // Filter by color if specified
      if (colorFilter != null && line.color != colorFilter) {
        continue;
      }

      // Create questions for moves where the training color plays
      for (int moveIndex = 0; moveIndex < line.moves.length; moveIndex++) {
        // Check if this move is played by the training color
        final isWhiteMove = moveIndex % 2 == 0;
        final shouldIncludeMove = (line.color == 'white' && isWhiteMove) ||
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
      filtered = filtered.where((q) => q.moveIndex < 20).toList(); // First 10 moves per side
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
  Future<bool> updateLineTitle(String filePath, String lineId, String newTitle) async {
    final file = io.File(filePath);
    if (!await file.exists()) return false;

    final content = await file.readAsString();
    final document = _splitPgnDocumentPreservingPreamble(content);
    final games = List<String>.from(document.games);

    // Find the game that matches this lineId
    int? matchIndex;
    for (int i = 0; i < games.length; i++) {
      try {
        final game = PgnGame.parsePgn(games[i]);
        final moves = game.moves.mainline().map((n) => n.san).toList();
        final id = _extractLineId(game, moves, i);
        if (id == lineId) {
          matchIndex = i;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    if (matchIndex == null) return false;

    // Replace or insert the [Event] header in the matched game text
    final gameText = games[matchIndex];
    final eventRegex = RegExp(r'\[Event\s+"[^"]*"\]');

    String updatedGame;
    if (eventRegex.hasMatch(gameText)) {
      updatedGame = gameText.replaceFirst(eventRegex, '[Event "$newTitle"]');
    } else {
      // No Event header — prepend one
      updatedGame = '[Event "$newTitle"]\n$gameText';
    }

    games[matchIndex] = updatedGame;

    // Reassemble and write back without dropping top-level metadata.
    final sections = <String>[];
    if (document.preamble.isNotEmpty) {
      sections.add(document.preamble);
    }
    sections.addAll(games);

    await file.writeAsString('${sections.join('\n\n').trimRight()}\n');
    return true;
  }
}
