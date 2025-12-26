#!/usr/bin/env dart
// Standalone Dart test script for tactics analysis comparison
// Run with: dart run test_dart_analysis_standalone.dart
//
// This is a standalone version with no Flutter dependencies.

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

// Win% formula (same as Flutter and JS)
double calculateWinChance(int centipawns) {
  return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * centipawns)) - 1);
}

// Simple UCI engine wrapper for desktop Stockfish
class SimpleStockfish {
  late Process _process;
  bool _ready = false;
  late Stream<String> _outputStream;
  late StreamIterator<String> _streamIterator;
  
  Future<void> init() async {
    // Try to find stockfish
    final stockfishPath = await _findStockfish();
    if (stockfishPath == null) {
      throw Exception('Stockfish not found. Install it with: sudo dnf install stockfish');
    }
    
    _process = await Process.start(stockfishPath, []);
    
    // Create a broadcast stream from stdout
    _outputStream = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    
    _streamIterator = StreamIterator(_outputStream);
    
    _process.stdin.writeln('uci');
    
    // Wait for uciok
    while (await _streamIterator.moveNext()) {
      if (_streamIterator.current.contains('uciok')) break;
    }
    
    _process.stdin.writeln('isready');
    
    // Wait for readyok
    while (await _streamIterator.moveNext()) {
      if (_streamIterator.current.contains('readyok')) break;
    }
    
    _ready = true;
    print('[Stockfish] Ready');
  }
  
  Future<String?> _findStockfish() async {
    final paths = [
      '/usr/bin/stockfish',
      '/usr/local/bin/stockfish',
    ];
    
    for (final path in paths) {
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
    while (await _streamIterator.moveNext()) {
      final line = _streamIterator.current;
      
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

// Simple chess position tracker
class SimpleChess {
  // Board representation: 8x8 array, each cell is null or 'Wp', 'Bp', etc.
  late List<String?> board;
  String turn = 'w';
  Map<String, bool> castling = {'K': true, 'Q': true, 'k': true, 'q': true};
  String? epSquare;
  int halfmove = 0;
  int fullmove = 1;
  
  SimpleChess() {
    reset();
  }
  
  void reset() {
    board = List.filled(64, null);
    turn = 'w';
    castling = {'K': true, 'Q': true, 'k': true, 'q': true};
    epSquare = null;
    halfmove = 0;
    fullmove = 1;
    
    // Setup initial position
    const backRank = ['r', 'n', 'b', 'q', 'k', 'b', 'n', 'r'];
    for (int i = 0; i < 8; i++) {
      board[i] = 'w${backRank[i]}';
      board[i + 8] = 'wp';
      board[i + 48] = 'bp';
      board[i + 56] = 'b${backRank[i]}';
    }
  }
  
  int algebraicToIndex(String sq) {
    final file = sq.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final rank = int.parse(sq[1]) - 1;
    return rank * 8 + file;
  }
  
  String indexToAlgebraic(int idx) {
    final file = String.fromCharCode('a'.codeUnitAt(0) + (idx % 8));
    final rank = (idx ~/ 8) + 1;
    return '$file$rank';
  }
  
  String getFen() {
    String fen = '';
    
    for (int rank = 7; rank >= 0; rank--) {
      int empty = 0;
      for (int file = 0; file < 8; file++) {
        final piece = board[rank * 8 + file];
        if (piece == null) {
          empty++;
        } else {
          if (empty > 0) {
            fen += empty.toString();
            empty = 0;
          }
          final color = piece[0];
          final type = piece[1];
          fen += color == 'w' ? type.toUpperCase() : type;
        }
      }
      if (empty > 0) fen += empty.toString();
      if (rank > 0) fen += '/';
    }
    
    fen += ' $turn';
    
    String castleStr = '';
    if (castling['K']!) castleStr += 'K';
    if (castling['Q']!) castleStr += 'Q';
    if (castling['k']!) castleStr += 'k';
    if (castling['q']!) castleStr += 'q';
    fen += ' ${castleStr.isEmpty ? '-' : castleStr}';
    
    fen += ' ${epSquare ?? '-'}';
    fen += ' $halfmove';
    fen += ' $fullmove';
    
    return fen;
  }
  
  bool move(String san) {
    String s = san.replaceAll(RegExp(r'[+#!?]'), '');
    
    // Castling
    if (s == 'O-O' || s == '0-0') {
      final rank = turn == 'w' ? 0 : 7;
      final kingFrom = rank * 8 + 4;
      final kingTo = rank * 8 + 6;
      final rookFrom = rank * 8 + 7;
      final rookTo = rank * 8 + 5;
      
      board[kingTo] = board[kingFrom];
      board[kingFrom] = null;
      board[rookTo] = board[rookFrom];
      board[rookFrom] = null;
      
      if (turn == 'w') {
        castling['K'] = false;
        castling['Q'] = false;
      } else {
        castling['k'] = false;
        castling['q'] = false;
      }
      
      _finishMove();
      return true;
    }
    
    if (s == 'O-O-O' || s == '0-0-0') {
      final rank = turn == 'w' ? 0 : 7;
      final kingFrom = rank * 8 + 4;
      final kingTo = rank * 8 + 2;
      final rookFrom = rank * 8 + 0;
      final rookTo = rank * 8 + 3;
      
      board[kingTo] = board[kingFrom];
      board[kingFrom] = null;
      board[rookTo] = board[rookFrom];
      board[rookFrom] = null;
      
      if (turn == 'w') {
        castling['K'] = false;
        castling['Q'] = false;
      } else {
        castling['k'] = false;
        castling['q'] = false;
      }
      
      _finishMove();
      return true;
    }
    
    // Extract promotion
    String? promotion;
    final promoMatch = RegExp(r'[=]?([QRBN])$', caseSensitive: false).firstMatch(s);
    if (promoMatch != null) {
      promotion = promoMatch.group(1)!.toLowerCase();
      s = s.replaceAll(RegExp(r'[=]?[QRBN]$', caseSensitive: false), '');
    }
    
    // Destination (last 2 chars)
    final dest = s.substring(s.length - 2);
    final destIdx = algebraicToIndex(dest);
    s = s.substring(0, s.length - 2);
    
    // Capture marker
    final isCapture = s.contains('x');
    s = s.replaceAll('x', '');
    
    // Piece type
    String pieceType = 'p';
    if (s.isNotEmpty && RegExp(r'^[KQRBN]$').hasMatch(s[0])) {
      pieceType = s[0].toLowerCase();
      s = s.substring(1);
    }
    
    // Disambiguation
    String? disambigFile;
    String? disambigRank;
    if (s.length == 1) {
      if (RegExp(r'[a-h]').hasMatch(s)) {
        disambigFile = s;
      } else if (RegExp(r'[1-8]').hasMatch(s)) {
        disambigRank = s;
      }
    } else if (s.length == 2) {
      disambigFile = s[0];
      disambigRank = s[1];
    }
    
    // For pawn captures, need the source file
    if (pieceType == 'p' && isCapture && disambigFile == null) {
      final cleanSan = san.replaceAll(RegExp(r'[+#!?]'), '').replaceAll(RegExp(r'[=]?[QRBN]$', caseSensitive: false), '');
      final xIdx = cleanSan.indexOf('x');
      if (xIdx > 0) {
        disambigFile = cleanSan[xIdx - 1];
      }
    }
    
    // Find the piece
    int? fromIdx;
    for (int i = 0; i < 64; i++) {
      final piece = board[i];
      if (piece == null || piece[0] != turn || piece[1] != pieceType) continue;
      
      final alg = indexToAlgebraic(i);
      if (disambigFile != null && alg[0] != disambigFile) continue;
      if (disambigRank != null && alg[1] != disambigRank) continue;
      
      // Check if this piece can reach destination
      if (_canMove(i, destIdx, pieceType)) {
        fromIdx = i;
        break;
      }
    }
    
    if (fromIdx == null) {
      print('ERROR: Could not find piece for move: $san');
      return false;
    }
    
    // Handle en passant capture
    if (pieceType == 'p' && isCapture && board[destIdx] == null) {
      final capturedIdx = destIdx + (turn == 'w' ? -8 : 8);
      board[capturedIdx] = null;
    }
    
    // Make the move
    board[destIdx] = board[fromIdx];
    board[fromIdx] = null;
    
    // Handle promotion
    if (promotion != null) {
      board[destIdx] = '$turn$promotion';
    }
    
    // Update en passant square
    if (pieceType == 'p' && (destIdx - fromIdx).abs() == 16) {
      epSquare = indexToAlgebraic((fromIdx + destIdx) ~/ 2);
    } else {
      epSquare = null;
    }
    
    // Update castling rights
    if (pieceType == 'k') {
      if (turn == 'w') {
        castling['K'] = false;
        castling['Q'] = false;
      } else {
        castling['k'] = false;
        castling['q'] = false;
      }
    }
    if (pieceType == 'r') {
      final alg = indexToAlgebraic(fromIdx);
      if (alg == 'a1') castling['Q'] = false;
      if (alg == 'h1') castling['K'] = false;
      if (alg == 'a8') castling['q'] = false;
      if (alg == 'h8') castling['k'] = false;
    }
    
    _finishMove();
    return true;
  }
  
  bool _canMove(int from, int to, String pieceType) {
    final fromFile = from % 8;
    final fromRank = from ~/ 8;
    final toFile = to % 8;
    final toRank = to ~/ 8;
    final dFile = toFile - fromFile;
    final dRank = toRank - fromRank;
    
    switch (pieceType) {
      case 'p':
        final dir = turn == 'w' ? 1 : -1;
        final startRank = turn == 'w' ? 1 : 6;
        
        // Forward move
        if (dFile == 0 && dRank == dir && board[to] == null) return true;
        // Double push from start
        if (dFile == 0 && dRank == 2 * dir && fromRank == startRank && 
            board[to] == null && board[from + 8 * dir] == null) return true;
        // Capture
        if (dFile.abs() == 1 && dRank == dir) {
          if (board[to] != null || indexToAlgebraic(to) == epSquare) return true;
        }
        return false;
        
      case 'n':
        return (dFile.abs() == 2 && dRank.abs() == 1) ||
               (dFile.abs() == 1 && dRank.abs() == 2);
        
      case 'b':
        if (dFile.abs() != dRank.abs()) return false;
        return _isPathClear(from, to, dFile.sign, dRank.sign);
        
      case 'r':
        if (dFile != 0 && dRank != 0) return false;
        return _isPathClear(from, to, dFile.sign, dRank.sign);
        
      case 'q':
        if (dFile != 0 && dRank != 0 && dFile.abs() != dRank.abs()) return false;
        return _isPathClear(from, to, dFile.sign, dRank.sign);
        
      case 'k':
        return dFile.abs() <= 1 && dRank.abs() <= 1;
    }
    
    return false;
  }
  
  bool _isPathClear(int from, int to, int dFile, int dRank) {
    int current = from + dFile + dRank * 8;
    while (current != to) {
      if (board[current] != null) return false;
      current += dFile + dRank * 8;
    }
    return true;
  }
  
  void _finishMove() {
    if (turn == 'b') {
      fullmove++;
    }
    turn = turn == 'w' ? 'b' : 'w';
  }
}

Future<void> main() async {
  const username = 'bigmanarkhangelsk';
  const depth = 15;
  
  print('=' * 80);
  print('DART TACTICS ANALYSIS TEST');
  print('Username: $username');
  print('Depth: $depth');
  print('=' * 80);
  print('');
  
  // Download 1 game from Chess.com
  final now = DateTime.now();
  final year = now.year;
  final month = now.month.toString().padLeft(2, '0');
  
  print('Downloading games from Chess.com...');
  
  String pgn;
  try {
    var url = 'https://api.chess.com/pub/player/${username.toLowerCase()}/games/$year/$month/pgn';
    var client = HttpClient();
    var request = await client.getUrl(Uri.parse(url));
    var response = await request.close();
    
    if (response.statusCode != 200) {
      // Try previous month
      final prevMonth = (now.month - 1 == 0 ? 12 : now.month - 1).toString().padLeft(2, '0');
      final prevYear = now.month == 1 ? now.year - 1 : now.year;
      url = 'https://api.chess.com/pub/player/${username.toLowerCase()}/games/$prevYear/$prevMonth/pgn';
      request = await client.getUrl(Uri.parse(url));
      response = await request.close();
      
      if (response.statusCode != 200) {
        print('Failed to fetch games');
        exit(1);
      }
    }
    
    pgn = await response.transform(utf8.decoder).join();
    client.close();
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
  
  String? userColor;
  if (white.contains(userLower)) {
    userColor = 'w';
  } else if (black.contains(userLower)) {
    userColor = 'b';
  } else {
    print('User not found in game');
    exit(1);
  }
  
  print('User plays: ${userColor == 'w' ? 'White' : 'Black'}');
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
  final game = SimpleChess();
  
  print('=' * 80);
  print('POSITION-BY-POSITION ANALYSIS');
  print('=' * 80);
  print('');
  
  for (final move in moves) {
    final san = move['san'] as String;
    final moveNum = move['num'] as int;
    final color = move['color'] as String;
    final isUserMove = color == userColor;
    
    if (!isUserMove) {
      // Opponent's move - just play it
      final result = game.move(san);
      if (!result) {
        print('ERROR: Failed to parse opponent move: $san');
        break;
      }
      continue;
    }
    
    // User's move - analyze
    final fenBefore = game.getFen();
    
    print('--- Move $moveNum. $san (${color == 'w' ? 'White' : 'Black'}) ---');
    print('FEN: $fenBefore');
    
    // Analyze position BEFORE the move
    final evalBefore = await stockfish.getEvaluation(fenBefore, depth: depth);
    
    // Make the move
    final result = game.move(san);
    if (!result) {
      print('ERROR: Failed to parse user move: $san');
      break;
    }
    
    final fenAfter = game.getFen();
    
    // Analyze position AFTER the move
    final evalAfter = await stockfish.getEvaluation(fenAfter, depth: depth);
    
    // Get effective centipawns (already normalized to White's perspective by engine wrapper)
    int cpBefore = evalBefore['effectiveCp'] as int;
    int cpAfter = evalAfter['effectiveCp'] as int;
    
    // Normalize to USER's perspective
    if (userColor == 'b') {
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
  
  print('=' * 80);
  print('ANALYSIS COMPLETE');
  print('=' * 80);
  
  stockfish.dispose();
}

