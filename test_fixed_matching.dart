import 'dart:io';

void main() async {
  print('=== TESTING FIXED MOVE MATCHING ===');

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

  // Test mistake extraction pattern
  final mistakePattern = RegExp(r'(\d+)\.{3}\s*([a-h1-8NBRQKO-]+[+#!?]*)\s*(\{[^}]*?(Mistake|Blunder)[^}]*?\})');
  final mistakeMatches = mistakePattern.allMatches(movesLine);

  final mistakeAnnotations = <String, Map<String, String>>{};
  print('Mistake annotations found:');
  for (final match in mistakeMatches) {
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

    print('Move $moveNumber: "$moveWithSymbols" -> clean: "$cleanMove" ($mistakeType)');
    print('  Key: "$key"');
  }

  // Extract all moves with FIXED key generation
  String cleanText = movesLine.replaceAll(RegExp(r'\s*(1-0|0-1|1/2-1/2|\*)\s*$'), '');
  final movePattern = RegExp(r'(\d+)\.(\.\.)?\s+([a-h1-8NBRQKO][a-h1-8xO=-]*[+#!?]*(?:=[QRBN])?)');
  final allMoveMatches = movePattern.allMatches(cleanText);

  print('\n=== TESTING FIXED KEY GENERATION ===');

  int fullMoveNumber = 1;
  bool isWhiteTurn = true;
  int matchCount = 0;

  for (final match in allMoveMatches) {
    final moveNumber = match.group(1);
    final isBlack = match.group(2) != null;
    final fullMove = match.group(3)!;
    final cleanMove = fullMove.replaceAll(RegExp(r'[+#!?]+$'), '');

    // CORRECTED key generation
    final correctKey = isWhiteTurn
        ? '$fullMoveNumber.$cleanMove'
        : '$fullMoveNumber...$cleanMove';

    final hasAnnotation = mistakeAnnotations.containsKey(correctKey);

    print('Move $moveNumber ${isWhiteTurn ? 'White' : 'Black'}: "$fullMove" -> key: "$correctKey" ${hasAnnotation ? "✓ MATCH!" : ""}');

    if (hasAnnotation) {
      matchCount++;
      final annotation = mistakeAnnotations[correctKey]!;
      print('  -> FOUND MISTAKE: ${annotation['type']} - ${annotation['comment']?.substring(0, 80)}...');
    }

    // Update counters
    if (!isWhiteTurn) {
      fullMoveNumber++;
    }
    isWhiteTurn = !isWhiteTurn;

    if (fullMoveNumber > 35) break; // Stop after move 35 to keep output manageable
  }

  print('\nSummary:');
  print('Total mistake annotations: ${mistakeAnnotations.length}');
  print('Matches found with fixed keys: $matchCount');
  print('Annotation keys: ${mistakeAnnotations.keys.toList()}');
}