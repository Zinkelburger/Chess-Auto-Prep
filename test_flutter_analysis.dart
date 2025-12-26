// Standalone Dart test script for tactics analysis comparison
// Run with: dart run test_flutter_analysis.dart
//
// This uses the same logic as TacticsImportService but outputs detailed logs
// for comparison with the JavaScript version.

import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:chess/chess.dart' as chess;

// Win% formula (same as Flutter and JS)
double calculateWinChance(int centipawns) {
  return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * centipawns)) - 1);
}

// Simple UCI engine wrapper for desktop Stockfish
class SimpleStockfish {
  late Process _process;
  bool _ready = false;
  
  Future<void> init() async {
    // Try to find stockfish
    final stockfishPath = await _findStockfish();
    if (stockfishPath == null) {
      throw Exception('Stockfish not found. Install it with: sudo dnf install stockfish');
    }
    
    _process = await Process.start(stockfishPath, []);
    
    // Listen for readyok
    _process.stdout.transform(const SystemEncoding().decoder).listen((line) {
      // Handle in getEvaluation
    });
    
    _process.stdin.writeln('uci');
    await Future.delayed(const Duration(milliseconds: 500));
    _process.stdin.writeln('isready');
    await Future.delayed(const Duration(milliseconds: 500));
    _ready = true;
    print('[Stockfish] Ready');
  }
  
  Future<String?> _findStockfish() async {
    final paths = [
      '/usr/bin/stockfish',
      '/usr/local/bin/stockfish',
      'stockfish',
    ];
    
    for (final path in paths) {
      try {
        final result = await Process.run('which', [path]);
        if (result.exitCode == 0) {
          return result.stdout.toString().trim();
        }
      } catch (e) {
        // Try next
      }
      
      if (await File(path).exists()) {
        return path;
      }
    }
    
    // Try 'which stockfish'
    try {
      final result = await Process.run('which', ['stockfish']);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
    } catch (e) {
      // Not found
    }
    
    return null;
  }
  
  Future<Map<String, dynamic>> getEvaluation(String fen, {int depth = 15}) async {
    if (!_ready) throw Exception('Engine not ready');
    
    final isWhiteTurn = fen.split(' ')[1] == 'w';
    
    _process.stdin.writeln('ucinewgame');
    _process.stdin.writeln('position fen $fen');
    _process.stdin.writeln('go depth $depth');
    
    int? scoreCp;
    int? scoreMate;
    List<String> pv = [];
    
    // Read output until bestmove
    await for (final line in _process.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter())) {
      if (line.startsWith('info depth') && line.contains(' pv ')) {
        // Parse score
        final cpMatch = RegExp(r'score cp (-?\d+)').firstMatch(line);
        final mateMatch = RegExp(r'score mate (-?\d+)').firstMatch(line);
        final pvMatch = RegExp(r' pv (.+)').firstMatch(line);
        
        if (cpMatch != null) {
          int rawCp = int.parse(cpMatch.group(1)!);
          // Normalize to White's perspective (like Flutter StockfishService)
          scoreCp = isWhiteTurn ? rawCp : -rawCp;
        } else if (mateMatch != null) {
          int rawMate = int.parse(mateMatch.group(1)!);
          scoreMate = isWhiteTurn ? rawMate : -rawMate;
        }
        
        if (pvMatch != null) {
          pv = pvMatch.group(1)!.split(' ');
        }
      }
      
      if (line.startsWith('bestmove')) {
        break;
      }
    }
    
    // Calculate effective centipawns
    int effectiveCp;
    if (scoreMate != null) {
      effectiveCp = scoreMate > 0 ? 10000 : -10000;
    } else {
      effectiveCp = scoreCp ?? 0;
    }
    
    return {
      'scoreCp': scoreCp,
      'scoreMate': scoreMate,
      'effectiveCp': effectiveCp,
      'pv': pv,
    };
  }
  
  void dispose() {
    _process.stdin.writeln('quit');
    _process.kill();
  }
}

Future<void> main() async {
  const username = 'bigmanarkhangelsk';
  const depth = 15;
  
  print('='.padRight(80, '='));
  print('FLUTTER TACTICS ANALYSIS TEST');
  print('Username: $username');
  print('Depth: $depth');
  print('='.padRight(80, '='));
  print('');
  
  // Download 1 game from Chess.com
  final now = DateTime.now();
  final year = now.year;
  final month = now.month.toString().padLeft(2, '0');
  
  print('Downloading games from Chess.com...');
  final url = 'https://api.chess.com/pub/player/${username.toLowerCase()}/games/$year/$month/pgn';
  
  String pgn;
  try {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      // Try previous month
      final prevMonth = (now.month - 1).toString().padLeft(2, '0');
      final prevYear = now.month == 1 ? now.year - 1 : now.year;
      final url2 = 'https://api.chess.com/pub/player/${username.toLowerCase()}/games/$prevYear/$prevMonth/pgn';
      final response2 = await http.get(Uri.parse(url2));
      if (response2.statusCode != 200) {
        print('Failed to fetch games');
        exit(1);
      }
      pgn = response2.body;
    } else {
      pgn = response.body;
    }
  } catch (e) {
    print('Error fetching games: $e');
    exit(1);
  }
  
  // Split PGN and get first game
  final games = <String>[];
  final lines = pgn.split('\n');
  String currentGame = '';
  bool inGame = false;
  
  for (final line in lines) {
    if (line.startsWith('[Event')) {
      if (inGame && currentGame.trim().isNotEmpty) {
        games.add(currentGame);
      }
      currentGame = '$line\n';
      inGame = true;
    } else if (inGame) {
      currentGame += '$line\n';
    }
  }
  if (inGame && currentGame.trim().isNotEmpty) {
    games.add(currentGame);
  }
  
  if (games.isEmpty) {
    print('No games found');
    exit(1);
  }
  
  final gameText = games.first;
  print('Found ${games.length} games, analyzing first one...');
  print('');
  
  // Parse headers
  final headers = <String, String>{};
  for (final match in RegExp(r'\[(\w+)\s+"([^"]*)"\]').allMatches(gameText)) {
    headers[match.group(1)!] = match.group(2)!;
  }
  
  print('Game: ${headers['White']} vs ${headers['Black']}');
  print('Date: ${headers['Date']}');
  print('Result: ${headers['Result']}');
  print('');
  
  // Find user color
  final white = (headers['White'] ?? '').toLowerCase();
  final black = (headers['Black'] ?? '').toLowerCase();
  final userLower = username.toLowerCase();
  
  chess.Color? userColor;
  if (white.contains(userLower)) {
    userColor = chess.Color.WHITE;
  } else if (black.contains(userLower)) {
    userColor = chess.Color.BLACK;
  } else {
    print('User not found in game');
    exit(1);
  }
  
  print('User plays: ${userColor == chess.Color.WHITE ? "White" : "Black"}');
  print('');
  
  // Extract moves
  final movesMatch = RegExp(r'\n\n([\s\S]+)$').firstMatch(gameText);
  if (movesMatch == null) {
    print('No moves found');
    exit(1);
  }
  
  String movesText = movesMatch.group(1)!
      .replaceAll(RegExp(r'\{[^}]*\}'), '')
      .replaceAll(RegExp(r'\([^)]*\)'), '')
      .replaceAll(RegExp(r'\$\d+'), '')
      .replaceAll(RegExp(r'\d+\.\.\.'), '')
      .trim();
  
  final moves = <Map<String, dynamic>>[];
  for (final m in RegExp(r'(\d+)\.\s*(\S+)(?:\s+(\S+))?').allMatches(movesText)) {
    final num = int.parse(m.group(1)!);
    final whiteMove = m.group(2)!;
    final blackMove = m.group(3);
    
    if (!['1-0', '0-1', '1/2-1/2', '*'].contains(whiteMove)) {
      moves.add({'num': num, 'san': whiteMove, 'color': 'w'});
    }
    if (blackMove != null && !['1-0', '0-1', '1/2-1/2', '*'].contains(blackMove)) {
      moves.add({'num': num, 'san': blackMove, 'color': 'b'});
    }
  }
  
  print('Total moves: ${moves.length}');
  print('');
  
  // Initialize Stockfish
  print('Initializing Stockfish...');
  final stockfish = SimpleStockfish();
  await stockfish.init();
  print('');
  
  // Replay game and analyze user moves
  final game = chess.Chess();
  
  print('='.padRight(80, '='));
  print('POSITION-BY-POSITION ANALYSIS');
  print('='.padRight(80, '='));
  print('');
  
  for (final move in moves) {
    final san = move['san'] as String;
    final moveNum = move['num'] as int;
    final color = move['color'] as String;
    final isUserMove = (color == 'w' && userColor == chess.Color.WHITE) ||
                       (color == 'b' && userColor == chess.Color.BLACK);
    
    if (!isUserMove) {
      // Opponent's move - just play it
      final result = game.move(san);
      if (result == null) {
        print('ERROR: Failed to parse opponent move: $san');
        break;
      }
      continue;
    }
    
    // User's move - analyze
    final fenBefore = game.fen;
    
    print('--- Move $moveNum. $san (${color == 'w' ? 'White' : 'Black'}) ---');
    print('FEN: $fenBefore');
    
    // Analyze position BEFORE the move
    final evalBefore = await stockfish.getEvaluation(fenBefore, depth: depth);
    
    // Make the move
    final result = game.move(san);
    if (result == null) {
      print('ERROR: Failed to parse user move: $san');
      break;
    }
    
    final fenAfter = game.fen;
    
    // Analyze position AFTER the move
    final evalAfter = await stockfish.getEvaluation(fenAfter, depth: depth);
    
    // Get effective centipawns (already normalized to White's perspective by engine)
    int cpBefore = evalBefore['effectiveCp'] as int;
    int cpAfter = evalAfter['effectiveCp'] as int;
    
    // Normalize to USER's perspective
    if (userColor == chess.Color.BLACK) {
      cpBefore = -cpBefore;
      cpAfter = -cpAfter;
    }
    
    final winChanceBefore = calculateWinChance(cpBefore);
    final winChanceAfter = calculateWinChance(cpAfter);
    final delta = winChanceBefore - winChanceAfter;
    
    final isBlunder = delta > 30;
    final isMistake = delta > 20 && delta <= 30;
    final status = isBlunder ? '⚠️ BLUNDER' : (isMistake ? '⚠ MISTAKE' : '✓ OK');
    
    print('Eval Before: ${cpBefore}cp (${winChanceBefore.toStringAsFixed(1)}%)');
    print('Eval After:  ${cpAfter}cp (${winChanceAfter.toStringAsFixed(1)}%)');
    print('Delta: ${delta.toStringAsFixed(1)}% | $status');
    print('PV: ${(evalBefore['pv'] as List).take(3).join(' ')}');
    print('');
  }
  
  print('='.padRight(80, '='));
  print('ANALYSIS COMPLETE');
  print('='.padRight(80, '='));
  
  stockfish.dispose();
}

