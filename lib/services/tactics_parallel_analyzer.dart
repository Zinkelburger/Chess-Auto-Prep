/// Parallel tactics analysis using one Stockfish process per CPU core.
///
/// Distributes games across multiple Dart isolates, each running its own
/// Stockfish binary. Results (positions, progress) stream back to the main
/// isolate in real time.
///
/// Only imported on native platforms (desktop) via conditional import.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:dartchess_webok/dartchess_webok.dart';
import 'package:chess/chess.dart' as chess;

import '../models/tactics_position.dart';
import 'process_connection.dart';

// ════════════════════════════════════════════════════════════════
// Public API (called from main isolate)
// ════════════════════════════════════════════════════════════════

/// Whether parallel multi-core analysis is available on this platform.
bool get isParallelAnalysisAvailable =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Number of logical CPU cores reported by the host OS.
int get availableProcessors => Platform.numberOfProcessors;

/// Analyze multiple games in parallel using one Stockfish instance per core.
///
/// [gameTasks] – list of `{gameText, globalIndex, gameId}` maps.
/// [onPositionFound] – called on the main isolate as each position is found.
/// [onGameComplete] – called with the gameId when a game finishes analysis.
///
/// Returns all discovered [TacticsPosition]s when every game is done.
Future<List<TacticsPosition>> analyzeGamesParallel({
  required List<Map<String, dynamic>> gameTasks,
  required String username,
  required int depth,
  required int totalGames,
  int? maxCores,
  Function(String)? progressCallback,
  void Function(TacticsPosition)? onPositionFound,
  void Function(String)? onGameComplete,
}) async {
  // Resolve Stockfish path on main isolate (requires platform channels).
  final stockfishPath = await ProcessConnection.resolveExecutablePath();

  // Determine worker count.
  // If maxCores is specified by the user, respect it (clamped to safe range).
  // Otherwise, leave 1 core for the main isolate, cap at 8.
  final coreLimit = maxCores ?? math.max(1, Platform.numberOfProcessors - 1);
  final numWorkers = math.min(
    coreLimit.clamp(1, Platform.numberOfProcessors),
    math.min(8, gameTasks.length),
  );

  progressCallback?.call(
    'Starting parallel analysis: ${gameTasks.length} games '
    'across $numWorkers cores...',
  );

  // Distribute games round-robin across workers.
  final workerBatches =
      List.generate(numWorkers, (_) => <Map<String, dynamic>>[]);
  for (int i = 0; i < gameTasks.length; i++) {
    workerBatches[i % numWorkers].add(gameTasks[i]);
  }

  // ── Build lookup for original game order ─────────────────
  // Map gameId → index in gameTasks so we can sort results later.
  final gameOrder = <String, int>{};
  for (int i = 0; i < gameTasks.length; i++) {
    gameOrder[gameTasks[i]['gameId'] as String] = i;
  }

  // ── Spawn workers and collect results ──────────────────────
  // Buffer positions per-game so each game's tactics stay grouped.
  final gamePositions = <String, List<TacticsPosition>>{};
  int completedGames = 0;
  int totalPositionsFound = 0;

  final completers = <Completer<void>>[];
  final isolates = <Isolate>[];
  final receivePorts = <ReceivePort>[];

  for (int w = 0; w < numWorkers; w++) {
    if (workerBatches[w].isEmpty) continue;

    final receivePort = ReceivePort();
    receivePorts.add(receivePort);
    final completer = Completer<void>();
    completers.add(completer);

    receivePort.listen((message) {
      if (message is! Map) return;
      final type = message['type'] as String;

      switch (type) {
        case 'position':
          final data = Map<String, dynamic>.from(message['data'] as Map);
          final pos = TacticsPosition.fromJson(data);
          final gameId = data['game_id'] as String? ?? '';
          gamePositions.putIfAbsent(gameId, () => []).add(pos);
          totalPositionsFound++;

        case 'gameComplete':
          completedGames++;
          onGameComplete?.call(message['gameId'] as String);
          progressCallback?.call(
            'Analyzed $completedGames/${gameTasks.length} games '
            '($totalPositionsFound tactics found)...',
          );

        case 'error':
          print('[Worker $w] ${message['message']}');

        case 'done':
          if (!completer.isCompleted) completer.complete();
      }
    });

    final isolate = await Isolate.spawn(
      _analysisWorkerEntryPoint,
      <dynamic>[
        receivePort.sendPort,
        <String, dynamic>{
          'stockfishPath': stockfishPath,
          'games': workerBatches[w],
          'username': username,
          'depth': depth,
          'totalGames': totalGames,
          'workerIndex': w,
        },
      ],
    );
    isolates.add(isolate);
  }

  // Wait for every worker (with a generous safety timeout).
  try {
    await Future.wait(completers.map((c) => c.future)).timeout(
      Duration(minutes: math.max(5, gameTasks.length * 2)),
    );
  } on TimeoutException {
    print('Parallel analysis timed out');
  }

  // Cleanup.
  for (final rp in receivePorts) {
    rp.close();
  }
  for (final iso in isolates) {
    iso.kill(priority: Isolate.beforeNextEvent);
  }

  // ── Assemble results in original game order ────────────────
  // Each game's positions are already in move-order (workers process
  // moves sequentially). We just need to arrange the *games* in the
  // same order they appeared in the input.
  final sortedGameIds = gamePositions.keys.toList()
    ..sort((a, b) => (gameOrder[a] ?? 999).compareTo(gameOrder[b] ?? 999));

  final positions = <TacticsPosition>[];
  for (final gameId in sortedGameIds) {
    final gamePositionsList = gamePositions[gameId]!;
    positions.addAll(gamePositionsList);
    // Emit positions game-by-game so DB writes are grouped.
    for (final pos in gamePositionsList) {
      onPositionFound?.call(pos);
    }
  }

  return positions;
}

// ════════════════════════════════════════════════════════════════
// Worker isolate  (runs in a child isolate — NO Flutter deps)
// ════════════════════════════════════════════════════════════════

/// Entry point for each analysis worker isolate.
///
/// [args] is `[SendPort, Map<String, dynamic> config]`.
void _analysisWorkerEntryPoint(List<dynamic> args) async {
  final SendPort resultPort = args[0] as SendPort;
  final config = Map<String, dynamic>.from(args[1] as Map);

  final stockfishPath = config['stockfishPath'] as String;
  final games = (config['games'] as List)
      .map((g) => Map<String, dynamic>.from(g as Map))
      .toList();
  final username = config['username'] as String;
  final depth = config['depth'] as int;
  final workerIndex = config['workerIndex'] as int;

  _WorkerStockfish? stockfish;

  try {
    stockfish = await _WorkerStockfish.start(stockfishPath);

    for (final gameInfo in games) {
      final gameText = gameInfo['gameText'] as String;
      final globalIndex = gameInfo['globalIndex'] as int;
      final gameId = gameInfo['gameId'] as String;

      try {
        await _analyzeGameInWorker(
          stockfish: stockfish,
          gameText: gameText,
          username: username,
          depth: depth,
          gameId: gameId,
          resultPort: resultPort,
        );
      } catch (e) {
        resultPort.send(<String, dynamic>{
          'type': 'error',
          'message': 'Game $globalIndex: $e',
        });
      }

      // Always mark game as complete (even on error, to avoid re-analysis).
      resultPort.send(<String, dynamic>{
        'type': 'gameComplete',
        'gameId': gameId,
      });
    }
  } catch (e) {
    resultPort.send(<String, dynamic>{
      'type': 'error',
      'message': 'Worker $workerIndex failed to start: $e',
    });
  } finally {
    stockfish?.dispose();
    resultPort.send(<String, dynamic>{'type': 'done'});
  }
}

/// Analyze a single game within a worker isolate.
Future<void> _analyzeGameInWorker({
  required _WorkerStockfish stockfish,
  required String gameText,
  required String username,
  required int depth,
  required String gameId,
  required SendPort resultPort,
}) async {
  final game = PgnGame.parsePgn(gameText);

  final white = (game.headers['White'] ?? '').toLowerCase();
  final black = (game.headers['Black'] ?? '').toLowerCase();
  final usernameLower = username.toLowerCase();

  chess.Color? userColor;
  if (white == usernameLower) {
    userColor = chess.Color.WHITE;
  } else if (black == usernameLower) {
    userColor = chess.Color.BLACK;
  } else if (white.contains(usernameLower)) {
    userColor = chess.Color.WHITE;
  } else if (black.contains(usernameLower)) {
    userColor = chess.Color.BLACK;
  } else {
    return; // Can't determine user colour – skip silently.
  }

  // Linearize moves from the PGN tree.
  final moves = <String>[];
  var node = game.moves;
  while (node.children.isNotEmpty) {
    final child = node.children.first;
    moves.add(child.data.san);
    node = child;
  }

  final chessGame = chess.Chess();
  int moveNumber = 1;

  for (final san in moves) {
    final isUserTurn = chessGame.turn == userColor;

    if (isUserTurn) {
      // 1. Evaluate BEFORE the user's move.
      final evalA = await stockfish.evaluate(chessGame.fen, depth);

      final fenBefore = chessGame.fen;
      chessGame.move(san);

      // Skip terminal positions (checkmate / stalemate).
      if (chessGame.game_over) {
        if (chessGame.turn == chess.Color.WHITE) moveNumber++;
        continue;
      }

      // 2. Evaluate AFTER the user's move.
      final evalB = await stockfish.evaluate(chessGame.fen, depth);

      // 3. Calculate win-chance delta (normalised to user's perspective).
      int cpA = evalA.effectiveCp;
      int cpB = evalB.effectiveCp;

      if (userColor == chess.Color.BLACK) {
        cpA = -cpA;
        cpB = -cpB;
      }

      final wcBefore = _winningChances(cpA);
      final wcAfter = _winningChances(cpB);
      final delta = wcBefore - wcAfter;

      final isBlunder = delta >= 0.3;
      final isMistake = delta >= 0.2 && delta < 0.3;

      if ((isBlunder || isMistake) && evalA.pv.isNotEmpty) {
        final bestMoveUci = evalA.pv.first;

        // Build correct line from PV, extending for tactical sequences.
        // If the user's move is a check (+), capture (x), or checkmate (#),
        // keep consuming the PV to include the opponent's response and the
        // next user move, up to a maximum of 5 user moves.
        final correctLine = <String>[];
        final tempGame = chess.Chess.fromFEN(fenBefore);

        int userMoveCount = 0;
        const maxUserMoves = 5;

        for (int i = 0; i < evalA.pv.length; i++) {
          final sanMove = _makeUciMoveAndGetSan(tempGame, evalA.pv[i]);
          if (sanMove == null) break;

          final isUserMove = (i % 2 == 0);

          if (isUserMove) {
            correctLine.add(sanMove);
            userMoveCount++;

            if (userMoveCount >= maxUserMoves) break;

            final isTactical = sanMove.contains('x') ||
                sanMove.contains('+') ||
                sanMove.contains('#');
            if (!isTactical) break;
          } else {
            correctLine.add(sanMove);
          }
        }

        // Ensure the line always ends on a user move.
        if (correctLine.length > 1 && correctLine.length.isEven) {
          correctLine.removeLast();
        }

        final bestMoveSan = _formatUciToSan(fenBefore, bestMoveUci);
        final wpBefore = _winPercent(cpA);
        final wpAfter = _winPercent(cpB);
        final mistakeType = isBlunder ? '??' : '?';
        final label = isBlunder ? 'Blunder' : 'Mistake';
        final analysis =
            '$label. Win chance dropped from ${wpBefore.toStringAsFixed(1)}% '
            'to ${wpAfter.toStringAsFixed(1)}% '
            '(${delta.toStringAsFixed(1)}%). Best was $bestMoveSan.';

        // Stream the position back immediately.
        resultPort.send(<String, dynamic>{
          'type': 'position',
          'data': <String, dynamic>{
            'fen': fenBefore,
            'user_move': san,
            'correct_line': correctLine,
            'mistake_type': mistakeType,
            'mistake_analysis': analysis,
            'position_context':
                'Move $moveNumber, '
                '${userColor == chess.Color.WHITE ? 'White' : 'Black'} to play',
            'game_white': game.headers['White'] ?? '',
            'game_black': game.headers['Black'] ?? '',
            'game_result': game.headers['Result'] ?? '*',
            'game_date': game.headers['Date'] ?? '',
            'game_id': gameId,
          },
        });
      }
    } else {
      // Opponent's move – just advance the board.
      chessGame.move(san);
    }

    if (chessGame.turn == chess.Color.WHITE) moveNumber++;
  }
}

// ════════════════════════════════════════════════════════════════
// Analysis helpers (duplicated from TacticsImportService because
// isolates cannot call instance methods on the main isolate)
// ════════════════════════════════════════════════════════════════

const double _multiplier = -0.00368208;

double _winningChances(int centipawns) {
  final capped = centipawns.clamp(-1000, 1000);
  return 2 / (1 + math.exp(_multiplier * capped)) - 1;
}

double _winPercent(int centipawns) {
  return 50 + 50 * _winningChances(centipawns);
}

String? _makeUciMoveAndGetSan(chess.Chess game, String uci) {
  final from = uci.substring(0, 2);
  final to = uci.substring(2, 4);
  String? promotion;
  if (uci.length > 4) promotion = uci.substring(4, 5);

  final moveMap = <String, String?>{'from': from, 'to': to};
  if (promotion != null) moveMap['promotion'] = promotion;

  final legalMoves = game.generate_moves();
  final fromSquare = chess.Chess.SQUARES[from];
  final toSquare = chess.Chess.SQUARES[to];
  String? sanMove;

  for (final move in legalMoves) {
    if (move.from == fromSquare && move.to == toSquare) {
      if (promotion == null ||
          move.promotion == null ||
          move.promotion.toString().toLowerCase() == promotion.toLowerCase()) {
        sanMove = game.move_to_san(move);
        break;
      }
    }
  }

  if (sanMove != null) game.move(moveMap);
  return sanMove;
}

String _formatUciToSan(String fen, String uci) {
  final game = chess.Chess.fromFEN(fen);
  return _makeUciMoveAndGetSan(game, uci) ?? uci;
}

// ════════════════════════════════════════════════════════════════
// Lightweight Stockfish UCI wrapper for worker isolates.
// Uses dart:io Process directly — NO Flutter platform channels.
// ════════════════════════════════════════════════════════════════

class _WorkerStockfish {
  final Process _process;
  late final StreamSubscription<String> _subscription;

  // Handshake completers.
  Completer<void>? _uciOkCompleter;
  Completer<void>? _readyCompleter;
  Completer<void>? _bestmoveCompleter;

  // Current eval state (overwritten by each `info` line).
  int _depth = 0;
  int? _scoreCp;
  int? _scoreMate;
  List<String> _pv = [];
  bool _isWhiteTurn = true;

  _WorkerStockfish._(this._process) {
    _subscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
  }

  /// Spawn a Stockfish process, perform UCI handshake, and configure
  /// for single-threaded operation (1 core per worker).
  static Future<_WorkerStockfish> start(String executablePath) async {
    final process = await Process.start(executablePath, []);
    final sf = _WorkerStockfish._(process);
    await sf._init();
    return sf;
  }

  Future<void> _init() async {
    _uciOkCompleter = Completer<void>();
    _process.stdin.writeln('uci');
    await _uciOkCompleter!.future.timeout(const Duration(seconds: 10));

    _process.stdin.writeln('setoption name Threads value 1');
    _process.stdin.writeln('setoption name Hash value 128');

    _readyCompleter = Completer<void>();
    _process.stdin.writeln('isready');
    await _readyCompleter!.future.timeout(const Duration(seconds: 10));
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    if (trimmed == 'uciok') {
      if (_uciOkCompleter != null && !_uciOkCompleter!.isCompleted) {
        _uciOkCompleter!.complete();
      }
    } else if (trimmed == 'readyok') {
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete();
      }
    } else if (trimmed.startsWith('info')) {
      _parseInfo(trimmed);
    } else if (trimmed.startsWith('bestmove')) {
      if (_bestmoveCompleter != null && !_bestmoveCompleter!.isCompleted) {
        _bestmoveCompleter!.complete();
      }
    }
  }

  void _parseInfo(String line) {
    if (!line.contains('score')) return;

    final parts = line.split(' ');
    for (int i = 0; i < parts.length; i++) {
      if (parts[i] == 'depth' && i + 1 < parts.length) {
        final d = int.tryParse(parts[i + 1]);
        if (d != null) _depth = d;
      } else if (parts[i] == 'score' && i + 2 < parts.length) {
        final type = parts[i + 1];
        final val = int.tryParse(parts[i + 2]);
        if (type == 'cp' && val != null) {
          _scoreCp = _isWhiteTurn ? val : -val;
          _scoreMate = null;
        } else if (type == 'mate' && val != null) {
          _scoreMate = _isWhiteTurn ? val : -val;
          _scoreCp = null;
        }
      } else if (parts[i] == 'pv' && i + 1 < parts.length) {
        _pv = parts.sublist(i + 1);
        break;
      }
    }
  }

  /// Evaluate a position to the given depth. Blocks until `bestmove`.
  Future<_EvalResult> evaluate(String fen, int depth) async {
    final parts = fen.split(' ');
    _isWhiteTurn = parts.length >= 2 && parts[1] == 'w';

    _scoreCp = null;
    _scoreMate = null;
    _pv = [];
    _depth = 0;

    _bestmoveCompleter = Completer<void>();

    _process.stdin.writeln('position fen $fen');
    _process.stdin.writeln('go depth $depth');

    await _bestmoveCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => _process.stdin.writeln('stop'),
    );

    return _EvalResult(
      depth: _depth,
      scoreCp: _scoreCp,
      scoreMate: _scoreMate,
      pv: List<String>.from(_pv),
    );
  }

  void dispose() {
    try {
      _process.stdin.writeln('quit');
    } catch (_) {}
    _subscription.cancel();
    _process.kill();
  }
}

/// Evaluation result from a single position search.
class _EvalResult {
  final int depth;
  final int? scoreCp;
  final int? scoreMate;
  final List<String> pv;

  _EvalResult({
    this.depth = 0,
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
  });

  int get effectiveCp {
    if (scoreMate != null) {
      return scoreMate! > 0 ? 10000 - scoreMate! : -10000 - scoreMate!;
    }
    return scoreCp ?? 0;
  }
}
