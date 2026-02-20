/// Self-contained DB-only repertoire generation that runs in a Dart isolate.
///
/// Runs the full DFS + Lichess Explorer HTTP calls on its own event loop,
/// completely independent of Flutter's UI thread.  This avoids the 30-70×
/// latency penalty caused by Flutter's rendering pipeline blocking async
/// continuations on the main isolate.
///
/// Uses [LichessApiClient.fetchExplorer] for HTTP + parsing, so there is
/// exactly one JSON parser for Explorer responses across the entire app.
library;

import 'dart:isolate';

import 'package:dartchess/dartchess.dart';

import '../models/explorer_response.dart';
import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import 'lichess_api_client.dart';

// ── Messages sent TO the isolate ────────────────────────────────────────

class DbOnlyIsolateRequest {
  final SendPort resultPort;
  final String startFen;
  final bool isWhiteRepertoire;
  final double cumulativeProbabilityCutoff;
  final int maxDepthPly;
  final String? authToken;
  final String variant;
  final String speeds;
  final String ratings;

  const DbOnlyIsolateRequest({
    required this.resultPort,
    required this.startFen,
    required this.isWhiteRepertoire,
    this.cumulativeProbabilityCutoff = 0.001,
    this.maxDepthPly = 15,
    this.authToken,
    this.variant = 'standard',
    this.speeds = 'blitz,rapid,classical',
    this.ratings = '1800,2000,2200,2500',
  });
}

// ── Messages sent FROM the isolate ──────────────────────────────────────

sealed class DbOnlyIsolateMsg {}

class DbOnlyProgress extends DbOnlyIsolateMsg {
  final int nodesVisited;
  final int linesGenerated;
  final int currentDepth;
  final String message;

  DbOnlyProgress({
    required this.nodesVisited,
    required this.linesGenerated,
    required this.currentDepth,
    required this.message,
  });
}

class DbOnlyLine extends DbOnlyIsolateMsg {
  final List<String> movesSan;
  final double cumulativeProbability;

  DbOnlyLine({required this.movesSan, required this.cumulativeProbability});
}

class DbOnlyDone extends DbOnlyIsolateMsg {
  final int nodesVisited;
  final int linesGenerated;
  final int dbCalls;
  final int dbCacheHits;
  final int elapsedMs;

  DbOnlyDone({
    required this.nodesVisited,
    required this.linesGenerated,
    required this.dbCalls,
    required this.dbCacheHits,
    required this.elapsedMs,
  });
}

class DbOnlyLog extends DbOnlyIsolateMsg {
  final String message;
  DbOnlyLog(this.message);
}

/// Port the isolate sends back so the main thread can request cancellation.
class DbOnlyCancelPort extends DbOnlyIsolateMsg {
  final SendPort cancelPort;
  DbOnlyCancelPort(this.cancelPort);
}

// ── Isolate entry point (top-level function) ────────────────────────────

Future<void> dbOnlyIsolateEntry(DbOnlyIsolateRequest req) async {
  final send = req.resultPort;

  final cancelPort = ReceivePort();
  send.send(DbOnlyCancelPort(cancelPort.sendPort));

  bool cancelled = false;
  cancelPort.listen((_) => cancelled = true);

  final runner = _IsolateRunner(
    sendPort: send,
    authToken: req.authToken,
    variant: req.variant,
    speeds: req.speeds,
    ratings: req.ratings,
    isCancelled: () => cancelled,
  );

  final sw = Stopwatch()..start();

  runner._log('═══ Generation START (isolate) ═══');
  runner._log('Start FEN: ${req.startFen}');
  runner._log('White repertoire: ${req.isWhiteRepertoire}');
  runner._log('Max depth: ${req.maxDepthPly} ply');
  runner._log('Cum prob cutoff: ${req.cumulativeProbabilityCutoff}');

  await runner._dfs(
    startFen: req.startFen,
    isWhiteRepertoire: req.isWhiteRepertoire,
    cumulativeProbabilityCutoff: req.cumulativeProbabilityCutoff,
    maxDepthPly: req.maxDepthPly,
    fen: req.startFen,
    depth: 0,
    cumulativeProb: 1.0,
    lineSan: const [],
  );

  sw.stop();
  runner._log('═══ Generation END (isolate) ═══');
  runner._log(
      'Time: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
  runner._log(
      'Nodes: ${runner._nodesVisited}, Lines: ${runner._linesGenerated}');
  runner._log(
      'DB calls: ${runner._dbCalls} (cache hits: ${runner._dbCacheHits})');

  send.send(DbOnlyDone(
    nodesVisited: runner._nodesVisited,
    linesGenerated: runner._linesGenerated,
    dbCalls: runner._dbCalls,
    dbCacheHits: runner._dbCacheHits,
    elapsedMs: sw.elapsedMilliseconds,
  ));

  runner._client.close();
  cancelPort.close();
}

// ── Internal runner (owns HTTP client, cache, counters) ─────────────────

/// Minimum play rate (0–100) for a move to be considered as our response.
const double _kMinOurMovePlayRate = 1.0;

/// Minimum play fraction (0–1) for an opponent reply to be branched on.
const double _kMinOpponentPlayFraction = 0.01;

class _IsolateRunner {
  final SendPort sendPort;
  final String? authToken;
  final String variant;
  final String speeds;
  final String ratings;
  final bool Function() isCancelled;

  late final LichessApiClient _client;
  final Map<String, ExplorerResponse?> _dbCache = {};

  int _nodesVisited = 0;
  int _linesGenerated = 0;
  int _dbCalls = 0;
  int _dbCacheHits = 0;

  _IsolateRunner({
    required this.sendPort,
    required this.authToken,
    required this.variant,
    required this.speeds,
    required this.ratings,
    required this.isCancelled,
  }) {
    _client = LichessApiClient.withToken(authToken);
  }

  void _log(String msg) {
    sendPort.send(DbOnlyLog('[Gen] $msg'));
  }

  void _sendProgress(int depth) {
    sendPort.send(DbOnlyProgress(
      nodesVisited: _nodesVisited,
      linesGenerated: _linesGenerated,
      currentDepth: depth,
      message: 'd=$depth  '
          '(${_nodesVisited}n ${_linesGenerated}L  db=$_dbCalls)',
    ));
  }

  // ── DFS ───────────────────────────────────────────────────────────────

  Future<void> _dfs({
    required String startFen,
    required bool isWhiteRepertoire,
    required double cumulativeProbabilityCutoff,
    required int maxDepthPly,
    required String fen,
    required int depth,
    required double cumulativeProb,
    required List<String> lineSan,
  }) async {
    if (isCancelled()) return;

    _nodesVisited++;
    final indent = '│ ' * depth;
    final lastMove = lineSan.isNotEmpty ? lineSan.last : '(root)';
    _log('$indent┌ DB#$_nodesVisited  d=$depth  $lastMove  '
        'cumProb=${(cumulativeProb * 100).toStringAsFixed(2)}%');

    _sendProgress(depth);

    final pos = Chess.fromSetup(Setup.parseFen(fen));
    final isWhiteToMove =
        fen.split(' ').length >= 2 && fen.split(' ')[1] == 'w';
    final isOurMove = isWhiteToMove == isWhiteRepertoire;

    final reachedStop = depth >= maxDepthPly ||
        cumulativeProb < cumulativeProbabilityCutoff;

    if (reachedStop || pos.legalMoves.isEmpty) {
      String reason = 'legal moves empty';
      if (depth >= maxDepthPly) reason = 'max depth';
      if (cumulativeProb < cumulativeProbabilityCutoff) {
        reason = 'cum prob too low';
      }
      if (lineSan.isNotEmpty) {
        var finalLine = lineSan;
        if (isOurMove && pos.legalMoves.isNotEmpty) {
          final response = await _findOurBestResponse(fen, isWhiteRepertoire);
          if (response != null) finalLine = [...lineSan, response];
        }
        final endsWithOurMove =
            !isOurMove || finalLine.length > lineSan.length;
        if (endsWithOurMove) {
          _linesGenerated++;
          sendPort.send(DbOnlyLine(
            movesSan: finalLine,
            cumulativeProbability: cumulativeProb,
          ));
          _log('$indent│ ★ LINE #$_linesGenerated: ${finalLine.join(" ")}');
        }
      }
      _log('$indent└ LEAF ($reason)');
      return;
    }

    final dbData = await _getDbData(fen);
    if (dbData == null || dbData.moves.isEmpty) {
      _log('$indent└ LEAF (no DB data)');
      return;
    }

    if (isOurMove) {
      final best = dbData.bestMoveForSide(
        asWhite: isWhiteRepertoire,
        minPlayRate: _kMinOurMovePlayRate,
      );
      if (best == null) {
        _log('$indent└ LEAF (no viable DB moves)');
        return;
      }
      final bestWr = best.winRateFor(asWhite: isWhiteRepertoire);
      _log('$indent│ OUR: ${best.san} '
          'wr=${(bestWr * 100).toStringAsFixed(1)}% '
          'p=${best.playRate.toStringAsFixed(1)}%');

      final childFen = playUciMove(fen, best.uci);
      if (childFen == null) return;

      await _dfs(
        startFen: startFen,
        isWhiteRepertoire: isWhiteRepertoire,
        cumulativeProbabilityCutoff: cumulativeProbabilityCutoff,
        maxDepthPly: maxDepthPly,
        fen: childFen,
        depth: depth + 1,
        cumulativeProb: cumulativeProb,
        lineSan: [...lineSan, best.san],
      );
    } else {
      final replies = <(String uci, String san, double prob)>[];
      for (final move in dbData.moves) {
        if (move.uci.isEmpty) continue;
        final prob = move.playFraction;
        if (prob < _kMinOpponentPlayFraction) continue;
        replies.add((move.uci, uciToSan(fen, move.uci), prob));
      }
      _log('$indent│ OPP: ${replies.length} replies');

      for (final (uci, san, prob) in replies) {
        if (isCancelled()) break;

        final childFen = playUciMove(fen, uci);
        if (childFen == null) continue;

        await _dfs(
          startFen: startFen,
          isWhiteRepertoire: isWhiteRepertoire,
          cumulativeProbabilityCutoff: cumulativeProbabilityCutoff,
          maxDepthPly: maxDepthPly,
          fen: childFen,
          depth: depth + 1,
          cumulativeProb: cumulativeProb * prob,
          lineSan: [...lineSan, san],
        );
      }
    }
    _log('$indent└ done d=$depth');
  }

  // ── Leaf extension ────────────────────────────────────────────────────

  Future<String?> _findOurBestResponse(
    String fen,
    bool isWhiteRepertoire,
  ) async {
    final dbData = await _getDbData(fen);
    final best = dbData?.bestMoveForSide(
      asWhite: isWhiteRepertoire,
      minPlayRate: _kMinOurMovePlayRate,
    );
    return best?.san;
  }

  // ── DB fetch (own HTTP client, own cache, own event loop) ─────────────

  Future<ExplorerResponse?> _getDbData(String fen) async {
    if (_dbCache.containsKey(fen)) {
      _dbCacheHits++;
      return _dbCache[fen];
    }
    _dbCalls++;
    final sw = Stopwatch()..start();
    final data = await _client.fetchExplorer(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
    );
    _log('  DB#$_dbCalls ${sw.elapsedMilliseconds}ms  '
        '${data?.moves.length ?? 0} moves  '
        '${data?.totalGames ?? 0} games');
    _dbCache[fen] = data;
    return data;
  }
}
