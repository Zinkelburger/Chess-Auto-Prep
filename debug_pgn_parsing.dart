import 'dart:io';

// Simple debugging script to test PGN parsing
void main() async {
  final file = File('/var/home/bigman/Documents/imported_games.pgn');
  if (!await file.exists()) {
    print('File does not exist');
    return;
  }

  final content = await file.readAsString();
  print('File size: ${content.length} characters');

  // Test the game splitting logic
  final gameTexts = splitPgnIntoGames(content);
  print('Split into ${gameTexts.length} games');

  // Check the first game
  if (gameTexts.isNotEmpty) {
    final firstGame = gameTexts.first;
    print('\nFirst game (first 500 chars):');
    print(firstGame.length > 500 ? firstGame.substring(0, 500) : firstGame);

    // Test moves extraction
    final movesSection = extractMovesSection(firstGame);
    print('\nMoves section length: ${movesSection.length}');
    print('Moves section (first 300 chars):');
    print(movesSection.length > 300 ? movesSection.substring(0, 300) : movesSection);

    // Test mistake pattern
    final mistakePattern = RegExp(r'\{[^}]*?(Mistake|Blunder)[^}]*?\}');
    final matches = mistakePattern.allMatches(movesSection);
    print('\nFound ${matches.length} mistake/blunder patterns');

    for (final match in matches) {
      print('Match: ${match.group(0)}');
    }
  }
}

List<String> splitPgnIntoGames(String content) {
  final games = <String>[];
  final lines = content.split('\n');
  var currentGame = <String>[];

  for (final line in lines) {
    if (line.startsWith('[Event ') && currentGame.isNotEmpty) {
      // Start of new game, save previous
      games.add(currentGame.join('\n'));
      currentGame = [line];
    } else {
      currentGame.add(line);
    }
  }

  // Don't forget the last game
  if (currentGame.isNotEmpty) {
    games.add(currentGame.join('\n'));
  }

  return games;
}

String extractMovesSection(String gameText) {
  // Find everything after the headers - look for the end of the last header line
  // Headers are like [Key "Value"] so we need to find where headers end
  final lines = gameText.split('\n');
  int lastHeaderLine = -1;

  for (int i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      lastHeaderLine = i;
    } else if (line.isNotEmpty && !line.startsWith('[')) {
      // First non-header, non-empty line
      break;
    }
  }

  if (lastHeaderLine == -1) {
    print('No headers found in game text');
    return '';
  }

  // Take everything after the last header line
  final moveLines = lines.skip(lastHeaderLine + 1);
  final movesSection = moveLines.join('\n').trim();
  return movesSection;
}