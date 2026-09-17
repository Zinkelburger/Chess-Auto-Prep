/// Scanning PGN files into a [PgnFreqMap].
///
/// Runs in a background isolate so a multi-gigabyte database does not freeze
/// the UI, and caches each file's result next to it (see `pgn_freq_cache.dart`)
/// so a rebuild costs one manifest comparison.
///
/// The scanner is deliberately lenient: real-world databases contain illegal
/// SAN, mojibake headers, and games that stop mid-move.  A bad game is counted
/// and skipped, never fatal.  Files stream through `pgn_line_reader.dart`,
/// games are split by `pgn_lexer.dart` and folded in by `pgn_game_scanner.dart`.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Chess, Position, Setup;
import 'package:flutter/foundation.dart';

import '../../utils/chess_utils.dart' show playSanOrNullMove;
import '../../chess_core/position/eval_canonicalize.dart';
import 'pgn_freq_cache.dart';
import 'pgn_freq_map.dart';
import 'pgn_game_scanner.dart';
import 'pgn_lexer.dart';
import 'pgn_line_reader.dart';

/// Parse one or more PGN files into a [PgnFreqMap] in a background isolate.
///
/// [onProgress] reports (gamesProcessed, currentFile) periodically.
/// [useDiskCache] loads/saves `<path>.freq.cache` when file metadata matches.
Future<(PgnFreqMap, PgnFreqStats)> parsePgnFiles({
  required List<String> paths,
  required PgnFreqConfig config,
  void Function(int gamesProcessed, String currentFile)? onProgress,
  bool useDiskCache = true,
}) async {
  final resultPort = ReceivePort();
  final progressPort = ReceivePort();
  final errorPort = ReceivePort();

  StreamSubscription? progressSub;
  if (onProgress != null) {
    progressSub = progressPort.listen((msg) {
      if (msg is List && msg.length == 2) {
        onProgress(msg[0] as int, msg[1] as String);
      }
    });
  }

  try {
    await Isolate.spawn(
      _parseIsolateEntry,
      _ParseRequest(
        paths: paths,
        config: config,
        useDiskCache: useDiskCache,
        resultPort: resultPort.sendPort,
        progressPort: progressPort.sendPort,
      ),
      onError: errorPort.sendPort,
    );

    // Race the result against an uncaught isolate error so a crashed
    // isolate surfaces as an exception instead of hanging this await.
    final completer = Completer<_ParseResult>();
    resultPort.listen((msg) {
      if (!completer.isCompleted) completer.complete(msg as _ParseResult);
    });
    errorPort.listen((msg) {
      final desc = (msg is List && msg.isNotEmpty) ? msg.first : msg;
      if (!completer.isCompleted) {
        completer.completeError(StateError('PGN parsing failed: $desc'));
      }
    });

    final result = await completer.future;
    return (result.map, result.stats);
  } finally {
    await progressSub?.cancel();
    resultPort.close();
    progressPort.close();
    errorPort.close();
  }
}

// ── Isolate plumbing ─────────────────────────────────────────────────────

class _ParseRequest {
  final List<String> paths;
  final PgnFreqConfig config;
  final bool useDiskCache;
  final SendPort resultPort;
  final SendPort progressPort;

  _ParseRequest({
    required this.paths,
    required this.config,
    required this.useDiskCache,
    required this.resultPort,
    required this.progressPort,
  });
}

class _ParseResult {
  final PgnFreqMap map;
  final PgnFreqStats stats;
  _ParseResult(this.map, this.stats);
}

void _parseIsolateEntry(_ParseRequest req) {
  final map = PgnFreqMap(gameCapacity: req.config.retainGames);
  final tally = _Tally();
  final warnings = PgnScanWarnings();
  final targetKey = buildTrackingTarget(req.config);

  for (final path in req.paths) {
    try {
      final file = io.File(path);
      final manifest = buildPgnFreqManifest(
        path: path,
        stat: file.statSync(),
        config: req.config,
      );
      final cachePath = pgnFreqCachePath(path);

      if (req.useDiskCache) {
        final cached = loadPgnFreqCache(cachePath, manifest);
        if (cached != null) {
          map.merge(cached);
          tally.games += cached.totalGames;
          req.progressPort.send([tally.games, path]);
          continue;
        }
      }

      final fileMap = _scanFile(
        path: path,
        config: req.config,
        targetKey: targetKey,
        tally: tally,
        warnings: warnings,
        onProgress: () => req.progressPort.send([tally.games, path]),
      );
      map.merge(fileMap);

      if (req.useDiskCache && fileMap.totalGames > 0) {
        if (!savePgnFreqCache(fileMap, cachePath, manifest)) {
          debugPrint(
            '[PgnFreqParser] Warning: could not save frequency cache to '
            '$cachePath',
          );
        }
      }
    } catch (e) {
      tally.fileReadErrors++;
      debugPrint('[PgnFreqParser] Error reading/parsing $path: $e');
    }
    req.progressPort.send([tally.games, path]);
  }

  map.remapGameRefs(map.games.finalize());
  warnings.logSummaryIfNeeded();

  req.resultPort.send(
    _ParseResult(map, tally.toStats(map.positionCount, map.games.length)),
  );
}

class _Tally {
  int games = 0;
  int skippedElo = 0;
  int skippedPrefix = 0;
  int parseErrors = 0;
  int fileReadErrors = 0;

  PgnFreqStats toStats(int positions, int retainedGames) => PgnFreqStats(
    positions: positions,
    totalGames: games,
    skippedElo: skippedElo,
    skippedPrefix: skippedPrefix,
    parseErrors: parseErrors,
    fileReadErrors: fileReadErrors,
    retainedGames: retainedGames,
  );
}

// ── One file ─────────────────────────────────────────────────────────────

PgnFreqMap _scanFile({
  required String path,
  required PgnFreqConfig config,
  required String? targetKey,
  required _Tally tally,
  required PgnScanWarnings warnings,
  required void Function() onProgress,
}) {
  final fileMap = PgnFreqMap(gameCapacity: config.retainGames);
  final scanner = PgnGameScanner(
    map: fileMap,
    config: config,
    targetKey: targetKey,
    warnings: warnings,
  );
  var gameIndex = 0;

  final splitter = PgnGameSplitter((game) {
    gameIndex++;
    switch (scanner.scan(game, gameIndex: gameIndex)) {
      case GameScan.ok:
        tally.games++;
        fileMap.totalGames++;
      case GameScan.belowEloFloor:
        tally.skippedElo++;
      case GameScan.prefixSkip:
        tally.skippedPrefix++;
      case GameScan.error:
        tally.parseErrors++;
    }
    if (gameIndex % 100 == 0) onProgress();
  });
  final usedLatin1 = readTextLines(path, splitter.addLine);
  splitter.close();

  if (usedLatin1) {
    debugPrint('[PgnFreqParser] Warning: read $path as Latin-1 (not UTF-8)');
  }
  return fileMap;
}

// ── Prefix targeting ─────────────────────────────────────────────────────

/// The 4-field FEN key a game must reach before its moves are counted, or
/// null when the scan tracks from move one.
String? buildTrackingTarget(PgnFreqConfig config) {
  final prefixMoves = _splitPrefixMoves(config.startMoves);
  final customFen =
      config.startFen != null &&
      config.startFen!.isNotEmpty &&
      canonicalizeFen4(config.startFen!) != canonicalizeFen4(kDefaultStartFen);

  if (prefixMoves.isEmpty && !customFen) return null;

  Position position;
  try {
    position = Chess.fromSetup(
      Setup.parseFen(customFen ? config.startFen! : kDefaultStartFen),
    );
  } catch (_) {
    return null;
  }

  for (final san in prefixMoves) {
    final next = playSanOrNullMove(position, san);
    if (next == null) return null;
    position = next;
  }
  return canonicalizeFen4(position.fen);
}

List<String> _splitPrefixMoves(String? moves) {
  if (moves == null || moves.isEmpty) return const [];
  return [
    for (final token in moves.split(RegExp(r'\s+')))
      if (token.isNotEmpty && !isResultToken(token) && !_isMoveNumber(token))
        token,
  ];
}

bool _isMoveNumber(String token) {
  final cleaned = token.replaceAll('.', '');
  return cleaned.isNotEmpty && int.tryParse(cleaned) != null;
}
