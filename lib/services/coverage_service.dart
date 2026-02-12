/// Coverage Calculator Service
/// Analyzes repertoire coverage using the Lichess Explorer API
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dartchess_webok/dartchess_webok.dart';
import '../models/opening_tree.dart';
import '../utils/fen_utils.dart';
import 'lichess_auth_service.dart';

/// Database types for Lichess Explorer
enum LichessDatabase {
  lichess,
  masters,
  player,
}

/// Represents a leaf node in the repertoire analysis
class LeafNode {
  final String fen;
  final List<String> moves;
  final int gameCount;
  final bool isSealed;
  final String reason;

  LeafNode({
    required this.fen,
    required this.moves,
    required this.gameCount,
    required this.isSealed,
    required this.reason,
  });

  String get moveString => moves.isEmpty ? '(root)' : moves.join(' ');
}

/// Results from coverage analysis
class CoverageResult {
  final String rootFen;
  final List<String> rootMoves;  // Moves to reach root (auto-detected first branch)
  final int rootGameCount;
  final double targetPercent;  // Target as percentage of root (e.g., 1.0 = 1%)
  final int targetGameCount;   // Calculated: rootGameCount * targetPercent / 100
  final List<LeafNode> sealedLeaves;
  final List<LeafNode> leakingLeaves;
  final int totalSealedGames;
  final int totalLeakingGames;
  final int totalUnaccountedGames;

  CoverageResult({
    required this.rootFen,
    required this.rootMoves,
    required this.rootGameCount,
    required this.targetPercent,
    required this.targetGameCount,
    required this.sealedLeaves,
    required this.leakingLeaves,
    required this.totalSealedGames,
    required this.totalLeakingGames,
    required this.totalUnaccountedGames,
  });
  
  /// Human-readable root position description
  String get rootDescription {
    if (rootMoves.isEmpty) return 'Starting position';
    return rootMoves.join(' ');
  }

  /// Percentage of games covered by sealed leaves
  double get coveragePercent {
    if (rootGameCount == 0) return 0.0;
    return (totalSealedGames / rootGameCount) * 100;
  }

  /// Percentage of games in leaking leaves
  double get leakagePercent {
    if (rootGameCount == 0) return 0.0;
    return (totalLeakingGames / rootGameCount) * 100;
  }

  /// Percentage of games not covered
  double get unaccountedPercent => 100.0 - coveragePercent - leakagePercent;
}

/// Progress callback for coverage analysis
typedef CoverageProgressCallback = void Function(String message, double progress);

/// Coverage Calculator Service
class CoverageService {
  static const _lichessBaseUrl = 'https://explorer.lichess.ovh/lichess';
  static const _mastersBaseUrl = 'https://explorer.lichess.ovh/masters';
  static const _playerBaseUrl = 'https://explorer.lichess.ovh/player';

  final LichessDatabase database;
  final String ratings;
  final String speeds;
  final String? playerName;
  final String? playerColor;
  final double baseDelay;
  final int maxRetries;

  // Cache for FEN positions
  final Map<String, Map<String, dynamic>> _cache = {};
  int _cacheHits = 0;
  int _cacheMisses = 0;
  int _apiCalls = 0;

  // Rate limiting state
  DateTime? _lastRequestTime;
  bool _isRateLimited = false;

  CoverageService({
    this.database = LichessDatabase.lichess,
    this.ratings = '2000,2200,2500',  // Default to 2000+
    this.speeds = 'blitz,rapid,classical',
    this.playerName,
    this.playerColor,
    this.baseDelay = 0.15,
    this.maxRetries = 5,
  });

  /// Get base URL for current database
  String get _baseUrl {
    switch (database) {
      case LichessDatabase.lichess:
        return _lichessBaseUrl;
      case LichessDatabase.masters:
        return _mastersBaseUrl;
      case LichessDatabase.player:
        return _playerBaseUrl;
    }
  }

  /// Query Lichess Explorer API with caching and rate limiting
  Future<Map<String, dynamic>?> getPositionData(String fen) async {
    final cacheKey = normalizeFen(fen);

    // Check cache
    if (_cache.containsKey(cacheKey)) {
      _cacheHits++;
      return _cache[cacheKey];
    }
    _cacheMisses++;

    // Build request parameters
    final params = <String, String>{
      'variant': 'standard',
      'fen': fen,
    };

    if (database == LichessDatabase.lichess) {
      params['ratings'] = ratings;
      params['speeds'] = speeds;
    } else if (database == LichessDatabase.player) {
      if (playerName == null) {
        throw ArgumentError('playerName required for player database');
      }
      params['player'] = playerName!;
      if (playerColor != null) {
        params['color'] = playerColor!;
      }
    }

    // Rate limiting with exponential backoff
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      // Polite delay
      if (_lastRequestTime != null) {
        final elapsed = DateTime.now().difference(_lastRequestTime!);
        final delayMs = (baseDelay * 1000).toInt();
        if (elapsed.inMilliseconds < delayMs) {
          await Future.delayed(Duration(milliseconds: delayMs - elapsed.inMilliseconds));
        }
      }

      _lastRequestTime = DateTime.now();
      _apiCalls++;

      try {
        final uri = Uri.parse(_baseUrl).replace(queryParameters: params);
        final headers = await LichessAuthService().getHeaders();
        final response = await http.get(uri, headers: headers);

        if (response.statusCode == 429) {
          // Rate limited - exponential backoff
          _isRateLimited = true;
          final waitTime = (1 << attempt) * 30; // 30s, 60s, 120s, ...
          await Future.delayed(Duration(seconds: waitTime));
          _isRateLimited = false;
          continue;
        }

        if (response.statusCode == 404) {
          // Position not found
          final result = <String, dynamic>{
            'white': 0,
            'black': 0,
            'draws': 0,
            'moves': <dynamic>[],
          };
          _cache[cacheKey] = result;
          return result;
        }

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final result = jsonDecode(response.body) as Map<String, dynamic>;
        _cache[cacheKey] = result;
        return result;

      } catch (e) {
        if (attempt < maxRetries - 1) {
          final waitTime = (1 << attempt) * 5;
          await Future.delayed(Duration(seconds: waitTime));
        } else {
          return null;
        }
      }
    }

    return null;
  }

  /// Get total game count for a position
  Future<int> getGameCount(String fen) async {
    final data = await getPositionData(fen);
    if (data == null) return 0;
    return (data['white'] as int? ?? 0) +
           (data['black'] as int? ?? 0) +
           (data['draws'] as int? ?? 0);
  }

  /// Get moves from a position with their counts
  Future<List<Map<String, dynamic>>> getMovesWithCounts(String fen) async {
    final data = await getPositionData(fen);
    if (data == null) return [];
    final moves = data['moves'] as List<dynamic>? ?? [];
    return moves.cast<Map<String, dynamic>>();
  }

  /// Find the root position of a repertoire (first branching point)
  /// 
  /// Walks from the tree root until finding a position with multiple children.
  /// Returns the moves to reach that position and the FEN.
  (List<String>, String) findRepertoireRoot(OpeningTree tree) {
    final moves = <String>[];
    Chess position = Chess.initial;
    OpeningTreeNode current = tree.root;
    
    // Walk down the tree until we find a branch (multiple children) or a leaf
    while (current.children.length == 1) {
      final childMove = current.children.keys.first;
      moves.add(childMove);
      
      final move = position.parseSan(childMove);
      if (move != null) {
        position = position.play(move) as Chess;
      }
      
      current = current.children.values.first;
    }
    
    return (moves, position.fen);
  }

  /// Analyze coverage of a repertoire from an OpeningTree
  /// 
  /// [targetPercent] is the threshold as a percentage of root games.
  /// For example, 1.0 means leaves with ≤1% of root games are "sealed".
  /// 
  /// The root position is automatically detected as the first branching point
  /// in the repertoire tree.
  Future<CoverageResult> analyzeOpeningTree(
    OpeningTree tree, {
    required double targetPercent,  // e.g., 1.0 = 1% of root games
    required bool isWhiteRepertoire,
    CoverageProgressCallback? onProgress,
  }) async {
    onProgress?.call('Detecting root position...', 0.0);

    // Auto-detect root position (first branching point)
    final (rootMoves, effectiveRootFen) = findRepertoireRoot(tree);
    
    onProgress?.call(
      'Root: ${rootMoves.isEmpty ? "Starting position" : rootMoves.join(" ")}', 
      0.02
    );

    // Query root position game count
    final rootGameCount = await getGameCount(effectiveRootFen);
    
    // Calculate target game count from percentage
    final targetGameCount = (rootGameCount * targetPercent / 100).round();
    
    onProgress?.call(
      'Root: ${_formatNumber(rootGameCount)} games → Target: ${_formatNumber(targetGameCount)} (${targetPercent.toStringAsFixed(1)}%)', 
      0.05
    );
    
    // Use detected root moves as starting moves for traversal
    final startingMoves = rootMoves;

    // Find all leaf nodes in the tree
    final leaves = <LeafNode>[];
    final allPositions = <String, List<String>>{}; // FEN -> moves

    // Traverse tree using DFS, starting from the detected root
    await _traverseTree(
      tree.root,
      [],
      leaves,
      allPositions,
      targetGameCount,
      isWhiteRepertoire,
      startingMoves,
      onProgress,
    );

    onProgress?.call('Found ${leaves.length} leaf positions', 0.6);

    // Categorize leaves
    final sealedLeaves = leaves.where((l) => l.isSealed).toList();
    final leakingLeaves = leaves.where((l) => !l.isSealed).toList();

    final totalSealedGames = sealedLeaves.fold(0, (sum, l) => sum + l.gameCount);
    final totalLeakingGames = leakingLeaves.fold(0, (sum, l) => sum + l.gameCount);

    // Calculate unaccounted games
    onProgress?.call('Calculating unaccounted moves...', 0.7);
    final unaccountedGames = await _calculateUnaccounted(
      tree,
      allPositions,
      isWhiteRepertoire,
      startingMoves,
      onProgress,
    );

    onProgress?.call('Analysis complete!', 1.0);

    return CoverageResult(
      rootFen: effectiveRootFen,
      rootMoves: startingMoves,
      rootGameCount: rootGameCount,
      targetPercent: targetPercent,
      targetGameCount: targetGameCount,
      sealedLeaves: sealedLeaves,
      leakingLeaves: leakingLeaves,
      totalSealedGames: totalSealedGames,
      totalLeakingGames: totalLeakingGames,
      totalUnaccountedGames: unaccountedGames,
    );
  }

  /// Traverse the opening tree and collect leaf nodes
  Future<void> _traverseTree(
    OpeningTreeNode node,
    List<String> currentMoves,
    List<LeafNode> leaves,
    Map<String, List<String>> allPositions,
    int targetGameCount,
    bool isWhiteRepertoire,
    List<String> startingMoves,
    CoverageProgressCallback? onProgress,
  ) async {
    // Build current position
    Chess position = Chess.initial;
    for (final move in startingMoves) {
      final m = position.parseSan(move);
      if (m != null) position = position.play(m) as Chess;
    }
    for (final move in currentMoves) {
      final m = position.parseSan(move);
      if (m != null) position = position.play(m) as Chess;
    }

    final fen = position.fen;
    allPositions[normalizeFen(fen)] = List.from(currentMoves);

    // Check if this is a leaf node
    if (node.children.isEmpty) {
      final gameCount = await getGameCount(fen);
      final isGameOver = position.isGameOver;
      final isSealed = gameCount <= targetGameCount || isGameOver;

      String reason;
      if (isGameOver) {
        if (position.isCheckmate) {
          reason = 'Checkmate';
        } else if (position.isStalemate) {
          reason = 'Stalemate';
        } else {
          reason = 'Game over';
        }
      } else if (isSealed) {
        reason = 'Target reached (${_formatNumber(gameCount)} ≤ ${_formatNumber(targetGameCount)})';
      } else {
        reason = 'Analysis stopped (${_formatNumber(gameCount)} > ${_formatNumber(targetGameCount)})';
      }

      leaves.add(LeafNode(
        fen: fen,
        moves: currentMoves,
        gameCount: gameCount,
        isSealed: isSealed,
        reason: reason,
      ));
    } else {
      // Recurse into children
      for (final child in node.children.values) {
        await _traverseTree(
          child,
          [...currentMoves, child.move],
          leaves,
          allPositions,
          targetGameCount,
          isWhiteRepertoire,
          startingMoves,
          onProgress,
        );
      }
    }
  }

  /// Calculate unaccounted games (opponent moves not in repertoire)
  Future<int> _calculateUnaccounted(
    OpeningTree tree,
    Map<String, List<String>> allPositions,
    bool isWhiteRepertoire,
    List<String> startingMoves,
    CoverageProgressCallback? onProgress,
  ) async {
    int unaccounted = 0;
    int checked = 0;
    final total = allPositions.length;

    for (final entry in allPositions.entries) {
      checked++;
      if (checked % 10 == 0) {
        onProgress?.call('Checking unaccounted ($checked/$total)...', 0.7 + (0.25 * checked / total));
      }

      // Reconstruct position
      Chess position = Chess.initial;
      for (final move in startingMoves) {
        final m = position.parseSan(move);
        if (m != null) position = position.play(m) as Chess;
      }
      for (final move in entry.value) {
        final m = position.parseSan(move);
        if (m != null) position = position.play(m) as Chess;
      }

      // Only check opponent's turns
      final isWhiteTurn = position.turn == Side.white;
      final isMyTurn = (isWhiteRepertoire && isWhiteTurn) || (!isWhiteRepertoire && !isWhiteTurn);
      if (isMyTurn) continue;

      // Get the tree node for this position
      final node = _findNodeByFen(tree, entry.key);
      if (node == null || node.children.isEmpty) continue;

      // Get moves from repertoire
      final repertoireMoves = node.children.keys.toSet();

      // Get moves from API
      final apiMoves = await getMovesWithCounts(position.fen);

      // Count games from moves NOT in repertoire
      for (final moveData in apiMoves) {
        final moveSan = moveData['san'] as String?;
        if (moveSan != null && !repertoireMoves.contains(moveSan)) {
          final moveGames = (moveData['white'] as int? ?? 0) +
                           (moveData['black'] as int? ?? 0) +
                           (moveData['draws'] as int? ?? 0);
          unaccounted += moveGames;
        }
      }
    }

    return unaccounted;
  }

  /// Find a tree node by normalized FEN
  OpeningTreeNode? _findNodeByFen(OpeningTree tree, String normalizedFen) {
    if (tree.fenToNodes.containsKey(normalizedFen)) {
      final nodes = tree.fenToNodes[normalizedFen];
      if (nodes != null && nodes.isNotEmpty) {
        return nodes.first;
      }
    }
    return null;
  }

  /// Format large numbers for display
  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }

  /// Get cache statistics
  String get cacheStats {
    final total = _cacheHits + _cacheMisses;
    final hitRate = total > 0 ? (_cacheHits / total * 100).toStringAsFixed(1) : '0.0';
    return 'Cache: $_cacheHits hits, $_cacheMisses misses ($hitRate% hit rate), $_apiCalls API calls';
  }

  /// Clear the cache
  void clearCache() {
    _cache.clear();
    _cacheHits = 0;
    _cacheMisses = 0;
    _apiCalls = 0;
  }

  /// Check if currently rate limited
  bool get isRateLimited => _isRateLimited;
}

