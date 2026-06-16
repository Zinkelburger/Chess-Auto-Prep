/// PGN frequency map — Dart port of C `pgn_freq.c`.
///
/// Parses standard PGN files and accumulates per-position move frequencies
/// keyed by 4-field canonical FEN.  Runs parsing in an isolate so the UI
/// stays responsive for large databases.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../utils/file_text_reader.dart';
import '../eval/eval_canonicalize.dart';
import 'pgn_freq_cache.dart';

// ── Public data types ────────────────────────────────────────────────────

class PgnFreqMove {
  final String uci;
  final String san;
  int count;

  PgnFreqMove({required this.uci, required this.san, this.count = 1});
}

class PgnFreqPosition {
  final String fenKey;
  int reachCount = 0;
  final List<PgnFreqMove> moves = [];

  PgnFreqPosition(this.fenKey);
}

class PgnFreqConfig {
  final String? startFen;
  final String? startMoves;
  final int maxPly;
  final int minElo;

  const PgnFreqConfig({
    this.startFen,
    this.startMoves,
    this.maxPly = 0,
    this.minElo = 0,
  });
}

class PgnFreqStats {
  final int positions;
  final int totalGames;
  final int skippedElo;
  final int skippedPrefix;
  final int parseErrors;
  final int fileReadErrors;

  const PgnFreqStats({
    this.positions = 0,
    this.totalGames = 0,
    this.skippedElo = 0,
    this.skippedPrefix = 0,
    this.parseErrors = 0,
    this.fileReadErrors = 0,
  });
}

// ── PgnFreqMap ───────────────────────────────────────────────────────────

const kDefaultStartFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class PgnFreqMap {
  final Map<String, PgnFreqPosition> _positions = {};
  int totalGames = 0;

  int get positionCount => _positions.length;

  /// Exposed for disk cache serialization.
  Iterable<MapEntry<String, PgnFreqPosition>> get positions =>
      _positions.entries;

  PgnFreqPosition? get(String fen) {
    final key = canonicalizeFen4(fen);
    return _positions[key];
  }

  PgnFreqPosition getOrCreate(String fenKey) {
    return _positions.putIfAbsent(fenKey, () => PgnFreqPosition(fenKey));
  }

  void recordMove(String fenKey, String uci, String san) {
    final pos = getOrCreate(fenKey);
    for (final m in pos.moves) {
      if (m.uci == uci) {
        m.count++;
        return;
      }
    }
    pos.moves.add(PgnFreqMove(uci: uci, san: san));
  }

  void recordReach(String fenKey) {
    getOrCreate(fenKey).reachCount++;
  }

  /// Filter moves by minimum game count AND minimum probability.
  List<PgnFreqMove> filteredMoves(
    PgnFreqPosition pos, {
    required int minGames,
    required double minProb,
  }) {
    int total = 0;
    for (final m in pos.moves) {
      total += m.count;
    }
    if (total == 0) return const [];

    final result = <PgnFreqMove>[];
    for (final m in pos.moves) {
      if (m.count < minGames) continue;
      if (m.count / total < minProb) continue;
      result.add(m);
    }
    return result;
  }

  /// Merge another map into this one (sum counts).
  void merge(PgnFreqMap other) {
    totalGames += other.totalGames;
    for (final entry in other._positions.entries) {
      final src = entry.value;
      final dst = getOrCreate(entry.key);
      dst.reachCount += src.reachCount;
      for (final srcMove in src.moves) {
        bool found = false;
        for (final dstMove in dst.moves) {
          if (dstMove.uci == srcMove.uci) {
            dstMove.count += srcMove.count;
            found = true;
            break;
          }
        }
        if (!found) {
          dst.moves.add(PgnFreqMove(
            uci: srcMove.uci,
            san: srcMove.san,
            count: srcMove.count,
          ));
        }
      }
    }
  }

  PgnFreqStats get stats => PgnFreqStats(
        positions: positionCount,
        totalGames: totalGames,
      );
}

// ── Isolate-based PGN file parsing ───────────────────────────────────────

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

  StreamSubscription? progressSub;
  if (onProgress != null) {
    progressSub = progressPort.listen((msg) {
      if (msg is List && msg.length == 2) {
        onProgress(msg[0] as int, msg[1] as String);
      }
    });
  }

  await Isolate.spawn(
    _parseIsolateEntry,
    _ParseRequest(
      paths: paths,
      config: config,
      useDiskCache: useDiskCache,
      resultPort: resultPort.sendPort,
      progressPort: progressPort.sendPort,
    ),
  );

  final result = await resultPort.first as _ParseResult;
  await progressSub?.cancel();
  resultPort.close();
  progressPort.close();

  return (result.map, result.stats);
}

// ── Isolate internals ────────────────────────────────────────────────────

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
  final map = PgnFreqMap();
  int skippedElo = 0;
  int skippedPrefix = 0;
  int parseErrors = 0;
  int fileReadErrors = 0;
  int totalParsed = 0;
  final parseWarnings = _ParseWarningLogger();

  final targetKey = _buildTrackingTarget(req.config);

  for (final path in req.paths) {
    try {
      final file = io.File(path);
      final stat = file.statSync();
      final manifest = buildPgnFreqManifest(
        path: path,
        stat: stat,
        config: req.config,
      );
      final cachePath = pgnFreqCachePath(path);

      PgnFreqMap? fileMap;
      if (req.useDiskCache) {
        fileMap = loadPgnFreqCache(cachePath, manifest);
        if (fileMap != null) {
          map.merge(fileMap);
          totalParsed += fileMap.totalGames;
          req.progressPort.send([totalParsed, path]);
          continue;
        }
      }

      fileMap = PgnFreqMap();
      final decoded = decodeTextBytesDetailed(file.readAsBytesSync());
      if (decoded.usedLatin1Fallback) {
        debugPrint(
          '[PgnFreqMap] Warning: read $path as Latin-1 (not valid UTF-8)',
        );
      }
      final games = _splitPgnGames(decoded.text);

      for (int gi = 0; gi < games.length; gi++) {
        final game = games[gi];

        if (req.config.minElo > 0) {
          final wElo = _parseEloTag(game.headers, 'WhiteElo');
          final bElo = _parseEloTag(game.headers, 'BlackElo');
          if (wElo > 0 &&
              bElo > 0 &&
              wElo < req.config.minElo &&
              bElo < req.config.minElo) {
            skippedElo++;
            continue;
          }
        }

        final result = _processGameMovetext(
          map: fileMap,
          movetext: game.movetext,
          targetKey: targetKey,
          maxPly: req.config.maxPly,
          gameIndex: gi + 1,
          headers: game.headers,
          warnings: parseWarnings,
        );

        switch (result) {
          case _GameResult.ok:
            totalParsed++;
            fileMap.totalGames++;
          case _GameResult.prefixSkip:
            skippedPrefix++;
          case _GameResult.error:
            parseErrors++;
        }

        if (gi % 100 == 0) {
          req.progressPort.send([totalParsed, path]);
        }
      }

      map.merge(fileMap);

      if (req.useDiskCache && fileMap.totalGames > 0) {
        if (!savePgnFreqCache(fileMap, cachePath, manifest)) {
          debugPrint(
            '[PgnFreqMap] Warning: could not save frequency cache to $cachePath',
          );
        }
      }
    } catch (e) {
      fileReadErrors++;
      debugPrint('[PgnFreqMap] Error reading/parsing $path: $e');
    }
    req.progressPort.send([totalParsed, path]);
  }

  parseWarnings.logSummaryIfNeeded();

  req.resultPort.send(_ParseResult(
    map,
    PgnFreqStats(
      positions: map.positionCount,
      totalGames: totalParsed,
      skippedElo: skippedElo,
      skippedPrefix: skippedPrefix,
      parseErrors: parseErrors,
      fileReadErrors: fileReadErrors,
    ),
  ));
}

// ── PGN file splitting ───────────────────────────────────────────────────

class _PgnGame {
  final Map<String, String> headers;
  final String movetext;
  _PgnGame({required this.headers, required this.movetext});
}

List<_PgnGame> _splitPgnGames(String pgn) {
  final games = <_PgnGame>[];
  final lines = pgn.split('\n');
  var headers = <String, String>{};
  final movetext = StringBuffer();
  bool inMovetext = false;

  for (final line in lines) {
    final trimmed = line.trim();

    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      if (inMovetext && movetext.isNotEmpty) {
        games.add(_PgnGame(headers: headers, movetext: movetext.toString()));
        headers = <String, String>{};
        movetext.clear();
        inMovetext = false;
      }
      final match = RegExp(r'^\[(\w+)\s+"(.*)"\]$').firstMatch(trimmed);
      if (match != null) {
        headers[match.group(1)!] = match.group(2)!;
      }
    } else if (trimmed.isEmpty) {
      if (headers.isNotEmpty && !inMovetext) {
        inMovetext = true;
      } else if (inMovetext && movetext.isNotEmpty) {
        games.add(_PgnGame(headers: headers, movetext: movetext.toString()));
        headers = <String, String>{};
        movetext.clear();
        inMovetext = false;
      }
    } else {
      inMovetext = true;
      if (movetext.isNotEmpty) movetext.write(' ');
      movetext.write(trimmed);
    }
  }

  if (movetext.isNotEmpty) {
    games.add(_PgnGame(headers: headers, movetext: movetext.toString()));
  }

  return games;
}

int _parseEloTag(Map<String, String> headers, String tag) {
  final value = headers[tag];
  if (value == null || value.isEmpty || value == '?') return 0;
  return int.tryParse(value) ?? 0;
}

// ── Movetext processing ──────────────────────────────────────────────────

enum _GameResult { ok, prefixSkip, error }

List<String> _parsePrefixMoves(String moves) {
  return moves
      .split(RegExp(r'\s+'))
      .where((tok) => !_isMoveNumber(tok) && !_isResult(tok) && tok.isNotEmpty)
      .toList();
}

bool _isMoveNumber(String tok) {
  if (tok.isEmpty) return true;
  final cleaned = tok.replaceAll('.', '');
  return cleaned.isNotEmpty && int.tryParse(cleaned) != null;
}

bool _isResult(String tok) {
  return tok == '1-0' || tok == '0-1' || tok == '1/2-1/2' || tok == '*';
}

/// Extracts a SAN move from a PGN token (handles "1.e4", "12.Nf3", "1...c5").
String? _tokenToSan(String tok) {
  if (tok.isEmpty) return null;

  int i = 0;
  while (i < tok.length && tok.codeUnitAt(i) >= 48 && tok.codeUnitAt(i) <= 57) {
    i++;
  }
  if (i > 0) {
    if (i >= tok.length) return null;
    if (tok[i] != '.') return tok;
    while (i < tok.length && tok[i] == '.') {
      i++;
    }
    if (i >= tok.length) return null;
    return tok.substring(i);
  }

  return tok;
}

/// Tokenize PGN movetext, skipping comments and variations.
List<String> _tokenizeMovetext(String movetext) {
  final tokens = <String>[];
  int i = 0;
  final len = movetext.length;

  while (i < len) {
    final ch = movetext[i];

    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
      i++;
      continue;
    }

    if (ch == '{') {
      i++;
      while (i < len && movetext[i] != '}') {
        i++;
      }
      if (i < len) i++;
      continue;
    }

    if (ch == '(') {
      int depth = 1;
      i++;
      while (i < len && depth > 0) {
        if (movetext[i] == '(') {
          depth++;
        } else if (movetext[i] == ')') {
          depth--;
        }
        i++;
      }
      continue;
    }

    if (ch == '\$') {
      i++;
      while (i < len &&
          movetext.codeUnitAt(i) >= 48 &&
          movetext.codeUnitAt(i) <= 57) {
        i++;
      }
      continue;
    }

    final start = i;
    while (i < len &&
        movetext[i] != ' ' &&
        movetext[i] != '\t' &&
        movetext[i] != '\r' &&
        movetext[i] != '\n' &&
        movetext[i] != '{' &&
        movetext[i] != '(') {
      i++;
    }
    tokens.add(movetext.substring(start, i));
  }
  return tokens;
}

/// SAN to UCI conversion using dartchess.
String? _sanToUci(String fen, String san) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final move = position.parseSan(san);
    if (move == null) return null;
    return move.uci;
  } catch (_) {
    return null;
  }
}

/// Play a UCI move and return the new FEN, or null if illegal.
String? _playUci(String baseFen, String uci) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(baseFen));
    final move = Move.parse(uci);
    if (move == null) return null;
    final newPos = position.play(move);
    return newPos.fen;
  } catch (_) {
    return null;
  }
}

bool _fenKeysEqual(String fenA, String fenB) {
  return canonicalizeFen4(fenA) == canonicalizeFen4(fenB);
}

/// Build the 4-field FEN key games must reach before frequency tracking.
/// Returns null when no prefix filter is configured.
String? _buildTrackingTarget(PgnFreqConfig cfg) {
  final prefixMoves = (cfg.startMoves != null && cfg.startMoves!.isNotEmpty)
      ? _parsePrefixMoves(cfg.startMoves!)
      : <String>[];

  final wantFen = cfg.startFen != null &&
      cfg.startFen!.isNotEmpty &&
      !_fenKeysEqual(cfg.startFen!, kDefaultStartFen);

  if (prefixMoves.isEmpty && !wantFen) return null;

  var fen = wantFen ? cfg.startFen! : kDefaultStartFen;

  for (final san in prefixMoves) {
    final uci = _sanToUci(fen, san);
    if (uci == null) return null;
    final newFen = _playUci(fen, uci);
    if (newFen == null) return null;
    fen = newFen;
  }

  return canonicalizeFen4(fen);
}

class _ParseWarningLogger {
  static const int maxDetailed = 10;
  int logged = 0;
  int suppressed = 0;

  void logMoveFailure({
    required int gameIndex,
    required Map<String, String> headers,
    required String failingSan,
    required String fen,
    required String reason,
  }) {
    if (logged >= maxDetailed) {
      suppressed++;
      return;
    }
    logged++;
    final white = headers['White'] ?? '?';
    final black = headers['Black'] ?? '?';
    final event = headers['Event'] ?? '?';
    final date = headers['Date'] ?? '?';
    debugPrint(
      '[PgnFreqMap] Warning: $reason SAN "$failingSan" at FEN $fen '
      '(game #$gameIndex: White=$white, Black=$black, Event=$event, Date=$date)',
    );
  }

  void logSummaryIfNeeded() {
    if (suppressed <= 0) return;
    debugPrint(
      '[PgnFreqMap] Warning: suppressed $suppressed additional parse warnings '
      '(first $maxDetailed shown)',
    );
  }
}

_GameResult _processGameMovetext({
  required PgnFreqMap map,
  required String movetext,
  required String? targetKey,
  required int maxPly,
  required int gameIndex,
  required Map<String, String> headers,
  required _ParseWarningLogger warnings,
}) {
  var fen = kDefaultStartFen;
  var tracking = targetKey == null;
  var plyTracked = 0;

  if (targetKey != null && _fenKeysEqual(fen, targetKey)) {
    tracking = true;
    map.recordReach(targetKey);
  }

  final tokens = _tokenizeMovetext(movetext);

  for (final tok in tokens) {
    final san = _tokenToSan(tok);
    if (san == null) continue;
    if (_isResult(san)) break;

    final uci = _sanToUci(fen, san);
    if (uci == null) {
      warnings.logMoveFailure(
        gameIndex: gameIndex,
        headers: headers,
        failingSan: san,
        fen: fen,
        reason: 'cannot parse move',
      );
      return _GameResult.error;
    }

    if (!tracking) {
      final newFen = _playUci(fen, uci);
      if (newFen == null) {
        warnings.logMoveFailure(
          gameIndex: gameIndex,
          headers: headers,
          failingSan: san,
          fen: fen,
          reason: 'illegal move',
        );
        return _GameResult.error;
      }
      fen = newFen;

      if (targetKey != null && _fenKeysEqual(fen, targetKey)) {
        tracking = true;
        map.recordReach(targetKey);
      }
      continue;
    }

    if (maxPly > 0 && plyTracked >= maxPly) break;

    map.recordMove(canonicalizeFen4(fen), uci, san);

    final newFen = _playUci(fen, uci);
    if (newFen == null) {
      warnings.logMoveFailure(
        gameIndex: gameIndex,
        headers: headers,
        failingSan: san,
        fen: fen,
        reason: 'illegal move',
      );
      return _GameResult.error;
    }
    fen = newFen;

    map.recordReach(canonicalizeFen4(fen));
    plyTracked++;
  }

  return tracking ? _GameResult.ok : _GameResult.prefixSkip;
}
