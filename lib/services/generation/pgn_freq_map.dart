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

import '../eval/eval_canonicalize.dart';

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

  const PgnFreqStats({
    this.positions = 0,
    this.totalGames = 0,
    this.skippedElo = 0,
    this.skippedPrefix = 0,
    this.parseErrors = 0,
  });
}

// ── PgnFreqMap ───────────────────────────────────────────────────────────

class PgnFreqMap {
  final Map<String, PgnFreqPosition> _positions = {};
  int totalGames = 0;

  int get positionCount => _positions.length;

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
Future<(PgnFreqMap, PgnFreqStats)> parsePgnFiles({
  required List<String> paths,
  required PgnFreqConfig config,
  void Function(int gamesProcessed, String currentFile)? onProgress,
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
  final SendPort resultPort;
  final SendPort progressPort;

  _ParseRequest({
    required this.paths,
    required this.config,
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
  int totalParsed = 0;

  final startFen = req.config.startFen ??
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  List<String>? prefixMoves;
  if (req.config.startMoves != null && req.config.startMoves!.isNotEmpty) {
    prefixMoves = _parsePrefixMoves(req.config.startMoves!);
  }

  for (final path in req.paths) {
    try {
      final contents = io.File(path).readAsStringSync();
      final games = _splitPgnGames(contents);

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
          map: map,
          movetext: game.movetext,
          startFen: startFen,
          prefixMoves: prefixMoves,
          maxPly: req.config.maxPly,
        );

        switch (result) {
          case _GameResult.ok:
            totalParsed++;
            map.totalGames++;
          case _GameResult.prefixSkip:
            skippedPrefix++;
          case _GameResult.error:
            parseErrors++;
        }

        if (gi % 100 == 0) {
          req.progressPort.send([totalParsed, path]);
        }
      }
    } catch (e) {
      debugPrint('[PgnFreqMap] Error parsing $path: $e');
    }
    req.progressPort.send([totalParsed, path]);
  }

  req.resultPort.send(_ParseResult(
    map,
    PgnFreqStats(
      positions: map.positionCount,
      totalGames: totalParsed,
      skippedElo: skippedElo,
      skippedPrefix: skippedPrefix,
      parseErrors: parseErrors,
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

bool _sanMovesMatch(String a, String b) {
  if (a == b) return true;
  final na = a.replaceAll('0-0-0', 'O-O-O').replaceAll('0-0', 'O-O');
  final nb = b.replaceAll('0-0-0', 'O-O-O').replaceAll('0-0', 'O-O');
  return na == nb;
}

_GameResult _processGameMovetext({
  required PgnFreqMap map,
  required String movetext,
  required String startFen,
  List<String>? prefixMoves,
  required int maxPly,
}) {
  String fen = startFen;
  bool tracking = (prefixMoves == null || prefixMoves.isEmpty);
  int prefixIdx = 0;
  int plyTracked = 0;

  final tokens = _tokenizeMovetext(movetext);

  for (final tok in tokens) {
    final san = _tokenToSan(tok);
    if (san == null) continue;
    if (_isResult(san)) break;

    final uci = _sanToUci(fen, san);
    if (uci == null) return _GameResult.error;

    if (!tracking) {
      if (prefixIdx >= prefixMoves!.length ||
          !_sanMovesMatch(san, prefixMoves[prefixIdx])) {
        return _GameResult.prefixSkip;
      }

      final newFen = _playUci(fen, uci);
      if (newFen == null) return _GameResult.error;
      fen = newFen;
      prefixIdx++;

      if (prefixIdx >= prefixMoves.length) {
        tracking = true;
        map.recordReach(canonicalizeFen4(fen));
      }
      continue;
    }

    if (maxPly > 0 && plyTracked >= maxPly) break;

    map.recordMove(canonicalizeFen4(fen), uci, san);

    final newFen = _playUci(fen, uci);
    if (newFen == null) return _GameResult.error;
    fen = newFen;

    map.recordReach(canonicalizeFen4(fen));
    plyTracked++;
  }

  return tracking ? _GameResult.ok : _GameResult.prefixSkip;
}
