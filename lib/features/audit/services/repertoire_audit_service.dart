/// Walks an existing repertoire tree (BFS) and emits findings about
/// move quality, missing opponent responses, and dead ends.
///
/// At each of our positions Stockfish rates the repertoire's moves against
/// its best; at each opponent position the [MissingReplyFinder] asks every
/// enabled source for replies the file does not answer; at each opponent
/// leaf the same sources decide whether the line stops where the game still
/// has choices.
library;

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';

import '../../../services/engine/stockfish_pool.dart';
import '../../../services/eval/chessdb_api_provider.dart';
import '../../../services/eval/db_move_list.dart';
import '../../../services/eval_cache.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../services/opening_tree_builder.dart';
import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../services/run_control.dart';
import '../../../utils/chess_utils.dart' as chess_utils;
import '../../../utils/fen_utils.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import 'audit_config.dart';
import 'engine_position_probe.dart';
import 'missing_reply_finder.dart';
import 'repertoire_walk.dart';

/// Progress callback emitted periodically during an audit pass.
typedef AuditProgressCallback = void Function(AuditProgress progress);

class AuditProgress {
  const AuditProgress({
    required this.nodesChecked,
    required this.totalNodes,
    required this.findingsCount,
    this.currentFen,
  });

  final int nodesChecked;
  final int totalNodes;
  final int findingsCount;
  final String? currentFen;

  double get percent => totalNodes > 0 ? (nodesChecked / totalNodes) * 100 : 0;
}

class RepertoireAuditService {
  /// [chessDbProvider] stands in for the chessdb.cn API — a test seam, and
  /// the hook for a local dump should the audit ever get one. Null means
  /// the live API, created per run when [AuditConfig.useChessDb] is on.
  RepertoireAuditService({
    ExternalMoveProvider? chessDbProvider,
    required StockfishPool pool,
    EvalCache? evalCache,
  }) : _chessDbOverride = chessDbProvider,
       _probe = EnginePositionProbe(pool: pool, evalCache: evalCache);

  /// A dead end with at least this many continuations is a warning rather
  /// than a note.
  static const int _deadEndWarningContinuations = 4;

  /// How deep a clash PGN is read; repertoire files rarely go further.
  static const int _clashTreeMaxDepth = 40;

  final EnginePositionProbe _probe;
  final ExternalMoveProvider? _chessDbOverride;

  /// Cooperative pause/cancel for the run in progress.
  final RunControl _control = RunControl();

  /// FENs checked in the current (or most recent) audit run.
  /// Useful for saving progress on cancellation.
  Set<String> get checkedFens => Set.unmodifiable(_checkedFens);
  final Set<String> _checkedFens = {};

  final Set<String> _warnings = {};
  List<String> get warnings => List.unmodifiable(_warnings);

  void cancel() => _control.cancel();
  void pause() => _control.pause();
  void resume() => _control.resume();

  /// Run a full audit of [tree] starting from [startFen].
  ///
  /// If [startFen] is null, audits from the tree root.
  /// [isWhiteRepertoire] determines which side's moves are "ours".
  ///
  /// Pass [skipFens] and [priorFindings] to resume a previously
  /// interrupted audit. Nodes whose FEN is in [skipFens] are traversed
  /// (so their children are enqueued) but not re-checked.
  Future<AuditResult> audit({
    required OpeningGraph tree,
    required bool isWhiteRepertoire,
    required AuditConfig config,
    String? startFen,
    AuditProgressCallback? onProgress,
    void Function(AuditFinding)? onFinding,
    Set<String> skipFens = const {},
    List<AuditFinding> priorFindings = const [],
    List<String> priorWarnings = const [],
  }) async {
    _control.reset();
    _probe.stats.reset();
    _warnings
      ..clear()
      ..addAll(priorWarnings);
    if (config.useMaia && !MaiaFactory.isAvailable) {
      _warnings.add('Maia is unavailable; common-reply checks were skipped.');
    }
    _checkedFens
      ..clear()
      ..addAll(skipFens);
    final stopwatch = Stopwatch()..start();
    final findings = <AuditFinding>[...priorFindings];
    final counts = _NodeCounts();

    await _probe.init();

    final startNode = _resolveStartNode(tree, startFen);
    if (startNode == null) {
      return AuditResult(
        findings: const [],
        nodesChecked: 0,
        ourMoveNodesChecked: 0,
        opponentNodesChecked: 0,
        leafNodesChecked: 0,
        elapsed: stopwatch.elapsed,
      );
    }

    final liveChessDb = config.useChessDb && _chessDbOverride == null
        ? ChessDbApiProvider()
        : null;
    await liveChessDb?.init();
    final replyFinder = MissingReplyFinder(
      config: config,
      tree: tree,
      probe: _probe,
      warn: _warnings.add,
      chessDb: _chessDbOverride ?? liveChessDb,
      clashTree: config.clashPgnPaths.isEmpty
          ? null
          : await _buildClashTree(config, isWhiteRepertoire),
    );

    final walk = RepertoireWalk(
      start: startNode,
      maxPly: config.maxPly,
      attenuatingSideIsWhite: !isWhiteRepertoire,
      control: _control,
    );

    void emit(Iterable<AuditFinding> found) {
      for (final finding in found) {
        findings.add(finding);
        onFinding?.call(finding);
      }
    }

    await walk.run(
      onProgress: (entry) => onProgress?.call(
        AuditProgress(
          nodesChecked: walk.visited,
          totalNodes: walk.totalNodes,
          findingsCount: findings.length,
          currentFen: entry.fen,
        ),
      ),
      visit: (entry) async {
        final isOurTurn = entry.whiteToMove == isWhiteRepertoire;
        final alreadyChecked = skipFens.contains(entry.fen);
        counts.tally(isOurTurn: isOurTurn, isLeaf: entry.isLeaf);

        if (!alreadyChecked) {
          if (entry.isLeaf) {
            if (!isOurTurn) emit(await _checkDeadEnd(entry, replyFinder));
          } else if (isOurTurn) {
            if (config.useStockfish) {
              emit(await _checkOurMoves(entry, isWhiteRepertoire, config));
            }
          } else {
            emit(await replyFinder.missingReplies(entry));
          }
          // Only now is the position checked. The session controller
          // snapshots [checkedFens] together with the findings it has been
          // handed at the moment of a cancel or app close; marking the node
          // before its engine calls returned put it in the skip set with its
          // findings still in flight, so a resumed audit never looked at it
          // again.
          _checkedFens.add(entry.fen);
        }
      },
    );

    stopwatch.stop();
    await liveChessDb?.flushQuota();

    onProgress?.call(
      AuditProgress(
        nodesChecked: walk.visited,
        totalNodes: walk.totalNodes,
        findingsCount: findings.length,
      ),
    );

    return AuditResult(
      findings: findings,
      warnings: warnings,
      nodesChecked: walk.visited,
      ourMoveNodesChecked: counts.ourMoveNodes,
      opponentNodesChecked: counts.opponentNodes,
      leafNodesChecked: counts.leafNodes,
      evalCacheHits: _probe.stats.hits,
      evalCacheMisses: _probe.stats.misses,
      elapsed: stopwatch.elapsed,
    );
  }

  // ── Our-move quality check ───────────────────────────────────────────────

  /// Rate every repertoire move at [entry] against Stockfish's best.
  Future<List<AuditFinding>> _checkOurMoves(
    RepertoireWalkEntry entry,
    bool isWhiteRepertoire,
    AuditConfig config,
  ) async {
    final findings = <AuditFinding>[];
    final node = entry.node;
    try {
      final lines = await _probe.discover(
        node.fen,
        depth: config.evalDepth,
        multiPv: config.multiPv,
        countAsLookup: true,
      );
      if (lines.isEmpty) {
        _warnings.add('Stockfish returned no evaluation for some positions.');
        return findings;
      }
      final best = lines.first;

      for (final MapEntry(key: repMoveSan, value: child)
          in node.children.entries) {
        final repMoveUci = chess_utils.sanToUci(node.fen, repMoveSan);
        if (repMoveUci == null) continue;

        final repCp = await _probe.evalAfterMove(
          node.fen,
          repMoveUci,
          lines: lines,
          depth: config.evalDepth,
        );
        if (repCp == null) {
          _warnings.add('Stockfish could not evaluate some repertoire moves.');
          continue;
        }
        // Cache the resulting position's eval for generation reuse.
        _probe.remember(child.fen, repCp, config.evalDepth);

        final movePath = [...entry.movePath, repMoveSan];
        // Positive = our move is worse than best.
        final evalLoss = isWhiteRepertoire
            ? best.whiteCp - repCp
            : repCp - best.whiteCp;
        final lossType = evalLoss >= config.mistakeThresholdCp
            ? AuditFindingType.mistake
            : evalLoss >= config.inaccuracyThresholdCp
            ? AuditFindingType.inaccuracy
            : null;
        if (lossType != null) {
          findings.add(
            AuditFinding(
              type: lossType,
              severity: lossType == AuditFindingType.mistake
                  ? AuditSeverity.critical
                  : AuditSeverity.warning,
              movePath: movePath,
              fen: node.fen,
              ourMove: repMoveSan,
              bestMove: best.san,
              evalLossCp: evalLoss,
              positionEvalCp: repCp,
              bestMoveEvalCp: best.whiteCp,
              cumulativeProbability: entry.cumulativeProbability,
            ),
          );
        }

        final ourPerspectiveCp = isWhiteRepertoire ? repCp : -repCp;
        if (ourPerspectiveCp < config.weakPositionThresholdCp) {
          findings.add(
            AuditFinding(
              type: AuditFindingType.weakPosition,
              severity: AuditSeverity.warning,
              movePath: movePath,
              fen: child.fen,
              positionEvalCp: repCp,
              cumulativeProbability: entry.cumulativeProbability,
            ),
          );
        }
      }
    } catch (e) {
      _warnings.add('Stockfish could not check some positions.');
      if (kDebugMode) debugPrint('[Audit] Stockfish error at ${node.fen}: $e');
    }
    return findings;
  }

  // ── Dead-end check ───────────────────────────────────────────────────────

  /// An opponent leaf where the sources still know continuations is a line
  /// the file stops too early.
  Future<List<AuditFinding>> _checkDeadEnd(
    RepertoireWalkEntry entry,
    MissingReplyFinder replyFinder,
  ) async {
    final continuations = await replyFinder.continuationsAt(entry);
    if (continuations.length < replyFinder.config.deadEndMinContinuations) {
      return const [];
    }
    return [
      AuditFinding(
        type: AuditFindingType.deadEnd,
        severity: continuations.length >= _deadEndWarningContinuations
            ? AuditSeverity.warning
            : AuditSeverity.info,
        movePath: entry.movePath,
        fen: entry.fen,
        continuationCount: continuations.length,
        uncoveredMoves: continuations.toList()..sort(),
        cumulativeProbability: entry.cumulativeProbability,
      ),
    ];
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Build a merged [OpeningGraph] from the configured clash PGN paths.
  ///
  /// With [AuditConfig.clashUsername] empty this merges every game in the
  /// files, which is what a book or course PGN wants. With a username set it
  /// filters to that player's games on [AuditConfig.clashUserIsWhite], which
  /// is what modeling a specific opponent's archive requires — their games on
  /// the other color say nothing about how they meet our repertoire.
  Future<OpeningGraph> _buildClashTree(
    AuditConfig config,
    bool isWhiteRepertoire,
  ) async {
    final allGames = <String>[];
    for (final path in config.clashPgnPaths) {
      try {
        final content = await io.File(path).readAsString();
        allGames.addAll(pgn.splitPgnIntoGames(content));
      } catch (e) {
        _warnings.add(
          'A clash PGN could not be read; its lines were not checked.',
        );
        if (kDebugMode) {
          debugPrint('[Audit] Failed to read clash PGN $path: $e');
        }
      }
    }
    return OpeningTreeBuilder.buildTree(
      pgnList: allGames,
      username: config.clashUsername,
      userIsWhite: config.clashUserIsWhite ?? isWhiteRepertoire,
      strictPlayerMatching: config.clashUsername.isNotEmpty,
      maxDepth: _clashTreeMaxDepth,
    );
  }

  OpeningNodeView? _resolveStartNode(OpeningGraph tree, String? startFen) {
    if (startFen == null) return tree.root;
    final key = normalizeFen(startFen);
    final nodes = tree.fenToNodes[key];
    if (nodes != null && nodes.isNotEmpty) return nodes.first;
    if (normalizeFen(tree.root.fen) == key) return tree.root;
    return null;
  }
}

/// How many positions of each kind a run visited.
class _NodeCounts {
  int ourMoveNodes = 0;
  int opponentNodes = 0;
  int leafNodes = 0;

  void tally({required bool isOurTurn, required bool isLeaf}) {
    if (isLeaf) {
      leafNodes++;
    } else if (isOurTurn) {
      ourMoveNodes++;
    } else {
      opponentNodes++;
    }
  }
}
