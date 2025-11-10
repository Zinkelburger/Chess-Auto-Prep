/// Repertoire parsing and training service
/// Extracts trainable lines from PGN files and manages training sessions
library;

import 'package:dartchess/dartchess.dart';
import 'dart:io' as io;
import '../models/repertoire_line.dart';

class RepertoireService {
  /// Parses a repertoire PGN file and extracts all trainable lines
  Future<List<RepertoireLine>> parseRepertoireFile(String filePath) async {
    final file = io.File(filePath);
    if (!(await file.exists())) {
      throw Exception('Repertoire file not found: $filePath');
    }

    final content = await file.readAsString();
    return parseRepertoirePgn(content);
  }

  /// Parses repertoire PGN content and extracts trainable lines
  List<RepertoireLine> parseRepertoirePgn(String pgnContent) {
    final lines = <RepertoireLine>[];

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

        // Determine which color this line trains based on the first move
        // If first move is White's, this trains Black responses (and vice versa)
        // Actually, we need to determine from headers or make configurable
        final whitePlayer = game.headers['White'] ?? '';
        final blackPlayer = game.headers['Black'] ?? '';

        // For now, determine training color based on player names
        // If "Me" or similar is Black, we train Black
        String trainingColor;
        if (blackPlayer.toLowerCase().contains('me') ||
            blackPlayer.toLowerCase().contains('repertoire') ||
            blackPlayer.toLowerCase().contains('training')) {
          trainingColor = 'black';
        } else if (whitePlayer.toLowerCase().contains('me') ||
                   whitePlayer.toLowerCase().contains('repertoire') ||
                   whitePlayer.toLowerCase().contains('training')) {
          trainingColor = 'white';
        } else {
          // Default: if the line starts with 1.e4, train Black responses
          trainingColor = 'black';
        }

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

        // Extract variations (not implemented for training yet, but for reference)
        final variations = <String>[];
        _extractVariations(game.moves, variations);

        // Create the repertoire line
        final lineName = _generateLineName(game, gameIndex);
        final lineId = '${lineName.toLowerCase().replaceAll(' ', '_')}_$gameIndex';

        lines.add(RepertoireLine(
          id: lineId,
          name: lineName,
          moves: mainlineMoves,
          color: trainingColor,
          startPosition: Chess.initial,
          fullPgn: gameText,
          comments: comments,
          variations: variations,
        ));

      } catch (e) {
        print('Error parsing game $gameIndex: $e');
        continue;
      }
    }

    return lines;
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

    if (opening.isNotEmpty) {
      return opening;
    } else if (event.isNotEmpty && event != 'Repertoire Line') {
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
  void _extractVariations(PgnNode moves, List<String> variations) {
    // This is a simplified extraction - real implementation would be more complex
    // For now, we'll just note that variations exist
    if (moves.children.isNotEmpty) {
      variations.add('Variations available'); // Placeholder
    }
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
            print('Error creating training question for ${line.name} move $moveIndex: $e');
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
}