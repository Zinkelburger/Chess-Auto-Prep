import 'dart:io' as io;
import 'package:dartchess/dartchess.dart';

void main() async {
  print('=== TESTING PGN PARSING CAPABILITIES ===');

  final file = io.File('/var/home/bigman/Documents/imported_games.pgn');
  final content = await file.readAsString();

  // Test dartchess PGN parsing
  print('\n1. Testing dartchess package:');
  try {
    final position = Chess.initial;
    print('Initial position created: ${position.fen}');
    print('Position type: ${position.runtimeType}');
  } catch (e) {
    print('Error with dartchess package: $e');
  }

  print('\n2. Checking PGN content:');
  try {
    final lines = content.split('\n');
    final firstGame = lines.take(50).join('\n');
    print('Sample PGN (first 500 chars):');
    print(firstGame.substring(0, firstGame.length > 500 ? 500 : firstGame.length));
  } catch (e) {
    print('Error reading PGN: $e');
  }
}
