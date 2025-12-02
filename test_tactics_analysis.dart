// Test script to trace the tactics analysis flow
// Run with: dart run test_tactics_analysis.dart

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;

// Win% formula from Lichess
double calculateWinChance(int centipawns) {
  return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * centipawns)) - 1);
}

void main() async {
  print('=== TACTICS ANALYSIS TEST ===\n');
  
  // Step 1: Download a game from Lichess
  final username = 'DrNykterstein'; // Magnus Carlsen's Lichess account
  print('Step 1: Downloading 1 game from Lichess for user: $username');
  
  final url = Uri.parse('https://lichess.org/api/games/user/$username?max=1&evals=false&clocks=false&opening=false&moves=true');
  
  final response = await http.get(url, headers: {'Accept': 'application/x-chess-pgn'});
  
  if (response.statusCode != 200) {
    print('Failed to download: ${response.statusCode}');
    exit(1);
  }
  
  final pgn = response.body;
  print('\n--- RAW PGN DOWNLOADED ---');
  print(pgn);
  print('--- END PGN ---\n');
  
  // Step 2: Parse the PGN to extract moves
  print('Step 2: Parsing PGN...');
  
  // Extract headers
  final headerRegex = RegExp(r'\[(\w+)\s+"([^"]+)"\]');
  final headers = <String, String>{};
  for (final match in headerRegex.allMatches(pgn)) {
    headers[match.group(1)!] = match.group(2)!;
  }
  
  print('Headers found:');
  headers.forEach((k, v) => print('  $k: $v'));
  
  // Extract moves - find the line after all headers (the move text)
  final lines = pgn.split('\n');
  String moveText = '';
  bool pastHeaders = false;
  for (final line in lines) {
    if (line.trim().isEmpty && !pastHeaders) {
      pastHeaders = true;
      continue;
    }
    if (pastHeaders && line.trim().isNotEmpty) {
      moveText += line + ' ';
    }
  }
  
  print('\nMove text: $moveText');
  
  // Parse SAN moves (simplified - just get the moves without annotations)
  // Match: move number (optional), then the actual move
  final moveRegex = RegExp(r'(?:\d+\.+\s*)?([KQRBN]?[a-h]?[1-8]?x?[a-h][1-8](?:=[QRBN])?[+#]?|O-O-O|O-O)');
  final moves = <String>[];
  for (final match in moveRegex.allMatches(moveText)) {
    final move = match.group(1)!;
    if (move.isNotEmpty) {
      moves.add(move);
    }
  }
  
  print('\nParsed ${moves.length} moves:');
  for (int i = 0; i < moves.length; i++) {
    final moveNum = (i ~/ 2) + 1;
    final isWhite = i % 2 == 0;
    if (isWhite) {
      stdout.write('$moveNum. ${moves[i]} ');
    } else {
      stdout.write('${moves[i]} ');
    }
  }
  print('\n');
  
  // Step 3: Now let's trace what Stockfish analysis WOULD do
  print('\n=== STOCKFISH ANALYSIS TRACE ===');
  print('(This is what the TacticsImportService does)\n');
  
  // Determine user side
  final white = headers['White']?.toLowerCase() ?? '';
  final black = headers['Black']?.toLowerCase() ?? '';
  final usernameLower = username.toLowerCase();
  
  String userSide;
  if (white.contains(usernameLower)) {
    userSide = 'white';
  } else if (black.contains(usernameLower)) {
    userSide = 'black';
  } else {
    print('User not found in game!');
    exit(1);
  }
  
  print('User ($username) is playing as: $userSide');
  print('\nFor each move where it\'s the user\'s turn:');
  print('  1. Get evaluation BEFORE the move (Position A)');
  print('  2. Make the move');
  print('  3. Get evaluation AFTER the move (Position B)');
  print('  4. Calculate Win% delta');
  print('  5. If delta > 30%, it\'s a BLUNDER\n');
  
  // Simulate the analysis loop
  bool isWhiteTurn = true;
  int moveNumber = 1;
  
  print('--- ANALYSIS LOOP (first 10 user moves for demo) ---');
  int userMoveCount = 0;
  for (int i = 0; i < moves.length && userMoveCount < 10; i++) {
    final san = moves[i];
    final isUserTurn = (userSide == 'white' && isWhiteTurn) || 
                       (userSide == 'black' && !isWhiteTurn);
    
    if (isUserTurn) {
      userMoveCount++;
      print('\nMove $moveNumber${isWhiteTurn ? '.' : '...'} $san (USER\'S TURN)');
      print('  -> Would call: stockfish.getEvaluation(currentFEN, depth: 12)');
      print('  -> Get evalA (e.g., score cp +20, pv [Nf6, e4, ...])');
      print('  -> Make move $san');
      print('  -> Would call: stockfish.getEvaluation(newFEN, depth: 12)');
      print('  -> Get evalB (e.g., score cp +15, pv [e4, Nc6, ...])');
      print('  -> Calculate: winChanceA(+20) - winChanceB(-15) = ${calculateWinChance(20).toStringAsFixed(1)}% - ${calculateWinChance(-15).toStringAsFixed(1)}% = ${(calculateWinChance(20) - calculateWinChance(-15)).toStringAsFixed(1)}%');
      print('  -> Delta ${(calculateWinChance(20) - calculateWinChance(-15)).toStringAsFixed(1)}% < 30% => Not a blunder');
    } else {
      print('\nMove $moveNumber${isWhiteTurn ? '.' : '...'} $san (opponent\'s turn - skip analysis)');
    }
    
    // Toggle turn
    isWhiteTurn = !isWhiteTurn;
    if (isWhiteTurn) moveNumber++;
  }
  
  print('\n=== WHAT THE STOCKFISH SERVICE DOES ===');
  print('''
1. getEvaluation(fen, depth: 12) is called
2. It sends to Stockfish process:
   - "stop"                    (stop any previous analysis)
   - "position fen <FEN>"      (set the position)
   - "go depth 12"             (analyze to depth 12)
3. Stockfish outputs lines like:
   - "info depth 1 score cp 25 pv e2e4 ..."
   - "info depth 2 score cp 30 pv e2e4 e7e5 ..."
   - ... (continues until depth 12)
   - "bestmove e2e4 ponder e7e5"
4. When "bestmove" is received, the analysis is complete
5. The service returns EngineEvaluation with:
   - scoreCp: centipawn score (e.g., +30 = 0.30 pawns advantage)
   - scoreMate: mate in N (if applicable)
   - pv: principal variation (best line of moves in UCI format)
''');

  print('\n=== WIN% CALCULATION ===');
  print('Formula: Win% = 50 + 50 * (2 / (1 + exp(-0.00368208 * centipawns)) - 1)');
  print('\nExamples:');
  for (final cp in [0, 50, 100, 200, 300, 500, 1000]) {
    final winPct = calculateWinChance(cp);
    print('  +$cp cp -> ${winPct.toStringAsFixed(1)}% win chance');
  }
  print('\nBlunder detection:');
  print('  If Win% drops from 70% to 35%, delta = 35% > 30% => BLUNDER!');
  
  print('\n=== THE ISSUE ===');
  print('''
The current code is STUCK because:

1. StockfishService.getEvaluation() sends "go depth 12" to Stockfish
2. It waits for a "bestmove" response via a Completer
3. BUT the engine might not be ready yet (isReady.value == false)
4. Or the engine output stream isn't being processed correctly

Let me check if the engine is actually responding...
''');

  // Try to actually run stockfish and see what happens
  print('\n=== TESTING ACTUAL STOCKFISH ===');
  final stockfishPath = '/home/anbernal/.local/share/com.example.chess_auto_prep/stockfish-linux';
  
  if (!File(stockfishPath).existsSync()) {
    print('Stockfish binary not found at: $stockfishPath');
    print('Run the Flutter app first to extract it.');
    exit(1);
  }
  
  print('Found Stockfish at: $stockfishPath');
  print('Starting Stockfish process...\n');
  
  final process = await Process.start(stockfishPath, []);
  
  // Listen to stdout
  process.stdout.transform(const SystemEncoding().decoder).listen((data) {
    print('STOCKFISH OUT: $data');
  });
  
  // Listen to stderr
  process.stderr.transform(const SystemEncoding().decoder).listen((data) {
    print('STOCKFISH ERR: $data');
  });
  
  // Send commands
  print('Sending: uci');
  process.stdin.writeln('uci');
  await Future.delayed(Duration(milliseconds: 500));
  
  print('\nSending: setoption name Threads value 4');
  process.stdin.writeln('setoption name Threads value 4');
  
  print('Sending: isready');
  process.stdin.writeln('isready');
  await Future.delayed(Duration(milliseconds: 500));
  
  print('\nSending: position startpos');
  process.stdin.writeln('position startpos');
  
  print('Sending: go depth 10');
  process.stdin.writeln('go depth 10');
  
  // Wait for analysis
  await Future.delayed(Duration(seconds: 3));
  
  print('\nSending: quit');
  process.stdin.writeln('quit');
  
  await process.exitCode;
  print('\n=== STOCKFISH TEST COMPLETE ===');
}
