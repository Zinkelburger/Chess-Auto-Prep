/// The audit's opponent-side sources: which replies the repertoire has no
/// answer to at a position, and how many continuations lie past a leaf.
///
/// Five sources, consulted in a fixed order so that the first to name a
/// move owns the finding: the Lichess Explorer and Maia say a reply is
/// *played*; ChessDB and Stockfish's MultiPV say it is *good* whether anyone
/// plays it or not; a clash tree built from books or an opponent's games says
/// it is on that file's menu. A source that fails at a position adds one
/// warning to the run and the others carry on.
library;

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'package:flutter/foundation.dart';

import '../../../models/explorer_response.dart';
import '../../../services/eval/db_move_list.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../services/probability_service.dart';
import '../../../utils/chess_utils.dart' as chess_utils;
import '../../../utils/fen_utils.dart';
import '../models/audit_finding.dart';
import 'audit_config.dart';
import 'engine_position_probe.dart';
import 'repertoire_walk.dart';

/// Finds the opponent replies a repertoire leaves unanswered.
///
/// One instance per audit run: it carries that run's config, the ChessDB
/// source (null when off), the optional clash tree and the warning sink.
class MissingReplyFinder {
  MissingReplyFinder({
    required this.config,
    required this.tree,
    required this._probe,
    required this._warn,
    ExternalMoveProvider? chessDb,
    this._clashTree,
    ProbabilityService? lichess,
  }) : _chessDb = config.useChessDb ? chessDb : null,
       _lichess = lichess ?? ProbabilityService.instance;

  /// A Lichess reply with this many times [AuditConfig.minGames] is critical.
  static const int _lichessCriticalGamesMultiplier = 3;

  /// A Maia or clash reply played at least this often is critical.
  static const double _criticalPlayRate = 0.20;

  /// A scored reply at most this far behind the opponent's best is critical.
  static const int _criticalGapCp = 10;

  /// With at most this many level replies a ChessDB gap is critical: in a
  /// quiet position ChessDB scores a dozen moves 0 and an uncovered one says
  /// little; where only two moves hold, the second is half the theory.
  static const int _sharpReplyCount = 4;

  final AuditConfig config;

  /// The repertoire, for transposition checks.
  final OpeningGraph tree;

  final EnginePositionProbe _probe;
  final void Function(String message) _warn;
  final ExternalMoveProvider? _chessDb;
  final OpeningGraph? _clashTree;
  final ProbabilityService _lichess;

  MaiaEvaluator? get _maia =>
      config.useMaia && MaiaFactory.isAvailable ? MaiaFactory.instance : null;

  /// Findings for the opponent replies at [entry] that the repertoire does
  /// not answer, in source order.
  Future<List<AuditFinding>> missingReplies(RepertoireWalkEntry entry) async {
    final gaps = _GapCollector(covered: entry.node.children.keys.toSet());
    if (config.useLichessDb) await _addLichessGaps(entry, gaps);
    if (_maia case final maia?) await _addMaiaGaps(entry, gaps, maia);
    if (_chessDb case final db?) await _addChessDbGaps(entry, gaps, db);
    if (config.useStockfish) await _addEngineGaps(entry, gaps);
    if (_clashTree case final clashTree?) {
      _addClashGaps(entry, gaps, clashTree);
    }
    return gaps.findings;
  }

  /// Opponent continuations past the leaf at [entry] (SAN), consulting the
  /// sources in order and stopping once
  /// [AuditConfig.deadEndMinContinuations] are known.
  Future<Set<String>> continuationsAt(RepertoireWalkEntry entry) async {
    final fen = entry.fen;
    final moves = <String>{};
    bool enough() => moves.length >= config.deadEndMinContinuations;

    if (config.useLichessDb) {
      try {
        final response = await _lichess.getProbabilitiesForFen(
          fen,
          speeds: config.explorerSpeeds,
          ratings: config.explorerRatings,
        );
        for (final move in response?.moves ?? const <ExplorerMove>[]) {
          if (move.total >= config.minGames) moves.add(move.san);
        }
      } catch (_) {
        _warn('Lichess could not check some line endings.');
      }
    }

    final maia = _maia;
    if (!enough() && maia != null) {
      try {
        final result = await maia.evaluate(fen, config.maiaElo);
        for (final MapEntry(key: uci, value: probability)
            in result.policy.entries) {
          if (probability < config.minMaiaProb) continue;
          final san = chess_utils.uciToSanOrNull(fen, uci);
          if (san != null) moves.add(san);
        }
      } catch (_) {
        _warn('Maia could not check some line endings.');
      }
    }

    final db = _chessDb;
    if (!enough() && db != null) {
      try {
        final list = await db.lookupMoves(fen);
        if (list.isEmpty) _warnChessDbEmpty();
        for (final move in list.withinCp(config.strongReplyWindowCp)) {
          final san = _dbMoveSan(fen, move);
          if (san.isNotEmpty) moves.add(san);
        }
      } catch (_) {
        _warn('ChessDB could not check some line endings.');
      }
    }

    return moves;
  }

  // ── Sources ──────────────────────────────────────────────────────────────

  Future<void> _addLichessGaps(
    RepertoireWalkEntry entry,
    _GapCollector gaps,
  ) async {
    try {
      final response = await _lichess.getProbabilitiesForFen(
        entry.fen,
        speeds: config.explorerSpeeds,
        ratings: config.explorerRatings,
      );
      for (final move in response?.moves ?? const <ExplorerMove>[]) {
        if (move.total < config.minGames) continue;
        if (!gaps.isUnanswered(move.san)) continue;
        gaps.add(
          _missingReply(
            entry,
            san: move.san,
            source: MissingResponseSource.lichess,
            severity:
                move.total >= config.minGames * _lichessCriticalGamesMultiplier
                ? AuditSeverity.critical
                : AuditSeverity.warning,
            gameCount: move.total,
            probability: move.playFraction,
            cumulativeProbability:
                entry.cumulativeProbability * move.playFraction,
          ),
        );
      }
    } catch (e) {
      _warn('Lichess could not check some positions.');
      _debug('Lichess Explorer error at ${entry.fen}: $e');
    }
  }

  Future<void> _addMaiaGaps(
    RepertoireWalkEntry entry,
    _GapCollector gaps,
    MaiaEvaluator maia,
  ) async {
    try {
      final result = await maia.evaluate(entry.fen, config.maiaElo);
      for (final MapEntry(key: uci, value: probability)
          in result.policy.entries) {
        if (probability < config.minMaiaProb) continue;
        final san = chess_utils.uciToSanOrNull(entry.fen, uci);
        if (san == null || !gaps.isUnanswered(san)) continue;
        gaps.add(
          _missingReply(
            entry,
            san: san,
            source: MissingResponseSource.maia,
            severity: probability >= _criticalPlayRate
                ? AuditSeverity.critical
                : AuditSeverity.info,
            probability: probability,
            cumulativeProbability: entry.cumulativeProbability * probability,
          ),
        );
      }
    } catch (e) {
      _warn('Maia could not check some positions.');
      _debug('Maia error at ${entry.fen}: $e');
    }
  }

  /// Replies the database scores close to the opponent's best, whether or
  /// not anyone plays them: the only source that can flag a move nobody has
  /// played yet.
  Future<void> _addChessDbGaps(
    RepertoireWalkEntry entry,
    _GapCollector gaps,
    ExternalMoveProvider db,
  ) async {
    try {
      final list = await db.lookupMoves(entry.fen);
      if (list.isEmpty) _warnChessDbEmpty();
      final best = list.bestStmCp;
      if (best == null) return;

      final good = list.withinCp(config.strongReplyWindowCp);
      final sharp = good.length <= _sharpReplyCount;
      for (final move in good) {
        final san = _dbMoveSan(entry.fen, move);
        if (san.isEmpty || !gaps.isUnanswered(san)) continue;
        // DbMove.stmCp is the opponent's view of the move; the finding
        // stores White-POV like every other eval on it.
        final gap = best - move.stmCp;
        gaps.add(
          _missingReply(
            entry,
            san: san,
            source: MissingResponseSource.chessDb,
            severity: gap <= _criticalGapCp && sharp
                ? AuditSeverity.critical
                : AuditSeverity.warning,
            evalLossCp: gap,
            continuationCount: good.length,
            positionEvalCp: entry.whiteToMove ? move.stmCp : -move.stmCp,
            bestMoveEvalCp: entry.whiteToMove ? best : -best,
            cumulativeProbability: entry.cumulativeProbability,
          ),
        );
      }
    } catch (e) {
      _warn('ChessDB could not check some positions.');
      _debug('ChessDB error at ${entry.fen}: $e');
    }
  }

  /// The MultiPV lines Stockfish rates close to the opponent's best.
  /// Narrower than ChessDB (it sees multiPv moves, not every move) but it
  /// knows every position, including the ones the database has never seen.
  Future<void> _addEngineGaps(
    RepertoireWalkEntry entry,
    _GapCollector gaps,
  ) async {
    try {
      final lines = await _probe.discover(
        entry.fen,
        depth: config.evalDepth,
        multiPv: config.multiPv,
      );
      if (lines.isEmpty) return;
      final bestWhite = lines.first.whiteCp;
      int toOpponent(int whiteCp) => entry.whiteToMove ? whiteCp : -whiteCp;
      final bestOpponent = toOpponent(bestWhite);
      for (final line in lines) {
        final gap = bestOpponent - toOpponent(line.whiteCp);
        if (gap > config.strongReplyWindowCp) continue;
        if (!gaps.isUnanswered(line.san)) continue;
        gaps.add(
          _missingReply(
            entry,
            san: line.san,
            source: MissingResponseSource.engine,
            severity: gap <= _criticalGapCp
                ? AuditSeverity.critical
                : AuditSeverity.warning,
            evalLossCp: gap,
            positionEvalCp: line.whiteCp,
            bestMoveEvalCp: bestWhite,
            cumulativeProbability: entry.cumulativeProbability,
          ),
        );
      }
    } catch (e) {
      _warn('Stockfish could not check some opponent replies.');
      _debug('Stockfish reply check error at ${entry.fen}: $e');
    }
  }

  /// Moves the clash tree (books, courses, an opponent's archive) plays at
  /// this position.
  void _addClashGaps(
    RepertoireWalkEntry entry,
    _GapCollector gaps,
    OpeningGraph clashTree,
  ) {
    final clashNodes = clashTree.fenToNodes[normalizeFen(entry.fen)];
    if (clashNodes == null) return;
    for (final clashNode in clashNodes) {
      final totalAtParent = clashNode.children.values.fold<int>(
        0,
        (sum, child) => sum + child.gamesPlayed,
      );
      for (final MapEntry(key: san, value: child)
          in clashNode.children.entries) {
        if (!gaps.isUnanswered(san)) continue;
        final probability = totalAtParent > 0
            ? child.gamesPlayed / totalAtParent
            : 0.0;
        gaps.add(
          _missingReply(
            entry,
            san: san,
            source: MissingResponseSource.clash,
            severity: probability >= _criticalPlayRate
                ? AuditSeverity.critical
                : AuditSeverity.info,
            gameCount: child.gamesPlayed,
            probability: probability,
            cumulativeProbability: entry.cumulativeProbability * probability,
          ),
        );
      }
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  AuditFinding _missingReply(
    RepertoireWalkEntry entry, {
    required String san,
    required MissingResponseSource source,
    required AuditSeverity severity,
    required double cumulativeProbability,
    int? gameCount,
    double? probability,
    int? evalLossCp,
    int? continuationCount,
    int? positionEvalCp,
    int? bestMoveEvalCp,
  }) => AuditFinding(
    type: AuditFindingType.missingResponse,
    severity: severity,
    movePath: entry.movePath,
    fen: entry.fen,
    missingMove: san,
    gameCount: gameCount,
    probability: probability,
    evalLossCp: evalLossCp,
    continuationCount: continuationCount,
    positionEvalCp: positionEvalCp,
    bestMoveEvalCp: bestMoveEvalCp,
    source: source,
    cumulativeProbability: cumulativeProbability,
    transposesIntoRepertoire: tree.doesMoveTranspose(entry.fen, san),
  );

  /// ChessDB stores UCI; convert strictly, falling back to the SAN the
  /// database sent (possibly empty).
  static String _dbMoveSan(String fen, DbMove move) =>
      chess_utils.uciToSanOrNull(fen, move.uci) ?? move.san;

  void _warnChessDbEmpty() => _warn(
    'ChessDB had no scored replies for some positions (unknown or unavailable).',
  );

  static void _debug(String message) {
    if (kDebugMode) debugPrint('[Audit] $message');
  }
}

/// The gaps found so far at one position, deduplicated across sources.
class _GapCollector {
  _GapCollector({required this.covered});

  /// Replies the repertoire answers.
  final Set<String> covered;

  final List<AuditFinding> findings = [];
  final Set<String> _reported = {};

  /// True when the repertoire does not answer [san] and no earlier source
  /// has flagged it.
  bool isUnanswered(String san) =>
      !covered.contains(san) && !_reported.contains(san);

  void add(AuditFinding finding) {
    _reported.add(finding.missingMove!);
    findings.add(finding);
  }
}
