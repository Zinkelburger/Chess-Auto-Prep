import 'dart:io';

void main() async {
  print('=== DEBUGGING MOVE STRIPPING ===');

  final file = File('/var/home/bigman/Documents/imported_games.pgn');
  final content = await file.readAsString();

  // Get first game and extract moves
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

  print('First 800 chars of moves:');
  print(movesLine.substring(0, movesLine.length > 800 ? 800 : movesLine.length));

  // Test move extraction patterns
  print('\n=== TESTING MOVE EXTRACTION ===');
  final movePattern = RegExp(r'(\d+)\.(\.\.)?\s+([a-h1-8NBRQKO][a-h1-8xO=-]*[+#!?]*(?:=[QRBN])?)');
  final matches = movePattern.allMatches(movesLine);

  print('\nFirst 15 extracted moves with their original form:');
  int count = 0;
  for (final match in matches) {
    if (count >= 15) break;
    count++;
    final moveNumber = match.group(1);
    final isBlack = match.group(2) != null;
    final originalMove = match.group(3)!;

    // Test different stripping approaches
    final stripAll = originalMove.replaceAll(RegExp(r'[+#!?]+$'), '');
    final stripOnlyMistake = originalMove.replaceAll(RegExp(r'[!?]+$'), ''); // Keep + and #
    final noStrip = originalMove;

    print('$count. Move $moveNumber ${isBlack ? 'Black' : 'White'}:');
    print('   Original: "$originalMove"');
    print('   Strip all: "$stripAll"');
    print('   Strip mistakes only: "$stripOnlyMistake"');
    print('   No strip: "$noStrip"');

    // Test which chess notation patterns match
    if (RegExp(r'^[a-h][1-8]$').hasMatch(stripAll)) print('   -> Pawn move');
    else if (RegExp(r'^[NBRQK][a-h1-8]*[+#]?$').hasMatch(stripAll)) print('   -> Piece move (stripped)');
    else if (RegExp(r'^[NBRQK][a-h1-8]*[+#]?$').hasMatch(stripOnlyMistake)) print('   -> Piece move (mistakes only)');
    else if (RegExp(r'^[NBRQK][a-h1-8]*[+#]?$').hasMatch(noStrip)) print('   -> Piece move (no strip)');
    else if (stripAll == 'O-O' || stripAll == 'O-O-O') print('   -> Castling');
    else print('   -> UNRECOGNIZED');

    print('');
  }

  // Test mistake pattern matching
  print('\n=== TESTING MISTAKE PATTERNS ===');
  final mistakePattern = RegExp(r'(\d+)\.{3}\s*([a-h1-8NBRQKO-]+[+#!?]*)\s*(\{[^}]*?(Mistake|Blunder)[^}]*?\})');
  final mistakeMatches = mistakePattern.allMatches(movesLine);

  print('First 5 mistake patterns:');
  count = 0;
  for (final match in mistakeMatches) {
    if (count >= 5) break;
    count++;
    final moveNumber = match.group(1);
    final move = match.group(2);
    final comment = match.group(3);
    final type = comment?.contains('Blunder') == true ? 'Blunder' : 'Mistake';

    print('$count. Move $moveNumber: "$move" ($type)');
    print('   Comment: ${comment?.substring(0, comment.length > 100 ? 100 : comment.length)}...');

    final cleanMove = move?.replaceAll(RegExp(r'[+#!?]+$'), '') ?? '';
    final keepCheckMate = move?.replaceAll(RegExp(r'[!?]+$'), '') ?? '';

    print('   Cleaned: "$cleanMove"');
    print('   Keep +#: "$keepCheckMate"');
    print('');
  }
}