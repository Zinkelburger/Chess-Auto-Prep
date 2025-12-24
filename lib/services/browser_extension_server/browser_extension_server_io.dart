/// Desktop (IO) implementation of the Browser Extension Server
/// Uses dart:io HttpServer to handle requests from the Lichess browser extension
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dartchess_webok/dartchess_webok.dart';

import 'browser_extension_server.dart';

/// Factory function for conditional import
BrowserExtensionServer createBrowserExtensionServer() => BrowserExtensionServerIO();

/// Desktop implementation using dart:io HttpServer
class BrowserExtensionServerIO implements BrowserExtensionServer {
  HttpServer? _server;
  int? _port;
  
  @override
  bool get isRunning => _server != null;
  
  @override
  int? get port => _port;
  
  @override
  bool get isSupported => !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);
  
  @override
  Future<bool> start({int port = 9812}) async {
    if (_server != null) {
      debugPrint('[BrowserExtensionServer] Server already running on port $_port');
      return true;
    }
    
    if (!isSupported) {
      debugPrint('[BrowserExtensionServer] Platform not supported');
      return false;
    }
    
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _port = port;
      
      debugPrint('[BrowserExtensionServer] Server started on http://localhost:$port');
      debugPrint('[BrowserExtensionServer] Endpoints:');
      debugPrint('[BrowserExtensionServer]   GET  /list-repertoires - List repertoires');
      debugPrint('[BrowserExtensionServer]   POST /add-line - Add line to repertoire');
      debugPrint('[BrowserExtensionServer]   GET  /health - Health check');
      
      _server!.listen(_handleRequest);
      return true;
    } catch (e) {
      debugPrint('[BrowserExtensionServer] Failed to start server: $e');
      return false;
    }
  }
  
  @override
  Future<void> stop() async {
    if (_server != null) {
      await _server!.close();
      _server = null;
      _port = null;
      debugPrint('[BrowserExtensionServer] Server stopped');
    }
  }
  
  void _handleRequest(HttpRequest request) async {
    // Add CORS headers for browser extension
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
    
    // Handle preflight requests
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }
    
    try {
      final path = request.uri.path;
      
      switch (path) {
        case '/list-repertoires':
          await _handleListRepertoires(request);
          break;
        case '/add-line':
          await _handleAddLine(request);
          break;
        case '/health':
          await _handleHealth(request);
          break;
        default:
          _sendJson(request, {'error': 'Not found'}, status: HttpStatus.notFound);
      }
    } catch (e, stack) {
      debugPrint('[BrowserExtensionServer] Error handling request: $e\n$stack');
      _sendJson(request, {'error': e.toString()}, status: HttpStatus.internalServerError);
    }
  }
  
  Future<void> _handleListRepertoires(HttpRequest request) async {
    if (request.method != 'GET') {
      _sendJson(request, {'error': 'Method not allowed'}, status: HttpStatus.methodNotAllowed);
      return;
    }
    
    try {
      final directory = await getApplicationDocumentsDirectory();
      final repertoireDir = Directory('${directory.path}/repertoires');
      
      // Create directory if it doesn't exist
      if (!await repertoireDir.exists()) {
        await repertoireDir.create(recursive: true);
        _sendJson(request, {'repertoires': []});
        return;
      }
      
      final repertoires = <Map<String, dynamic>>[];
      
      await for (final file in repertoireDir.list()) {
        if (file is File && file.path.endsWith('.pgn')) {
          final stat = await file.stat();
          final content = await file.readAsString();
          final lineCount = _countGamesInPgn(content);
          final fileName = file.path.split(Platform.pathSeparator).last;
          final name = fileName.replaceAll('.pgn', '');
          
          // Extract color metadata from PGN comments (e.g., "// Color: White")
          final color = _extractRepertoireColor(content);
          
          repertoires.add({
            'name': name,
            'filename': fileName,
            'path': file.path,
            'modified': stat.modified.millisecondsSinceEpoch / 1000,
            'size': stat.size,
            'lineCount': lineCount,
            'color': color,  // "white", "black", or null if not specified
          });
        }
      }
      
      // Sort by modification time (most recent first)
      repertoires.sort((a, b) => (b['modified'] as double).compareTo(a['modified'] as double));
      
      _sendJson(request, {'repertoires': repertoires});
    } catch (e) {
      debugPrint('[BrowserExtensionServer] Error listing repertoires: $e');
      _sendJson(request, {'error': e.toString()}, status: HttpStatus.internalServerError);
    }
  }
  
  Future<void> _handleAddLine(HttpRequest request) async {
    if (request.method != 'POST') {
      _sendJson(request, {'error': 'Method not allowed'}, status: HttpStatus.methodNotAllowed);
      return;
    }
    
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      
      // Validate data
      if (!data.containsKey('moves') || (data['moves'] as List).isEmpty) {
        _sendJson(request, {'error': 'No moves provided'}, status: HttpStatus.badRequest);
        return;
      }
      
      // Get target repertoire file
      String? targetFilename = data['targetRepertoire'] as String?;
      if (targetFilename == null || targetFilename.isEmpty) {
        _sendJson(request, {'error': 'No target repertoire specified'}, status: HttpStatus.badRequest);
        return;
      }
      
      // Sanitize filename
      targetFilename = targetFilename.split(Platform.pathSeparator).last;
      if (!targetFilename.endsWith('.pgn')) {
        targetFilename = '$targetFilename.pgn';
      }
      
      final directory = await getApplicationDocumentsDirectory();
      final repertoireDir = Directory('${directory.path}/repertoires');
      await repertoireDir.create(recursive: true);
      
      final targetFile = File('${repertoireDir.path}${Platform.pathSeparator}$targetFilename');
      
      // Check for duplicates
      if (await _isDuplicate(data, targetFile)) {
        final lineCount = await _countGamesInFile(targetFile);
        _sendJson(request, {
          'status': 'duplicate',
          'message': 'Line already exists in repertoire',
          'lineCount': lineCount,
        });
        return;
      }
      
      // Create PGN game from line data
      final pgnGame = _createPgnGame(data);
      
      // Append to file
      await _appendToFile(targetFile, pgnGame);
      
      final lineCount = await _countGamesInFile(targetFile);
      final name = targetFilename.replaceAll('.pgn', '');
      
      debugPrint('[BrowserExtensionServer] Added line to $targetFilename (total: $lineCount)');
      
      _sendJson(request, {
        'status': 'success',
        'lineCount': lineCount,
        'message': 'Line added to $name',
      });
    } catch (e) {
      debugPrint('[BrowserExtensionServer] Error adding line: $e');
      _sendJson(request, {'error': e.toString()}, status: HttpStatus.internalServerError);
    }
  }
  
  Future<void> _handleHealth(HttpRequest request) async {
    if (request.method != 'GET') {
      _sendJson(request, {'error': 'Method not allowed'}, status: HttpStatus.methodNotAllowed);
      return;
    }
    
    try {
      final directory = await getApplicationDocumentsDirectory();
      final repertoireDir = Directory('${directory.path}/repertoires');
      
      int repertoireCount = 0;
      if (await repertoireDir.exists()) {
        await for (final file in repertoireDir.list()) {
          if (file is File && file.path.endsWith('.pgn')) {
            repertoireCount++;
          }
        }
      }
      
      _sendJson(request, {
        'status': 'ok',
        'repertoireCount': repertoireCount,
        'repertoireDir': repertoireDir.path,
        'platform': Platform.operatingSystem,
      });
    } catch (e) {
      _sendJson(request, {'error': e.toString()}, status: HttpStatus.internalServerError);
    }
  }
  
  void _sendJson(HttpRequest request, Map<String, dynamic> data, {int status = HttpStatus.ok}) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    request.response.close();
  }
  
  int _countGamesInPgn(String content) {
    return '[Event '.allMatches(content).length;
  }
  
  /// Extract repertoire color from PGN content
  /// Looks for "// Color: White" or "// Color: Black" comments at the start of the file
  String? _extractRepertoireColor(String content) {
    final lines = content.split('\n');
    
    // Check the first 10 lines for the color comment
    for (int i = 0; i < lines.length && i < 10; i++) {
      final line = lines[i].trim();
      if (line.startsWith('// Color:')) {
        final colorValue = line.substring(9).trim().toLowerCase();
        if (colorValue == 'white' || colorValue == 'black') {
          return colorValue;
        }
      }
    }
    
    return null;  // No color specified
  }
  
  Future<int> _countGamesInFile(File file) async {
    if (!await file.exists()) return 0;
    final content = await file.readAsString();
    return _countGamesInPgn(content);
  }
  
  /// Generate a signature for a line based on moves (for duplicate detection)
  String _getLineSignature(Map<String, dynamic> data) {
    final moves = data['moves'] as List;
    final startFen = data['startFen'] as String? ?? 
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final variant = data['variant'] as String? ?? 'standard';
    
    final sanSequence = moves
        .map((m) => (m as Map<String, dynamic>)['san'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    
    return '$variant:$startFen:${sanSequence.join(':')}';
  }
  
  /// Check if this line already exists in the repertoire
  Future<bool> _isDuplicate(Map<String, dynamic> data, File file) async {
    if (!await file.exists()) return false;
    
    final content = await file.readAsString();
    if (content.trim().isEmpty) return false;
    
    final newSignature = _getLineSignature(data);
    
    // Parse existing games and compare signatures
    final games = _splitPgnIntoGames(content);
    
    for (final gameText in games) {
      try {
        final existingSignature = _getGameSignature(gameText);
        if (existingSignature == newSignature) {
          return true;
        }
      } catch (e) {
        // Ignore parse errors in existing games
        continue;
      }
    }
    
    return false;
  }
  
  /// Get signature from an existing PGN game text
  String _getGameSignature(String gameText) {
    // Extract FEN if present
    String startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final fenMatch = RegExp(r'\[FEN\s+"([^"]+)"\]').firstMatch(gameText);
    if (fenMatch != null) {
      startFen = fenMatch.group(1)!;
    }
    
    // Extract variant
    String variant = 'standard';
    final variantMatch = RegExp(r'\[Variant\s+"([^"]+)"\]').firstMatch(gameText);
    if (variantMatch != null) {
      variant = variantMatch.group(1)!.toLowerCase();
    }
    
    // Parse moves using dartchess
    try {
      final game = PgnGame.parsePgn(gameText);
      final moves = game.moves.mainline().map((node) => node.san).toList();
      return '$variant:$startFen:${moves.join(':')}';
    } catch (e) {
      // Fallback: extract moves manually
      final moves = _extractMovesManually(gameText);
      return '$variant:$startFen:${moves.join(':')}';
    }
  }
  
  /// Split PGN content into individual games
  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');
    
    String currentGame = '';
    bool inGame = false;
    
    for (final line in lines) {
      final trimmedLine = line.trim();
      
      // Skip comment-only lines at the top level
      if (trimmedLine.startsWith('//') && !inGame) {
        continue;
      }
      
      if (trimmedLine.startsWith('[Event')) {
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
    
    return games;
  }
  
  /// Fallback move extraction when parsing fails
  List<String> _extractMovesManually(String gameText) {
    final moves = <String>[];
    
    // Find where moves start (after headers and empty line)
    final headerEnd = gameText.lastIndexOf(']');
    if (headerEnd == -1) return moves;
    
    final movesText = gameText.substring(headerEnd + 1).trim();
    
    // Simple regex to extract moves (not perfect but works for basic cases)
    final movePattern = RegExp(r'([KQRBN]?[a-h]?[1-8]?x?[a-h][1-8](=[QRBN])?|O-O-O|O-O)[+#]?');
    
    for (final match in movePattern.allMatches(movesText)) {
      moves.add(match.group(0)!);
    }
    
    return moves;
  }
  
  /// Create a PGN game string from the line data
  String _createPgnGame(Map<String, dynamic> data) {
    final now = DateTime.now();
    final dateStr = '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';
    
    final variant = data['variant'] as String? ?? 'standard';
    final startFen = data['startFen'] as String?;
    const standardFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    
    final buffer = StringBuffer();
    
    // Headers
    buffer.writeln('[Event "Repertoire Line"]');
    buffer.writeln('[Site "Lichess Analysis"]');
    buffer.writeln('[Date "$dateStr"]');
    buffer.writeln('[Round "?"]');
    buffer.writeln('[White "?"]');
    buffer.writeln('[Black "?"]');
    buffer.writeln('[Result "*"]');
    
    if (variant != 'standard') {
      buffer.writeln('[Variant "${_capitalize(variant)}"]');
    }
    
    if (startFen != null && startFen != standardFen) {
      buffer.writeln('[FEN "$startFen"]');
      buffer.writeln('[SetUp "1"]');
    }
    
    buffer.writeln();
    
    // Build moves with annotations
    final moves = data['moves'] as List;
    
    for (int i = 0; i < moves.length; i++) {
      final move = moves[i] as Map<String, dynamic>;
      final san = move['san'] as String? ?? '';
      if (san.isEmpty) continue;
      
      final ply = move['ply'] as int? ?? (i + 1);
      final moveNumber = ((ply + 1) / 2).floor();
      final isWhiteMove = ply % 2 == 1;
      
      // Add move number
      if (isWhiteMove) {
        buffer.write('$moveNumber. ');
      } else if (i == 0) {
        // First move is black - add move number with ...
        buffer.write('$moveNumber... ');
      }
      
      // Add move
      buffer.write(san);
      
      // Add glyphs (NAGs)
      final glyphs = move['glyphs'] as List?;
      if (glyphs != null) {
        for (final glyph in glyphs) {
          final glyphId = (glyph as Map<String, dynamic>)['id'] as int?;
          if (glyphId != null) {
            buffer.write(' \$$glyphId');
          }
        }
      }
      
      // Add comments
      final comments = move['comments'] as List?;
      if (comments != null && comments.isNotEmpty) {
        final commentText = comments.join(' ').trim();
        if (commentText.isNotEmpty) {
          buffer.write(' { $commentText }');
        }
      }
      
      buffer.write(' ');
    }
    
    buffer.write('*');
    
    return buffer.toString();
  }
  
  /// Append a PGN game to the repertoire file
  Future<void> _appendToFile(File file, String pgnGame) async {
    // Create file if it doesn't exist
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    
    // Check if file is empty or not
    final existingContent = await file.readAsString();
    
    if (existingContent.isEmpty) {
      // Write directly
      await file.writeAsString(pgnGame);
    } else {
      // Append with separator
      await file.writeAsString('$existingContent\n\n$pgnGame');
    }
  }
  
  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}

