// Standalone Dart test script for tactics analysis comparison
// Run with: dart run test_flutter_analysis.dart
//
// This uses the same logic as TacticsImportService but outputs detailed logs
// for comparison with the JavaScript version.

import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:dartchess/dartchess.dart' hide File;

// Win% formula (same as Flutter and JS)
double calculateWinChance(int centipawns) {
  return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * centipawns)) - 1);
}

// Simple UCI engine wrapper for desktop Stockfish
class SimpleStockfish {
  late Process _process;
  bool _ready = false;
  
  Future<void> init() async {
    final stockfishPath = await _findStockfish();
    if (stockfishPath == null) {
      throw Exception('Stockfish not found. Install it with: sudo dnf install stockfish');
    }
    
    _process = await Process.start(stockfishPath, []);
    
    _process.stdout.transform(const SystemEncoding().decoder).listen((line) {});
    
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
    
    await for (final line in _process.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter())) {
      if (line.startsWith('info depth') && line.contains(' pv ')) {
        final cpMatch = RegExp(r'score cp (-?\d+)').firstMatch(line);
        final mateMatch = RegExp(r'score mate (-?\d+)').firstMatch(line);
        final pvMatch = RegExp(r' pv (.+)').firstMatch(line);
        
        if (cpMatch != null) {
          int rawCp = int.parse(cpMatch.group(1)!);
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
  
  final now = DateTime.now();
  final year = now.year;
  final month = now.month.toString().padLeft(2, '0');
  
  print('Downloading games from Chess.com...');
  final url = 'https://api.chess.com/pub/player/${username.toLowerCase()}/games/$year/$month/pgn';
  
  String pgn;
  try {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
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
  
  final headers = <String, String>{};
  for (final match in RegExp(r'\[(\w+)\s+"([^"]*)"\]').allMatches(gameText)) {
    headers[match.group(1)!] = match.group(2)!;
  }
  
  print('Game: ${headers['White']} vs ${headers['Black']}');
  print('Date: ${headers['Date']}');
  print('Result: ${headers['Result']}');
  print('');
  
  final white = (headers['White'] ?? '').toLowerCase();
  final black = (headers['Black'] ?? '').toLowerCase();
  final userLower = username.toLowerCase();
  
  Side? userSide;
  if (white.contains(userLower)) {
    userSide = Side.white;
  } else if (black.contains(userLower)) {
    userSide = Side.black;
  } else {
    print('User not found in game');
    exit(1);
  }
  
  print('User plays: ${userSide == Side.white ? "White" : "Black"}');
  print('');
  
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
  
  print('Initializing Stockfish...');
  final stockfish = SimpleStockfish();
  await stockfish.init();
  print('');
  
  Position pos = Chess.initial;
  
  print('='.padRight(80, '='));
  print('POSITION-BY-POSITION ANALYSIS');
  print('='.padRight(80, '='));
  print('');
  
  for (final move in moves) {
    final san = move['san'] as String;
    final moveNum = move['num'] as int;
    final color = move['color'] as String;
    final isUserMove = (color == 'w' && userSide == Side.white) ||
                       (color == 'b' && userSide == Side.black);
    
    final parsedMove = pos.parseSan(san);
    if (parsedMove == null) {
      print('ERROR: Failed to parse move: $san');
      break;
    }
    
    if (!isUserMove) {
      pos = pos.play(parsedMove);
      continue;
    }
    
    final fenBefore = pos.fen;
    
    print('--- Move $moveNum. $san (${color == 'w' ? 'White' : 'Black'}) ---');
    print('FEN: $fenBefore');
    
    final evalBefore = await stockfish.getEvaluation(fenBefore, depth: depth);
    
    pos = pos.play(parsedMove);
    final fenAfter = pos.fen;
    
    final evalAfter = await stockfish.getEvaluation(fenAfter, depth: depth);
    
    int cpBefore = evalBefore['effectiveCp'] as int;
    int cpAfter = evalAfter['effectiveCp'] as int;
    
    if (userSide == Side.black) {
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
