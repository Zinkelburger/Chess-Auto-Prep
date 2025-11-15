import 'dart:io' as io;
import 'package:dartchess_webok/dartchess_webok.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/tactics_position.dart';

class TacticsService {
  /// Extract tactical positions using proper PGN parsing (Python approach)
  Future<List<TacticsPosition>> generateTacticsFromLichess(String username) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = io.File('${directory.path}/imported_games.pgn');

    if (!await file.exists()) {
      throw Exception('No imported games found. Please import games first.');
    }

    if (kDebugMode) {
      print('Parsing PGN with dartchess (Python approach)');
    }

    final content = await file.readAsString();
    final allPositions = <TacticsPosition>[];

    // Split into individual games
    final games = _splitPgnIntoGames(content);

    if (kDebugMode) {
      print('Found ${games.length} games in PGN file');
    }

    int gameCount = 0;
    for (final gameText in games) {
      gameCount++;
      try {
        final positions = await _extractPositionsFromGame(gameText, username);
        allPositions.addAll(positions);

        if (kDebugMode && positions.isNotEmpty) {
          print('Game $gameCount: Found ${positions.length} tactical positions');
        }
      } catch (e) {
        if (kDebugMode) {
          print('Error parsing game $gameCount: $e');
        }
        continue;
      }
    }

    if (kDebugMode) {
      print('Total tactical positions found: ${allPositions.length}');
    }

    // Save to CSV
    await _saveTacticsToCSV(allPositions);

    return allPositions;
  }

  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');

    String currentGame = '';
    bool inGame = false;

    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && currentGame.isNotEmpty) {
          games.add(currentGame);
        }
        currentGame = line + '\n';
        inGame = true;
      } else if (inGame) {
        currentGame += line + '\n';
      }
    }

    if (inGame && currentGame.isNotEmpty) {
      games.add(currentGame);
    }

    return games;
  }

  Future<List<TacticsPosition>> _extractPositionsFromGame(String gameText, String username) async {
    final positions = <TacticsPosition>[];

    try {
      // Parse PGN with dartchess (like Python's chess.pgn.read_game)
      final game = PgnGame.parsePgn(gameText);

      // Check if user is in this game
      final white = game.headers['White']?.toLowerCase() ?? '';
      final black = game.headers['Black']?.toLowerCase() ?? '';
      final usernameLower = username.toLowerCase();

      Side? userSide;
      if (white.contains(usernameLower)) {
        userSide = Side.white;
      } else if (black.contains(usernameLower)) {
        userSide = Side.black;
      } else {
        return positions; // User not in this game
      }

      if (kDebugMode) {
        print('Found user $username as ${userSide == Side.white ? 'white' : 'black'} in game: $white vs $black');
      }

      // PYTHON APPROACH: Walk through the move tree like Python does
      Position position = Chess.initial;

      void walkMoves(PgnNode<PgnNodeData> node, int moveNumber) {
        for (final child in node.children) {
          final isUserMove = position.turn == userSide;
          final san = child.data.san;

          // Check for mistake comments BEFORE making the move (Python approach)
          if (isUserMove && child.data.comments != null) {
            for (final comment in child.data.comments!) {
              if (comment.contains('Mistake') || comment.contains('Blunder')) {
                // Found a mistake! Get FEN BEFORE the mistake (Python: board.fen())
                final fenBeforeMistake = position.fen;
                final mistakeType = comment.contains('Blunder') ? '??' : '?';

                // Extract correct line from PGN variations (like Python does)
                final correctLine = _extractCorrectLineFromVariations(node, position, moveNumber);

                final tacticsPosition = TacticsPosition(
                  fen: fenBeforeMistake,
                  userMove: san,
                  correctLine: correctLine,
                  mistakeType: mistakeType,
                  mistakeAnalysis: comment,
                  positionContext: 'Move $moveNumber, ${userSide == Side.white ? 'White' : 'Black'} to play',
                  gameWhite: game.headers['White'] ?? '',
                  gameBlack: game.headers['Black'] ?? '',
                  gameResult: game.headers['Result'] ?? '*',
                  gameDate: game.headers['Date'] ?? '',
                  gameId: game.headers['GameId'] ?? game.headers['Site']?.split('/').last ?? '',
                );

                positions.add(tacticsPosition);

                if (kDebugMode) {
                  print('Found tactical position: $mistakeType at move $moveNumber');
                  print('FEN: $fenBeforeMistake');
                  print('User move: $san');
                  print('Correct line: ${correctLine.join(' ')}');
                }
              }
            }
          }

          // Make the move (Python: board.push(move))
          final move = position.parseSan(san);
          if (move != null) {
            position = position.play(move);

            // Continue walking through variations/children
            walkMoves(child, position.fullmoves);
          } else {
            if (kDebugMode) {
              print('=== MOVE PARSING FAILURE ===');
              print('Game: ${game.headers['White'] ?? 'Unknown'} vs ${game.headers['Black'] ?? 'Unknown'}');
              print('Current FEN: ${position.fen}');
              print('Failed to parse move: $san');
              print('Raw move before regex removal: $san');
              print('============================');
            }
            break;
          }
        }
      }

      // Start the walk (Python: node = game, while node.variations)
      walkMoves(game.moves, 1);

    } catch (e) {
      if (kDebugMode) {
        print('Error parsing game with dartchess: $e');
      }
      rethrow;
    }

    return positions;
  }


  List<String> _extractCorrectLineFromVariations(PgnNode<PgnNodeData> parentNode, Position currentBoard, int currentMoveNumber) {
    // Extract correct line from PGN variations structure, like Python implementation
    // The Python code looks for node.variations[1] which contains the correct variation
    final correctLine = <String>[];

    try {
      if (kDebugMode) {
        print('=== EXTRACTING CORRECT LINE FROM VARIATIONS ===');
        print('Parent node has ${parentNode.children.length} children (variations)');
        print('Current move number: $currentMoveNumber, turn: ${currentBoard.turn}');
      }

      // Check if parent node has multiple variations (mistake move + correct alternative)
      if (parentNode.children.length > 1) {
        // Get the correct variation (second variation after the mistake)
        // In Python: node.variations[1] contains the correct line
        final correctVariation = parentNode.children[1];

        if (kDebugMode) {
          print('Found correct variation: ${correctVariation.data.san}');
        }

        // Traverse this variation to get up to 3 moves
        var currentNodeInVar = correctVariation;
        var boardCopy = currentBoard;
        var moveNumber = currentMoveNumber;
        var isWhiteToMove = currentBoard.turn == Side.white;

        while (currentNodeInVar.children.isNotEmpty && correctLine.length < 3) {
          // Get SAN notation for this move
          final san = currentNodeInVar.data.san;
          final move = boardCopy.parseSan(san);

          if (move != null) {
            // Format move with proper numbering
            String formattedMove;
            if (isWhiteToMove) {
              formattedMove = '$moveNumber. $san';
            } else {
              formattedMove = '$moveNumber... $san';
            }

            correctLine.add(formattedMove);
            boardCopy = boardCopy.play(move);

            if (kDebugMode) {
              print('Added move to correct line: $formattedMove');
            }

            // Update move tracking
            if (!isWhiteToMove) {
              moveNumber++;
            }
            isWhiteToMove = !isWhiteToMove;

            // Move to next node in this variation (main line of the variation)
            if (currentNodeInVar.children.isNotEmpty) {
              currentNodeInVar = currentNodeInVar.children.first;
            } else {
              break;
            }
          } else {
            if (kDebugMode) {
              print('Failed to parse move: $san');
            }
            break;
          }
        }
      }

      // If no correct line found from variations, fall back to comment parsing
      if (correctLine.isEmpty) {
        if (kDebugMode) {
          print('No variations found, falling back to comment parsing');
        }
        correctLine.addAll(_extractCorrectLineFromComments(parentNode.children.firstOrNull?.data.comments, currentMoveNumber, currentBoard.turn == Side.white));
      }

      if (kDebugMode) {
        print('Final extracted correct line: $correctLine');
        print('==============================================');
      }

    } catch (e) {
      if (kDebugMode) {
        print('Error extracting correct line from variations: $e');
        print('Falling back to comment parsing');
      }
      // Fallback to comment parsing on error
      correctLine.addAll(_extractCorrectLineFromComments(parentNode.children.firstOrNull?.data.comments, currentMoveNumber, currentBoard.turn == Side.white));
    }

    return correctLine;
  }

  List<String> _extractCorrectLineFromComments(List<String>? comments, int moveNumber, bool isWhiteToMove) {
    // Fallback method: extract correct moves from comments using regex
    final correctLine = <String>[];

    if (comments != null) {
      for (final comment in comments) {
        // Match chess moves which can include +, #, =Q, etc.
        final match = RegExp(r'([A-Za-z0-9+#=\-]+) was best').firstMatch(comment);
        if (match != null) {
          final san = match.group(1)!;
          // Format with proper move numbering
          String formattedMove;
          if (isWhiteToMove) {
            formattedMove = '$moveNumber. $san';
          } else {
            formattedMove = '$moveNumber... $san';
          }
          correctLine.add(formattedMove);
          break;
        }
      }
    }

    return correctLine;
  }

  Future<void> _saveTacticsToCSV(List<TacticsPosition> positions) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = io.File('${directory.path}/tactics_positions.csv');

    final lines = <String>[];
    lines.add('fen,user_move,correct_line,best_move,mistake_type,mistake_analysis,position_context,game_white,game_black,game_result,game_date,game_id');

    for (final pos in positions) {
      final line = [
        '"${pos.fen}"',
        '"${pos.userMove}"',
        '"${pos.correctLine.join(' ')}"',
        '"${pos.bestMove}"',
        '"${pos.mistakeType}"',
        '"${pos.mistakeAnalysis.replaceAll('"', '""')}"',
        '"${pos.positionContext}"',
        '"${pos.gameWhite}"',
        '"${pos.gameBlack}"',
        '"${pos.gameResult}"',
        '"${pos.gameDate}"',
        '"${pos.gameId}"',
      ].join(',');
      lines.add(line);
    }

    await file.writeAsString(lines.join('\n'));

    if (kDebugMode) {
      print('Saved ${positions.length} positions to ${file.path}');
    }
  }
}