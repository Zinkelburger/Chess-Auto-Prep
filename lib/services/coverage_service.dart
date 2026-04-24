/// Coverage Calculator Service
/// Analyzes repertoire coverage using the Lichess Explorer API
library;

import 'dart:async';
import 'dart:convert';
import 'package:dartchess/dartchess.dart';
import '../models/opening_tree.dart';
import '../utils/fen_utils.dart';
import '../utils/chess_utils.dart';
import 'lichess_api_client.dart';
import 'maia_factory.dart';

/// Database types for Lichess Explorer
enum LichessDatabase {
  lichess,
  masters,
  player,
}

/// Leaf classification for coverage analysis
enum LeafCategory {
  covered,
  tooShallow,
  tooDeep,
}

/// Represents a leaf node in the repertoire analysis
class LeafNode {
  final String fen;
  final List<String> moves;
  final int gameCount;
  final LeafCategory category;
  final String reason;

  /// For tooDeep leaves: how many ply past the threshold point
  final int excessPly;

  LeafNode({
    required this.fen,
    required this.moves,
    required this.gameCount,
    required this.category,
    required this.reason,
    this.excessPly = 0,
  });

  bool get isCovered => category == LeafCategory.covered;

  String get moveString => moves.isEmpty ? '(root)' : moves.join(' ');
}

/// An opponent move not covered by the repertoire
class UnaccountedMove {
  final List<String> parentMoves;
  final String move;
  final int gameCount;
  final double probability;
  final String source; // "lichess" or "maia"

  UnaccountedMove({
    required this.parentMoves,
    required this.move,
    required this.gameCount,
    required this.probability,
    required this.source,
  });
}

/// Results from coverage analysis
class CoverageResult {
  final String rootFen;
  final List<String> rootMoves;
  final int rootGameCount;
  final double targetPercent;
  final int targetGameCount;
  final List<LeafNode> coveredLeaves;
  final List<LeafNode> tooShallowLeaves;
  final List<LeafNode> tooDeepLeaves;
  final List<UnaccountedMove> unaccountedMoves;
  final int totalCoveredGames;
  final int totalShallowGames;
  final int totalDeepGames;
  final int totalUnaccountedGames;

  CoverageResult({
    required this.rootFen,
    required this.rootMoves,
    required this.rootGameCount,
    required this.targetPercent,
    required this.targetGameCount,
    required this.coveredLeaves,
    required this.tooShallowLeaves,
    required this.tooDeepLeaves,
    required this.unaccountedMoves,
    required this.totalCoveredGames,
    required this.totalShallowGames,
    required this.totalDeepGames,
    required this.totalUnaccountedGames,
  });

  String get rootDescription {
    if (rootMoves.isEmpty) return 'Starting position';
    return rootMoves.join(' ');
  }

  double get coveragePercent {
    if (rootGameCount == 0) return 0.0;
    return (totalCoveredGames / rootGameCount) * 100;
  }

  double get shallowPercent {
    if (rootGameCount == 0) return 0.0;
    return (totalShallowGames / rootGameCount) * 100;
  }

  double get deepPercent {
    if (rootGameCount == 0) return 0.0;
    return (totalDeepGames / rootGameCount) * 100;
  }

  double get unaccountedPercent {
    if (rootGameCount == 0) return 0.0;
    return (totalUnaccountedGames / rootGameCount) * 100;
  }

  /// All leaves regardless of category
  List<LeafNode> get allLeaves => [...coveredLeaves, ...tooShallowLeaves, ...tooDeepLeaves];
}

/// Progress callback for coverage analysis
typedef CoverageProgressCallback = void Function(String message, double progress);

/// Coverage Calculator Service
class CoverageService {
  static const _lichessBaseUrl = 'https://explorer.lichess.ovh/lichess';
  static const _mastersBaseUrl = 'https://explorer.lichess.ovh/masters';
  static const _playerBaseUrl = 'https://explorer.lichess.ovh/player';

  /// Leaves extending this many ply past the first sub-threshold node
  /// are classified as "too deep".
  static const tooDeepThresholdPly = 4;

  final LichessDatabase database;
  final String ratings;
  final String speeds;
  final String? playerName;
  final String? playerColor;
  final bool useMaia;
  final int maiaElo;

  // Cache for FEN positions
  final Map<String, Map<String, dynamic>> _cache = {};
  int _cacheHits = 0;
  int _cacheMisses = 0;
  int _apiCalls = 0;

  CoverageService({
    this.database = LichessDatabase.lichess,
    this.ratings = '2000,2200,2500',
    this.speeds = 'blitz,rapid,classical',
    this.playerName,
    this.playerColor,
    this.useMaia = false,
    this.maiaElo = 2200,
  });

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

  Future<Map<String, dynamic>?> getPositionData(String fen) async {
    final cacheKey = normalizeFen(fen);

    if (_cache.containsKey(cacheKey)) {
      _cacheHits++;
      return _cache[cacheKey];
    }
    _cacheMisses++;

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

    _apiCalls++;
    final uri = Uri.parse(_baseUrl).replace(queryParameters: params);
    final response = await LichessApiClient().get(uri);

    if (response == null) return null;

    if (response.statusCode == 404) {
      final result = <String, dynamic>{
        'white': 0,
        'black': 0,
        'draws': 0,
        'moves': <dynamic>[],
      };
      _cache[cacheKey] = result;
      return result;
    }

    if (response.statusCode != 200) return null;

    final result =
        response.body.isNotEmpty ? _parseJson(response.body) : null;
    if (result != null) _cache[cacheKey] = result;
    return result;
  }

  static Map<String, dynamic>? _parseJson(String body) {
    try {
      return Map<String, dynamic>.from(
        const JsonDecoder().convert(body) as Map,
      );
    } catch (_) {
      return null;
    }
  }

  Future<int> getGameCount(String fen) async {
    final data = await getPositionData(fen);
    if (data == null) return 0;
    return (data['white'] as int? ?? 0) +
           (data['black'] as int? ?? 0) +
           (data['draws'] as int? ?? 0);
  }

  Future<List<Map<String, dynamic>>> getMovesWithCounts(String fen) async {
    final data = await getPositionData(fen);
    if (data == null) return [];
    final moves = data['moves'] as List<dynamic>? ?? [];
    return moves.cast<Map<String, dynamic>>();
  }

  (List<String>, String) findRepertoireRoot(OpeningTree tree) {
    final moves = <String>[];
    Chess position = Chess.initial;
    OpeningTreeNode current = tree.root;

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

  Future<CoverageResult> analyzeOpeningTree(
    OpeningTree tree, {
    required double targetPercent,
    required bool isWhiteRepertoire,
    CoverageProgressCallback? onProgress,
  }) async {
    onProgress?.call('Detecting root position...', 0.0);

    final (rootMoves, effectiveRootFen) = findRepertoireRoot(tree);

    onProgress?.call(
      'Root: ${rootMoves.isEmpty ? "Starting position" : rootMoves.join(" ")}',
      0.02
    );

    final rootGameCount = await getGameCount(effectiveRootFen);
    final targetGameCount = (rootGameCount * targetPercent / 100).round();

    onProgress?.call(
      'Root: ${_formatNumber(rootGameCount)} games → Target: ${_formatNumber(targetGameCount)} (${targetPercent.toStringAsFixed(1)}%)',
      0.05
    );

    final startingMoves = rootMoves;
    final leaves = <LeafNode>[];
    final allPositions = <String, List<String>>{};

    await _traverseTree(
      tree.root,
      [],
      leaves,
      allPositions,
      targetGameCount,
      isWhiteRepertoire,
      startingMoves,
      onProgress,
      null, // firstBelowThresholdPly — not yet below threshold at root
    );

    onProgress?.call('Found ${leaves.length} leaf positions', 0.6);

    final coveredLeaves = leaves.where((l) => l.category == LeafCategory.covered).toList();
    final tooShallowLeaves = leaves.where((l) => l.category == LeafCategory.tooShallow).toList();
    final tooDeepLeaves = leaves.where((l) => l.category == LeafCategory.tooDeep).toList();

    final totalCoveredGames = coveredLeaves.fold(0, (sum, l) => sum + l.gameCount);
    final totalShallowGames = tooShallowLeaves.fold(0, (sum, l) => sum + l.gameCount);
    final totalDeepGames = tooDeepLeaves.fold(0, (sum, l) => sum + l.gameCount);

    onProgress?.call('Calculating unaccounted moves...', 0.7);
    final unaccountedMoves = await _calculateUnaccounted(
      tree,
      allPositions,
      isWhiteRepertoire,
      startingMoves,
      rootGameCount,
      onProgress,
    );

    final totalUnaccountedGames = unaccountedMoves.fold(0, (sum, m) => sum + m.gameCount);

    onProgress?.call('Analysis complete!', 1.0);

    return CoverageResult(
      rootFen: effectiveRootFen,
      rootMoves: startingMoves,
      rootGameCount: rootGameCount,
      targetPercent: targetPercent,
      targetGameCount: targetGameCount,
      coveredLeaves: coveredLeaves,
      tooShallowLeaves: tooShallowLeaves,
      tooDeepLeaves: tooDeepLeaves,
      unaccountedMoves: unaccountedMoves,
      totalCoveredGames: totalCoveredGames,
      totalShallowGames: totalShallowGames,
      totalDeepGames: totalDeepGames,
      totalUnaccountedGames: totalUnaccountedGames,
    );
  }

  /// Traverse the opening tree and collect leaf nodes.
  ///
  /// [firstBelowThresholdPly] tracks the ply at which game count first
  /// dropped below the target.  If a leaf is 4+ ply deeper, it's "too deep".
  Future<void> _traverseTree(
    OpeningTreeNode node,
    List<String> currentMoves,
    List<LeafNode> leaves,
    Map<String, List<String>> allPositions,
    int targetGameCount,
    bool isWhiteRepertoire,
    List<String> startingMoves,
    CoverageProgressCallback? onProgress,
    int? firstBelowThresholdPly,
  ) async {
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

    final currentPly = currentMoves.length;

    if (node.children.isEmpty) {
      final gameCount = await getGameCount(fen);
      final isGameOver = position.isGameOver;
      final belowThreshold = gameCount <= targetGameCount || isGameOver;

      final effectiveFirstBelow = firstBelowThresholdPly ??
          (belowThreshold ? currentPly : null);

      LeafCategory category;
      String reason;

      if (isGameOver) {
        category = LeafCategory.covered;
        if (position.isCheckmate) {
          reason = 'Checkmate';
        } else if (position.isStalemate) {
          reason = 'Stalemate';
        } else {
          reason = 'Game over';
        }
      } else if (!belowThreshold) {
        category = LeafCategory.tooShallow;
        reason = 'Too shallow (${_formatNumber(gameCount)} > ${_formatNumber(targetGameCount)} target)';
      } else if (effectiveFirstBelow != null &&
                 currentPly - effectiveFirstBelow >= tooDeepThresholdPly) {
        category = LeafCategory.tooDeep;
        reason = '${currentPly - effectiveFirstBelow} ply past threshold';
      } else {
        category = LeafCategory.covered;
        reason = 'Covered (${_formatNumber(gameCount)} ≤ ${_formatNumber(targetGameCount)} target)';
      }

      leaves.add(LeafNode(
        fen: fen,
        moves: currentMoves,
        gameCount: gameCount,
        category: category,
        reason: reason,
        excessPly: effectiveFirstBelow != null
            ? currentPly - effectiveFirstBelow
            : 0,
      ));
    } else {
      // Check game count at this intermediate node to track threshold crossing
      int? updatedFirstBelow = firstBelowThresholdPly;
      if (updatedFirstBelow == null) {
        final gameCount = await getGameCount(fen);
        if (gameCount <= targetGameCount) {
          updatedFirstBelow = currentPly;
        }
      }

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
          updatedFirstBelow,
        );
      }
    }
  }

  /// Calculate unaccounted moves (opponent moves not in repertoire).
  /// Returns structured list with move details and source.
  Future<List<UnaccountedMove>> _calculateUnaccounted(
    OpeningTree tree,
    Map<String, List<String>> allPositions,
    bool isWhiteRepertoire,
    List<String> startingMoves,
    int rootGameCount,
    CoverageProgressCallback? onProgress,
  ) async {
    final result = <UnaccountedMove>[];
    int checked = 0;
    final total = allPositions.length;

    for (final entry in allPositions.entries) {
      checked++;
      if (checked % 10 == 0) {
        onProgress?.call('Checking unaccounted ($checked/$total)...', 0.7 + (0.25 * checked / total));
      }

      Chess position = Chess.initial;
      for (final move in startingMoves) {
        final m = position.parseSan(move);
        if (m != null) position = position.play(m) as Chess;
      }
      for (final move in entry.value) {
        final m = position.parseSan(move);
        if (m != null) position = position.play(m) as Chess;
      }

      final isWhiteTurn = position.turn == Side.white;
      final isMyTurn = (isWhiteRepertoire && isWhiteTurn) || (!isWhiteRepertoire && !isWhiteTurn);
      if (isMyTurn) continue;

      final node = _findNodeByFen(tree, entry.key);
      if (node == null || node.children.isEmpty) continue;

      final repertoireMoves = node.children.keys.toSet();
      final fen = position.fen;

      // Try Lichess DB first
      final apiMoves = await getMovesWithCounts(fen);

      if (apiMoves.isNotEmpty) {
        final totalGames = apiMoves.fold<int>(0, (s, m) =>
            s + (m['white'] as int? ?? 0) + (m['black'] as int? ?? 0) + (m['draws'] as int? ?? 0));

        for (final moveData in apiMoves) {
          final moveSan = moveData['san'] as String?;
          if (moveSan != null && !repertoireMoves.contains(moveSan)) {
            final moveGames = (moveData['white'] as int? ?? 0) +
                             (moveData['black'] as int? ?? 0) +
                             (moveData['draws'] as int? ?? 0);
            final prob = totalGames > 0 ? moveGames / totalGames : 0.0;
            result.add(UnaccountedMove(
              parentMoves: List<String>.from(entry.value),
              move: moveSan,
              gameCount: moveGames,
              probability: prob,
              source: 'lichess',
            ));
          }
        }
      } else if (useMaia && MaiaFactory.isAvailable && MaiaFactory.instance != null) {
        // Maia fallback when Lichess DB has no data
        try {
          final maiaResult = await MaiaFactory.instance!.evaluate(fen, maiaElo);
          for (final moveEntry in maiaResult.policy.entries) {
            final uci = moveEntry.key;
            final prob = moveEntry.value;
            if (prob < 0.02) continue;
            final san = uciToSan(fen, uci);
            if (!repertoireMoves.contains(san)) {
              result.add(UnaccountedMove(
                parentMoves: List<String>.from(entry.value),
                move: san,
                gameCount: 0,
                probability: prob,
                source: 'maia',
              ));
            }
          }
        } catch (_) {
          // Maia eval failed — skip this position
        }
      }
    }

    return result;
  }

  OpeningTreeNode? _findNodeByFen(OpeningTree tree, String normalizedFen) {
    if (tree.fenToNodes.containsKey(normalizedFen)) {
      final nodes = tree.fenToNodes[normalizedFen];
      if (nodes != null && nodes.isNotEmpty) {
        return nodes.first;
      }
    }
    return null;
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }

  String get cacheStats {
    final total = _cacheHits + _cacheMisses;
    final hitRate = total > 0 ? (_cacheHits / total * 100).toStringAsFixed(1) : '0.0';
    return 'Cache: $_cacheHits hits, $_cacheMisses misses ($hitRate% hit rate), $_apiCalls API calls';
  }

  void clearCache() {
    _cache.clear();
    _cacheHits = 0;
    _cacheMisses = 0;
    _apiCalls = 0;
  }

  bool get isRateLimited => LichessApiClient().isBackingOff;
}
