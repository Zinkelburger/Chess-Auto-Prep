import 'dart:io';
import 'package:chess/chess.dart' as chess_lib;
import 'package:dartchess_webok/dartchess_webok.dart' as dartchess;

void main() async {
  print('=== TESTING PGN PARSING CAPABILITIES ===');

  final file = File('/var/home/bigman/Documents/imported_games.pgn');
  final content = await file.readAsString();

  // Test if chess package has PGN parsing
  print('\n1. Testing chess package:');
  try {
    final chess = chess_lib.Chess();

    // Check available methods
    print('Chess object created successfully');
    print('Available methods: toString, ascii, clear, fen, pgn, history, etc.');

    // Try to load PGN
    if (chess.toString().contains('pgn')) {
      print('PGN method exists on Chess object');

      // Try to see what pgn() returns
      final currentPgn = chess.pgn();
      print('Current PGN: $currentPgn');

      // Check if there's a loadPgn method
      final chessMethods = chess.runtimeType.toString();
      print('Chess type: $chessMethods');
    }

  } catch (e) {
    print('Error with chess package: $e');
  }

  // Test dartchess package
  print('\n2. Testing dartchess package:');
  try {
    // Check what classes are available in dartchess
    print('Available dartchess classes: Position, Game, Move, etc.');

    // Try to create a position
    final position = dartchess.Chess.initial;
    print('Initial position created: ${position.fen}');

    // Check if there's PGN functionality
    print('Position type: ${position.runtimeType}');

  } catch (e) {
    print('Error with dartchess package: $e');
  }

  // Let's see what we can import
  print('\n3. Checking import capabilities:');

  // Try to find PGN-related functionality
  try {
    // Get a small sample of PGN
    final lines = content.split('\n');
    final firstGame = lines.take(50).join('\n');

    print('Sample PGN (first 500 chars):');
    print(firstGame.substring(0, firstGame.length > 500 ? 500 : firstGame.length));

  } catch (e) {
    print('Error reading PGN: $e');
  }
}