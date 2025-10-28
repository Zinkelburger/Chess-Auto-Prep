import 'dart:io' as io;
import 'package:dartchess/dartchess.dart';

void main() async {
  print('=== TESTING DARTCHESS PGN PARSING ===');

  final file = io.File('/var/home/bigman/Documents/imported_games.pgn');
  final content = await file.readAsString();

  // Get first game that has BigManArkhangelsk as a player
  final lines = content.split('\n');
  String gameContent = '';
  bool inGame = false;
  bool foundUser = false;

  for (final line in lines) {
    if (line.startsWith('[')) {
      if (line.toLowerCase().contains('bigmanarkhangelsk')) {
        foundUser = true;
      }
    }

    if (line.startsWith('[Event')) {
      if (foundUser && inGame) break;
      inGame = true;
      gameContent = '';
      foundUser = false;
    }

    if (inGame) {
      gameContent += line + '\n';
    }
  }

  if (!foundUser) {
    print('ERROR: No game found');
    return;
  }

  print('Sample game content (first 800 chars):');
  print(gameContent.substring(0, gameContent.length > 800 ? 800 : gameContent.length));

  try {
    // Parse with dartchess
    print('\n=== TESTING DARTCHESS PARSING ===');

    final game = PgnGame.parsePgn(gameContent);
    print('Successfully parsed PGN!');
    print('Headers: ${game.headers}');
    print('White: ${game.headers['White']}');
    print('Black: ${game.headers['Black']}');

    // Walk through moves like Python does
    print('\n=== WALKING THROUGH MOVES ===');
    Position position = Chess.initial;

    void walkMoves(PgnNode<PgnNodeData> node, int depth) {
      if (depth > 20) return; // Limit depth for testing

      for (final child in node.children) {
        final moveNumber = position.fullmoves;
        final isWhite = position.turn == Side.white;
        final san = child.data.san;

        print('Move $moveNumber ${isWhite ? 'White' : 'Black'}: $san');

        // Check for comments (this is where mistakes would be)
        if (child.data.comments != null && child.data.comments!.isNotEmpty) {
          for (final comment in child.data.comments!) {
            if (comment.contains('Mistake') || comment.contains('Blunder')) {
              print('  -> MISTAKE: $comment');

              // Check for variations (correct moves)
              if (child.children.isNotEmpty) {
                print('  -> Has ${child.children.length} variations:');
                for (final variation in child.children) {
                  print('     ${variation.data.san}');
                }
              }
            }
          }
        }

        // Make the move
        final move = position.parseSan(san);
        if (move != null) {
          position = position.play(move);
          print('     Position after: ${position.fen.substring(0, 20)}...');

          // Recursively walk variations
          walkMoves(child, depth + 1);
        } else {
          print('     Failed to parse move: $san');
          break;
        }
      }
    }

    walkMoves(game.moves, 0);

  } catch (e) {
    print('Error parsing with dartchess: $e');
    print('Error type: ${e.runtimeType}');
  }
}