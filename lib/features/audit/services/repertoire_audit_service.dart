/// Walks an existing repertoire tree (BFS) and emits findings about
/// move quality, missing opponent responses, and dead ends.
library;

import 'dart:async';
import 'dart:collection';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../models/opening_tree.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/eval_cache.dart';
import '../../../services/maia_factory.dart';
import '../../../services/probability_service.dart';
import '../../../utils/fen_utils.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import 'audit_config.dart';

/// Progress callback emitted periodically during an audit pass.
typedef AuditProgressCallback = void Function(AuditProgress progress);

class AuditProgress {
  final int nodesChecked;
  final int totalNodes;
  final int findingsCount;
  final String? currentFen;

  const AuditProgress({
    required this.nodesChecked,
    required this.totalNodes,
    required this.findingsCount,
    this.currentFen,
  });

  double get percent =>
      totalNodes > 0 ? (nodesChecked / totalNodes) * 100 : 0;
}

class RepertoireAuditService {
  final StockfishPool _pool = StockfishPool();
  final ProbabilityService _probService = ProbabilityService();
  final EvalCache _evalCache = EvalCache.instance;

  bool _cancelled = false;
  bool _paused = false;

  void cancel() => _cancelled = true;
  void pause() => _paused = true;
  void resume() => _paused = false;

  /// Run a full audit of [tree] starting from [startFen].
  ///
  /// If [startFen] is null, audits from the tree root.
  /// [isWhiteRepertoire] determines which side's moves are "ours".
  Future<AuditResult> audit({
    required OpeningTree tree,
    required bool isWhiteRepertoire,
    required AuditConfig config,
    String? startFen,
    AuditProgressCallback? onProgress,
    void Function(AuditFinding)? onFinding,
  }) async {
    _cancelled = false;
    _paused = false;
    final stopwatch = Stopwatch()..start();
    final findings = <AuditFinding>[];

    int ourMoveNodes = 0;
    int oppNodes = 0;
    int leafNodes = 0;
    int evalCacheHits = 0;
    int evalCacheMisses = 0;

    await _evalCache.init();

    final startNode = _resolveStartNode(tree, startFen);
    if (startNode == null) {
      return AuditResult(
        findings: [],
        nodesChecked: 0,
        ourMoveNodesChecked: 0,
        opponentNodesChecked: 0,
        leafNodesChecked: 0,
        elapsed: stopwatch.elapsed,
      );
    }

    // Count total nodes for progress reporting.
    final totalNodes = _countNodes(startNode, config.maxPly);

    // BFS traversal.
    final queue = Queue<_AuditQueueEntry>();
    final startPath = startNode.getMovePath();
    queue.add(_AuditQueueEntry(
      node: startNode, movePath: startPath, ply: 0, cumProb: 1.0,
    ));

    int checked = 0;

    while (queue.isNotEmpty) {
      if (_cancelled) break;
      while (_paused && !_cancelled) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_cancelled) break;

      final entry = queue.removeFirst();
      final node = entry.node;
      final ply = entry.ply;

      if (ply > config.maxPly) continue;

      checked++;

      // Determine whose turn it is at this node.
      final isWhiteTurn = _isWhiteTurnAtNode(node);
      final isOurTurn = (isWhiteRepertoire && isWhiteTurn) ||
          (!isWhiteRepertoire && !isWhiteTurn);

      // Report progress periodically.
      if (checked % 5 == 0 || checked == totalNodes) {
        onProgress?.call(AuditProgress(
          nodesChecked: checked,
          totalNodes: totalNodes,
          findingsCount: findings.length,
          currentFen: node.fen,
        ));
      }

      final isLeaf = node.children.isEmpty;

      if (isOurTurn && !isLeaf) {
        ourMoveNodes++;
        if (config.useStockfish) {
          final (newFindings, hits, misses) = await _checkOurMoves(
            node: node,
            movePath: entry.movePath,
            isWhiteRepertoire: isWhiteRepertoire,
            config: config,
            cumulativeProbability: entry.cumProb,
          );
          evalCacheHits += hits;
          evalCacheMisses += misses;
          for (final f in newFindings) {
            findings.add(f);
            onFinding?.call(f);
          }
        }
      } else if (!isOurTurn && !isLeaf) {
        oppNodes++;
        final newFindings = await _checkOpponentCoverage(
          node: node,
          tree: tree,
          movePath: entry.movePath,
          isWhiteRepertoire: isWhiteRepertoire,
          config: config,
          cumulativeProbability: entry.cumProb,
        );
        for (final f in newFindings) {
          findings.add(f);
          onFinding?.call(f);
        }
      }

      if (isLeaf) {
        leafNodes++;
        if (!isOurTurn) {
          final deadEndFindings = await _checkDeadEnd(
            node: node,
            movePath: entry.movePath,
            config: config,
            cumulativeProbability: entry.cumProb,
          );
          for (final f in deadEndFindings) {
            findings.add(f);
            onFinding?.call(f);
          }
        }
      }

      // Enqueue children with updated cumulative probability.
      // Opponent moves attenuate probability; our moves don't (we always play them).
      final parentTotal = node.children.values
          .fold<int>(0, (sum, c) => sum + c.gamesPlayed);
      for (final childEntry in node.children.entries) {
        final child = childEntry.value;
        double childProb = entry.cumProb;
        if (!isOurTurn && parentTotal > 0) {
          childProb *= child.gamesPlayed / parentTotal;
        }
        queue.add(_AuditQueueEntry(
          node: child,
          movePath: [...entry.movePath, childEntry.key],
          ply: ply + 1,
          cumProb: childProb,
        ));
      }
    }

    stopwatch.stop();

    // Final progress.
    onProgress?.call(AuditProgress(
      nodesChecked: checked,
      totalNodes: totalNodes,
      findingsCount: findings.length,
    ));

    return AuditResult(
      findings: findings,
      nodesChecked: checked,
      ourMoveNodesChecked: ourMoveNodes,
      opponentNodesChecked: oppNodes,
      leafNodesChecked: leafNodes,
      evalCacheHits: evalCacheHits,
      evalCacheMisses: evalCacheMisses,
      elapsed: stopwatch.elapsed,
    );
  }

  // ── Our-move quality check ───────────────────────────────────────────────

  /// Returns (findings, cacheHits, cacheMisses).
  Future<(List<AuditFinding>, int, int)> _checkOurMoves({
    required OpeningTreeNode node,
    required List<String> movePath,
    required bool isWhiteRepertoire,
    required AuditConfig config,
    required double cumulativeProbability,
  }) async {
    final findings = <AuditFinding>[];
    int cacheHits = 0;
    int cacheMisses = 0;
    if (node.children.isEmpty) return (findings, cacheHits, cacheMisses);

    final isWhiteTurn = _isWhiteTurnAtNode(node);

    try {
      final discovery = await _pool.discoverMoves(
        fen: node.fen,
        depth: config.evalDepth,
        multiPv: config.multiPv,
        isWhiteToMove: isWhiteTurn,
      );
      cacheMisses++;

      if (discovery.lines.isEmpty) return (findings, cacheHits, cacheMisses);

      // Best move from Stockfish (white-normalized cp).
      final bestLine = discovery.lines.first;
      final bestCp = bestLine.effectiveCp;
      final bestMoveSan = _uciToSan(node.fen, bestLine.moveUci);

      // Cache the position eval from the best line.
      _evalCache.putEvalCpWhite(node.fen, bestCp, config.evalDepth);

      // Check each repertoire move at this position.
      for (final repMoveEntry in node.children.entries) {
        final repMoveSan = repMoveEntry.key;
        final repMoveUci = _sanToUci(node.fen, repMoveSan);
        if (repMoveUci == null) continue;

        // Find this move in the discovery lines.
        int? repCp;
        for (final line in discovery.lines) {
          if (line.moveUci == repMoveUci) {
            repCp = line.effectiveCp;
            break;
          }
        }

        // If the move wasn't in MultiPV, try the cache, then evaluate.
        if (repCp == null) {
          final (cp, hit, miss) = await _evalAfterMove(
            node.fen, repMoveUci, config.evalDepth,
          );
          repCp = cp;
          cacheHits += hit;
          cacheMisses += miss;
        }

        // Cache the resulting position's eval for generation reuse.
        if (repCp != null) {
          final childFen = repMoveEntry.value.fen;
          _evalCache.putEvalCpWhite(childFen, repCp, config.evalDepth);
        }

        if (repCp == null) continue;

        // Compute eval loss from our perspective.
        // Positive = our move is worse than best.
        final evalLoss = isWhiteRepertoire
            ? (bestCp - repCp)
            : (repCp - bestCp);

        if (evalLoss >= config.mistakeThresholdCp) {
          findings.add(AuditFinding(
            type: AuditFindingType.mistake,
            severity: AuditSeverity.critical,
            movePath: [...movePath, repMoveSan],
            fen: node.fen,
            ourMove: repMoveSan,
            bestMove: bestMoveSan,
            evalLossCp: evalLoss,
            positionEvalCp: repCp,
            bestMoveEvalCp: bestCp,
            cumulativeProbability: cumulativeProbability,
          ));
        } else if (evalLoss >= config.inaccuracyThresholdCp) {
          findings.add(AuditFinding(
            type: AuditFindingType.inaccuracy,
            severity: AuditSeverity.warning,
            movePath: [...movePath, repMoveSan],
            fen: node.fen,
            ourMove: repMoveSan,
            bestMove: bestMoveSan,
            evalLossCp: evalLoss,
            positionEvalCp: repCp,
            bestMoveEvalCp: bestCp,
            cumulativeProbability: cumulativeProbability,
          ));
        }

        // Check for weak resulting position.
        final ourPerspectiveCp =
            isWhiteRepertoire ? repCp : -repCp;
        if (ourPerspectiveCp < config.weakPositionThresholdCp) {
          findings.add(AuditFinding(
            type: AuditFindingType.weakPosition,
            severity: AuditSeverity.warning,
            movePath: [...movePath, repMoveSan],
            fen: repMoveEntry.value.fen,
            positionEvalCp: repCp,
            cumulativeProbability: cumulativeProbability,
          ));
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Audit] Stockfish error at ${node.fen}: $e');
    }

    return (findings, cacheHits, cacheMisses);
  }

  // ── Opponent coverage check ──────────────────────────────────────────────

  Future<List<AuditFinding>> _checkOpponentCoverage({
    required OpeningTreeNode node,
    required OpeningTree tree,
    required List<String> movePath,
    required bool isWhiteRepertoire,
    required AuditConfig config,
    required double cumulativeProbability,
  }) async {
    final findings = <AuditFinding>[];
    final coveredMoves = node.children.keys.toSet();

    // Lichess Explorer check.
    if (config.useLichessDb) {
      try {
        final response = await _probService.getProbabilitiesForFen(
          node.fen,
          speeds: config.explorerSpeeds,
          ratings: config.explorerRatings,
        );
        if (response != null) {
          for (final move in response.moves) {
            if (move.total < config.minGames) continue;
            if (coveredMoves.contains(move.san)) continue;

            findings.add(AuditFinding(
              type: AuditFindingType.missingResponse,
              severity: move.total >= config.minGames * 3
                  ? AuditSeverity.critical
                  : AuditSeverity.warning,
              movePath: movePath,
              fen: node.fen,
              missingMove: move.san,
              gameCount: move.total,
              probability: move.playFraction,
              source: MissingResponseSource.lichess,
              cumulativeProbability: cumulativeProbability * move.playFraction,
            ));
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Audit] Lichess Explorer error at ${node.fen}: $e');
        }
      }
    }

    // Maia check.
    if (config.useMaia && MaiaFactory.isAvailable) {
      try {
        final maia = MaiaFactory.instance!;
        final result = await maia.evaluate(node.fen, config.maiaElo);

        for (final entry in result.policy.entries) {
          if (entry.value < config.minMaiaProb) continue;
          final san = _uciToSan(node.fen, entry.key);
          if (san == null) continue;
          if (coveredMoves.contains(san)) continue;

          // Skip if already reported by Lichess.
          final alreadyReported = findings.any((f) =>
              f.type == AuditFindingType.missingResponse &&
              f.missingMove == san);
          if (alreadyReported) continue;

          findings.add(AuditFinding(
            type: AuditFindingType.missingResponse,
            severity: entry.value >= 0.20
                ? AuditSeverity.critical
                : AuditSeverity.info,
            movePath: movePath,
            fen: node.fen,
            missingMove: san,
            probability: entry.value,
            source: MissingResponseSource.maia,
            cumulativeProbability: cumulativeProbability * entry.value,
          ));
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Audit] Maia error at ${node.fen}: $e');
        }
      }
    }

    return findings;
  }

  // ── Dead-end check ───────────────────────────────────────────────────────

  Future<List<AuditFinding>> _checkDeadEnd({
    required OpeningTreeNode node,
    required List<String> movePath,
    required AuditConfig config,
    required double cumulativeProbability,
  }) async {
    int continuations = 0;

    if (config.useLichessDb) {
      try {
        final response = await _probService.getProbabilitiesForFen(
          node.fen,
          speeds: config.explorerSpeeds,
          ratings: config.explorerRatings,
        );
        if (response != null) {
          continuations =
              response.moves.where((m) => m.total >= config.minGames).length;
        }
      } catch (_) {}
    }

    if (continuations < config.deadEndMinContinuations) {
      // Also check Maia if Lichess didn't find enough.
      if (config.useMaia && MaiaFactory.isAvailable) {
        try {
          final result =
              await MaiaFactory.instance!.evaluate(node.fen, config.maiaElo);
          final significantMoves =
              result.policy.values.where((p) => p >= config.minMaiaProb).length;
          continuations =
              continuations > significantMoves ? continuations : significantMoves;
        } catch (_) {}
      }
    }

    if (continuations >= config.deadEndMinContinuations) {
      return [
        AuditFinding(
          type: AuditFindingType.deadEnd,
          severity: continuations >= 4
              ? AuditSeverity.warning
              : AuditSeverity.info,
          movePath: movePath,
          fen: node.fen,
          continuationCount: continuations,
          cumulativeProbability: cumulativeProbability,
        ),
      ];
    }

    return [];
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  OpeningTreeNode? _resolveStartNode(OpeningTree tree, String? startFen) {
    if (startFen == null) return tree.root;
    final key = normalizeFen(startFen);
    final nodes = tree.fenToNodes[key];
    if (nodes != null && nodes.isNotEmpty) return nodes.first;
    if (normalizeFen(tree.root.fen) == key) return tree.root;
    return null;
  }

  int _countNodes(OpeningTreeNode root, int maxPly) {
    int count = 0;
    final queue = Queue<(OpeningTreeNode, int)>();
    queue.add((root, 0));
    while (queue.isNotEmpty) {
      final (node, ply) = queue.removeFirst();
      if (ply > maxPly) continue;
      count++;
      for (final child in node.children.values) {
        queue.add((child, ply + 1));
      }
    }
    return count;
  }

  bool _isWhiteTurnAtNode(OpeningTreeNode node) {
    return node.fen.contains(' w ');
  }

  String? _uciToSan(String fen, String uci) {
    try {
      final pos = Chess.fromSetup(Setup.parseFen(fen));
      final move = Move.parse(uci);
      if (move == null) return null;
      final (_, san) = pos.makeSan(move);
      return san;
    } catch (_) {
      return null;
    }
  }

  String? _sanToUci(String fen, String san) {
    try {
      final pos = Chess.fromSetup(Setup.parseFen(fen));
      final move = pos.parseSan(san);
      if (move == null) return null;
      return move.uci;
    } catch (_) {
      return null;
    }
  }

  /// Returns (whiteCp, cacheHits, cacheMisses).
  Future<(int?, int, int)> _evalAfterMove(
    String fen, String moveUci, int depth,
  ) async {
    try {
      final pos = Chess.fromSetup(Setup.parseFen(fen));
      final move = Move.parse(moveUci);
      if (move == null) return (null, 0, 0);
      final newPos = pos.play(move);
      final newFen = newPos.fen;

      // Check EvalCache first — shared with generation pipeline.
      final cached = await _evalCache.getEvalCpWhite(newFen, minDepth: depth);
      if (cached != null) return (cached, 1, 0);

      final result = await _pool.evaluateFen(newFen, depth);
      final isWhiteAfter = newPos.turn == Side.white;
      final whiteCp = isWhiteAfter
          ? (result.scoreCp ?? 0)
          : -(result.scoreCp ?? 0);

      // Write back so generation (and future audits) can reuse.
      _evalCache.putEvalCpWhite(newFen, whiteCp, depth);

      return (whiteCp, 0, 1);
    } catch (e) {
      if (kDebugMode) debugPrint('[Audit] Eval after move failed: $e');
      return (null, 0, 0);
    }
  }
}

class _AuditQueueEntry {
  final OpeningTreeNode node;
  final List<String> movePath;
  final int ply;
  final double cumProb;

  const _AuditQueueEntry({
    required this.node,
    required this.movePath,
    required this.ply,
    required this.cumProb,
  });
}
