import 'dart:io';

void main() async {
  print('=== DEBUGGING MOVE MATCHING ISSUE ===');

  final file = File('/var/home/bigman/Documents/imported_games.pgn');
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

  // Extract moves line
  final gameLines = gameContent.split('\n');
  String movesLine = '';
  bool foundMoves = false;

  for (final line in gameLines) {
    if (line.startsWith('1.')) {
      foundMoves = true;
    }
    if (foundMoves && !line.startsWith('[')) {
      movesLine += line + ' ';
    }
  }

  print('First 1000 chars of moves:');
  print(movesLine.substring(0, movesLine.length > 1000 ? 1000 : movesLine.length));

  // Test move extraction patterns exactly like tactics_service.dart
  print('\n=== MOVE EXTRACTION TESTING ===');

  // Extract all moves pattern (from _extractAllMovesFromText)
  String cleanText = movesLine.replaceAll(RegExp(r'\s*(1-0|0-1|1/2-1/2|\*)\s*$'), '');
  final movePattern = RegExp(r'(\d+)\.(\.\.)?\s+([a-h1-8NBRQKO][a-h1-8xO=-]*[+#!?]*(?:=[QRBN])?)');
  final allMoveMatches = movePattern.allMatches(cleanText);

  print('All moves extracted:');
  int count = 0;
  final extractedMoves = <String>[];
  for (final match in allMoveMatches) {
    if (count >= 20) break; // Show first 20
    count++;
    final moveNumber = match.group(1);
    final isBlack = match.group(2) != null;
    final fullMove = match.group(3)!;
    final cleanMove = fullMove.replaceAll(RegExp(r'[+#!?]+$'), '');

    extractedMoves.add(cleanMove);
    print('$count. Move $moveNumber ${isBlack ? 'Black' : 'White'}: "$fullMove" -> clean: "$cleanMove"');
  }

  // Test mistake extraction pattern (from mistake annotations)
  print('\n=== MISTAKE PATTERN TESTING ===');
  final mistakePattern = RegExp(r'(\d+)\.{3}\s*([a-h1-8NBRQKO-]+[+#!?]*)\s*(\{[^}]*?(Mistake|Blunder)[^}]*?\})');
  final mistakeMatches = mistakePattern.allMatches(movesLine);

  final mistakeAnnotations = <String, Map<String, String>>{};
  print('Mistake annotations found:');
  count = 0;
  for (final match in mistakeMatches) {
    if (count >= 5) break; // Show first 5
    count++;
    final moveNumber = match.group(1) ?? '';
    final moveWithSymbols = match.group(2) ?? '';
    final comment = match.group(3) ?? '';
    final mistakeType = comment.contains('Blunder') ? '??' : '?';

    final cleanMove = moveWithSymbols.replaceAll(RegExp(r'[+#!?]+$'), '');
    final key = '$moveNumber...$cleanMove';

    mistakeAnnotations[key] = {
      'type': mistakeType,
      'comment': comment,
      'originalMove': moveWithSymbols,
    };

    print('$count. Move $moveNumber: "$moveWithSymbols" -> clean: "$cleanMove" ($mistakeType)');
    print('   Key: "$key"');
    print('   Comment: ${comment.substring(0, comment.length > 100 ? 100 : comment.length)}...');
    print('');
  }

  // Test matching logic
  print('\n=== MATCHING LOGIC TESTING ===');
  print('Looking for matches between extracted moves and mistake annotations...');

  int fullMoveNumber = 1;
  bool isWhiteTurn = true;

  for (int i = 0; i < extractedMoves.length && i < 40; i++) {
    final cleanMoveSan = extractedMoves[i];
    final currentMoveNumber = fullMoveNumber;
    final moveKey = '$currentMoveNumber...$cleanMoveSan';

    final hasAnnotation = mistakeAnnotations.containsKey(moveKey);

    if (i < 20 || hasAnnotation) { // Show first 20 or any with annotations
      print('Move ${i+1}: "$cleanMoveSan" -> key: "$moveKey" -> ${hasAnnotation ? "HAS ANNOTATION ✓" : "no annotation"}');
    }

    // Update move counters
    if (!isWhiteTurn) {
      fullMoveNumber++;
    }
    isWhiteTurn = !isWhiteTurn;
  }

  print('\nTotal extracted moves: ${extractedMoves.length}');
  print('Total mistake annotations: ${mistakeAnnotations.length}');
  print('Annotation keys: ${mistakeAnnotations.keys.take(10).toList()}');
}