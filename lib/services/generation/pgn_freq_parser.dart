/// Scanning PGN files into a [PgnFreqMap].
///
/// Runs in a background isolate so a multi-gigabyte database does not freeze
/// the UI, and caches each file's result next to it (see `pgn_freq_cache.dart`)
/// so a rebuild costs one manifest comparison.
///
/// The scanner is deliberately lenient: real-world databases contain illegal
/// SAN, mojibake headers, and games that stop mid-move.  A bad game is counted
/// and skipped, never fatal.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../utils/chess_utils.dart' show isNullMoveSan, playSanOrNullMove;
import '../eval/eval_canonicalize.dart';
import 'pgn_freq_cache.dart';
import 'pgn_freq_map.dart';

/// Deepest ply at which a position still records references to the games that
/// passed through it.  Model-game matching only ever walks the repertoire
/// spine, and past this depth a position belongs to a single game anyway.
const int kGameRefMaxPly = 40;

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
  final warnings = _ParseWarningLogger();
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
  required _ParseWarningLogger warnings,
  required void Function() onProgress,
}) {
  final fileMap = PgnFreqMap(gameCapacity: config.retainGames);
  var gameIndex = 0;

  final usedLatin1 = _forEachGame(path, (game) {
    gameIndex++;
    if (_belowEloFloor(game.headers, config.minElo)) {
      tally.skippedElo++;
      return;
    }

    switch (_scanGame(
      map: fileMap,
      game: game,
      config: config,
      targetKey: targetKey,
      gameIndex: gameIndex,
      warnings: warnings,
    )) {
      case _GameScan.ok:
        tally.games++;
        fileMap.totalGames++;
      case _GameScan.prefixSkip:
        tally.skippedPrefix++;
      case _GameScan.error:
        tally.parseErrors++;
    }

    if (gameIndex % 100 == 0) onProgress();
  });

  if (usedLatin1) {
    debugPrint('[PgnFreqParser] Warning: read $path as Latin-1 (not UTF-8)');
  }
  return fileMap;
}

/// Bytes read per `readIntoSync`.  Large enough that the syscall count is
/// irrelevant, small enough that three of them (raw, decoded, carry) are
/// nothing next to the map being built.
const int _readChunkBytes = 4 << 20;

/// Feed every game in the file at [path] to [onGame], one at a time.
///
/// A multi-gigabyte database is never resident: bytes are read in fixed
/// chunks, decoded incrementally, split into lines, and each game is handed
/// over the moment its movetext ends.  The previous whole-file
/// `readAsBytesSync` → decode → `split('\n')` held three copies of the file
/// at once (bytes, a two-byte-per-char string, and a list of every line).
///
/// Encoding follows `decodeTextBytesDetailed`: UTF-8, with a whole-file
/// Latin-1 fallback when the bytes are not valid UTF-8.  A validation pass
/// decides that up front — games are scanned as they stream and cannot be
/// un-scanned if a malformed byte turns up late in the file.  Returns whether
/// the fallback was used.
bool _forEachGame(String path, void Function(PgnGame game) onGame) {
  final file = io.File(path).openSync();
  try {
    final utf8Valid = _isValidUtf8(file);
    file.setPositionSync(0);

    final splitter = PgnGameSplitter(onGame);
    final lines = _LineSink(splitter.addLine);
    final ByteConversionSink decoder = utf8Valid
        ? utf8.decoder.startChunkedConversion(lines)
        : latin1.decoder.startChunkedConversion(lines);
    final buffer = Uint8List(_readChunkBytes);
    while (true) {
      final read = file.readIntoSync(buffer);
      if (read == 0) break;
      decoder.addSlice(buffer, 0, read, false);
    }
    decoder.close();
    splitter.close();
    return !utf8Valid;
  } finally {
    file.closeSync();
  }
}

/// Whether [file] (read from its current position to the end) is well-formed
/// UTF-8, by the same rules `utf8.decode` enforces: no overlong forms, no
/// surrogates, nothing above U+10FFFF.  Streams the bytes; allocates nothing
/// per byte.
bool _isValidUtf8(io.RandomAccessFile file) {
  final buffer = Uint8List(_readChunkBytes);
  var pending = 0; // Continuation bytes still expected.
  var low = 0x80; // Allowed range of the next continuation byte.
  var high = 0xBF;
  while (true) {
    final read = file.readIntoSync(buffer);
    if (read == 0) break;
    for (var i = 0; i < read; i++) {
      final b = buffer[i];
      if (pending > 0) {
        if (b < low || b > high) return false;
        low = 0x80;
        high = 0xBF;
        pending--;
      } else if (b < 0x80) {
        continue;
      } else if (b >= 0xC2 && b <= 0xDF) {
        pending = 1;
      } else if (b == 0xE0) {
        pending = 2;
        low = 0xA0;
      } else if (b == 0xED) {
        pending = 2;
        high = 0x9F;
      } else if (b >= 0xE1 && b <= 0xEF) {
        pending = 2;
      } else if (b == 0xF0) {
        pending = 3;
        low = 0x90;
      } else if (b == 0xF4) {
        pending = 3;
        high = 0x8F;
      } else if (b >= 0xF1 && b <= 0xF3) {
        pending = 3;
      } else {
        return false;
      }
    }
  }
  return pending == 0;
}

/// Turns decoded text chunks into lines.  Only the trailing partial line is
/// carried between chunks, so memory stays bounded by the longest line.
class _LineSink implements Sink<String> {
  _LineSink(this._onLine);

  final void Function(String line) _onLine;
  String _carry = '';

  @override
  void add(String chunk) {
    var start = 0;
    while (true) {
      final newline = chunk.indexOf('\n', start);
      if (newline < 0) break;
      final line = chunk.substring(start, newline);
      _onLine(_carry.isEmpty ? line : _carry + line);
      _carry = '';
      start = newline + 1;
    }
    if (start < chunk.length) _carry += chunk.substring(start);
  }

  @override
  void close() {
    if (_carry.isNotEmpty) _onLine(_carry);
    _carry = '';
  }
}

/// True when both players are rated and *both* fall below [minElo].  A single
/// known rating above the floor keeps the game — databases are full of
/// half-rated pairings and dropping them silently skews the sample.
bool _belowEloFloor(Map<String, String> headers, int minElo) {
  if (minElo <= 0) return false;
  final white = _eloTag(headers, 'WhiteElo');
  final black = _eloTag(headers, 'BlackElo');
  return white > 0 && black > 0 && white < minElo && black < minElo;
}

// ── One game ─────────────────────────────────────────────────────────────

enum _GameScan { ok, prefixSkip, error }

/// Everything the scanner extracts from a game's headers up front.
class _GameContext {
  final GameOutcome? outcome;
  final int? averageElo;
  final int? year;

  const _GameContext({this.outcome, this.averageElo, this.year});

  factory _GameContext.fromHeaders(Map<String, String> headers) {
    final white = _eloTag(headers, 'WhiteElo');
    final black = _eloTag(headers, 'BlackElo');
    final average = white > 0 && black > 0
        ? (white + black) ~/ 2
        : (white > 0 ? white : (black > 0 ? black : null));
    return _GameContext(
      outcome: GameOutcome.parse(headers['Result']),
      averageElo: average,
      year: _year(
        headers['Date'] ?? headers['UTCDate'] ?? headers['EventDate'],
      ),
    );
  }
}

_GameScan _scanGame({
  required PgnFreqMap map,
  required PgnGame game,
  required PgnFreqConfig config,
  required String? targetKey,
  required int gameIndex,
  required _ParseWarningLogger warnings,
}) {
  final context = _GameContext.fromHeaders(game.headers);

  // One live position threaded through the game; fenKey always mirrors it.
  var position = Chess.initial as Position;
  var fenKey = canonicalizeFen4(position.fen);
  var tracking = targetKey == null;
  var plyTracked = 0;

  // Positions this game passed through, for model-game back-references.
  final visitedKeys = <String>[];
  final trackedMoves = <String>[];

  if (targetKey != null && fenKey == targetKey) {
    tracking = true;
    map.recordReach(targetKey);
    visitedKeys.add(targetKey);
  } else if (tracking) {
    visitedKeys.add(fenKey);
  }

  for (final token in tokenizeMovetext(game.movetext)) {
    final san = tokenToSan(token);
    if (san == null) continue;
    if (isResultToken(san)) break;

    // Statistics stop at the build's depth, but a model game has to keep
    // going: its teaching value is the middlegame the opening was played
    // for, and maxPly is only ever a handful of moves deep.
    final counting =
        !tracking || config.maxPly <= 0 || plyTracked < config.maxPly;
    final retaining =
        tracking &&
        config.retainGames > 0 &&
        trackedMoves.length < PgnGameRecord.maxRetainedPlies;
    if (!counting && !retaining) break;

    // parseSan only yields legal moves, so this covers illegal moves too.
    // Null-move tokens (ChessBase `--` / `Z0`) pass the turn without a
    // recorded repertoire move so later same-side SAN stays legal.
    if (isNullMoveSan(san)) {
      final next = playSanOrNullMove(position, san);
      if (next == null) {
        if (!counting) break;
        warnings.logMoveFailure(
          gameIndex: gameIndex,
          headers: game.headers,
          failingSan: san,
          fen: position.fen,
          reason: 'cannot parse move',
        );
        return _GameScan.error;
      }
      position = next;
      if (!tracking) {
        fenKey = canonicalizeFen4(position.fen);
        if (fenKey == targetKey) {
          tracking = true;
          map.recordReach(fenKey);
          visitedKeys.add(fenKey);
        }
        continue;
      }
      // Past the counted window the key is never read again (counting only
      // ever turns off), so the FEN is not serialised.
      if (counting) {
        fenKey = canonicalizeFen4(position.fen);
        map.recordReach(fenKey);
        if (plyTracked < kGameRefMaxPly) visitedKeys.add(fenKey);
      }
      plyTracked++;
      continue;
    }

    final move = _parseSanMove(position, san);
    if (move == null) {
      // Past the counted window nothing is at stake but the tail of a model
      // game, so a broken move truncates it instead of voiding the game's
      // already-recorded statistics.
      if (!counting) break;
      warnings.logMoveFailure(
        gameIndex: gameIndex,
        headers: game.headers,
        failingSan: san,
        fen: position.fen,
        reason: 'cannot parse move',
      );
      return _GameScan.error;
    }

    if (!tracking) {
      position = position.play(move);
      fenKey = canonicalizeFen4(position.fen);
      if (fenKey == targetKey) {
        tracking = true;
        map.recordReach(fenKey);
        visitedKeys.add(fenKey);
      }
      continue;
    }

    if (counting) {
      map.recordMove(
        fenKey,
        move.uci,
        san,
        outcome: context.outcome,
        averageElo: context.averageElo,
        year: context.year,
      );
    }
    if (retaining) trackedMoves.add(san);

    position = position.play(move);
    if (counting) {
      fenKey = canonicalizeFen4(position.fen);
      map.recordReach(fenKey);
      if (plyTracked < kGameRefMaxPly) visitedKeys.add(fenKey);
    }
    plyTracked++;
  }

  if (!tracking) return _GameScan.prefixSkip;

  _retainGame(map, game, context, trackedMoves, visitedKeys, config);
  return _GameScan.ok;
}

/// Offer the game to the reservoir and, if admitted, back-reference it from
/// every position it passed through.
void _retainGame(
  PgnFreqMap map,
  PgnGame game,
  _GameContext context,
  List<String> movesSan,
  List<String> visitedKeys,
  PgnFreqConfig config,
) {
  if (config.retainGames <= 0 || movesSan.isEmpty) return;
  final elo = context.averageElo ?? 0;
  if (config.retainMinElo > 0 && elo > 0 && elo < config.retainMinElo) return;

  final index = map.games.offer(
    PgnGameRecord(
      white: game.headers['White'] ?? '',
      black: game.headers['Black'] ?? '',
      whiteElo: _eloTag(game.headers, 'WhiteElo'),
      blackElo: _eloTag(game.headers, 'BlackElo'),
      event: game.headers['Event'] ?? '',
      date: game.headers['Date'] ?? game.headers['UTCDate'] ?? '',
      outcome: context.outcome,
      movesSan: movesSan,
    ),
  );
  if (index == null) return;

  for (final key in visitedKeys) {
    map.getOrCreate(key).addGameRef(index);
  }

  // Compacting invalidates indices, so rewrite every reference immediately.
  if (map.games.needsCompaction) {
    map.remapGameRefs(map.games.compactIndices());
  }
}

// ── PGN lexing ───────────────────────────────────────────────────────────

class PgnGame {
  final Map<String, String> headers;
  final String movetext;
  const PgnGame({required this.headers, required this.movetext});
}

final _headerPattern = RegExp(r'^\[(\w+)\s+"(.*)"\]$');

/// Incremental PGN game splitter: feed it lines, receive games.
///
/// Splits on the header/movetext boundary and tolerates missing blank lines
/// between games, which hand-edited and scraped files routinely omit.  The
/// state machine is the same one [splitPgnGames] runs over a whole string;
/// exposing it line by line is what lets the scanner stream a file.
class PgnGameSplitter {
  PgnGameSplitter(this._onGame);

  final void Function(PgnGame game) _onGame;

  Map<String, String> _headers = <String, String>{};
  final StringBuffer _movetext = StringBuffer();
  bool _inMovetext = false;

  void addLine(String line) {
    final trimmed = line.trim();

    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      if (_inMovetext) _flush();
      final match = _headerPattern.firstMatch(trimmed);
      if (match != null) _headers[match.group(1)!] = match.group(2)!;
    } else if (trimmed.isEmpty) {
      if (_headers.isNotEmpty && !_inMovetext) {
        _inMovetext = true;
      } else if (_inMovetext) {
        _flush();
      }
    } else {
      _inMovetext = true;
      if (_movetext.isNotEmpty) _movetext.write(' ');
      _movetext.write(trimmed);
    }
  }

  /// Emit the game in progress, if any.  Call once after the last line.
  void close() => _flush();

  void _flush() {
    if (_movetext.isEmpty) return;
    _onGame(PgnGame(headers: _headers, movetext: _movetext.toString()));
    _headers = <String, String>{};
    _movetext.clear();
    _inMovetext = false;
  }
}

/// Split a PGN string into games.  See [PgnGameSplitter].
List<PgnGame> splitPgnGames(String pgn) {
  final games = <PgnGame>[];
  final splitter = PgnGameSplitter(games.add);
  var start = 0;
  while (start <= pgn.length) {
    var end = pgn.indexOf('\n', start);
    if (end < 0) end = pgn.length;
    splitter.addLine(pgn.substring(start, end));
    start = end + 1;
  }
  splitter.close();
  return games;
}

/// Tokenize movetext, skipping comments, variations, and NAGs.
///
/// Works on code units: `movetext[i]` allocates a one-character string, and
/// this runs over every byte of movetext in a multi-million-game database.
List<String> tokenizeMovetext(String movetext) {
  final tokens = <String>[];
  final len = movetext.length;
  var i = 0;

  while (i < len) {
    final ch = movetext.codeUnitAt(i);

    if (_isWhitespace(ch)) {
      i++;
      continue;
    }
    if (ch == _leftBrace) {
      while (i < len && movetext.codeUnitAt(i) != _rightBrace) {
        i++;
      }
      if (i < len) i++;
      continue;
    }
    if (ch == _leftParen) {
      var depth = 1;
      i++;
      while (i < len && depth > 0) {
        final c = movetext.codeUnitAt(i);
        if (c == _leftParen) depth++;
        if (c == _rightParen) depth--;
        i++;
      }
      continue;
    }
    if (ch == _dollar) {
      i++;
      while (i < len && _isDigit(movetext.codeUnitAt(i))) {
        i++;
      }
      continue;
    }

    final start = i;
    while (i < len && !_isTokenBoundary(movetext.codeUnitAt(i))) {
      i++;
    }
    tokens.add(movetext.substring(start, i));
  }
  return tokens;
}

const int _space = 0x20;
const int _tab = 0x09;
const int _cr = 0x0D;
const int _lf = 0x0A;
const int _leftBrace = 0x7B;
const int _rightBrace = 0x7D;
const int _leftParen = 0x28;
const int _rightParen = 0x29;
const int _dollar = 0x24;
const int _dot = 0x2E;

bool _isWhitespace(int c) => c == _space || c == _tab || c == _cr || c == _lf;

bool _isTokenBoundary(int c) =>
    _isWhitespace(c) || c == _leftBrace || c == _leftParen;

bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

bool isResultToken(String token) =>
    token == '1-0' || token == '0-1' || token == '1/2-1/2' || token == '*';

/// Extract a SAN move from a movetext token (`1.e4`, `12.Nf3`, `1...c5`).
/// Returns null for a bare move number.
String? tokenToSan(String token) {
  if (token.isEmpty) return null;

  var i = 0;
  while (i < token.length && _isDigit(token.codeUnitAt(i))) {
    i++;
  }
  if (i == 0) return token;
  if (i >= token.length) return null;
  if (token.codeUnitAt(i) != _dot) return token;
  while (i < token.length && token.codeUnitAt(i) == _dot) {
    i++;
  }
  return i >= token.length ? null : token.substring(i);
}

Move? _parseSanMove(Position position, String san) {
  try {
    return position.parseSan(san);
  } catch (_) {
    return null;
  }
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

// ── Header helpers ───────────────────────────────────────────────────────

int _eloTag(Map<String, String> headers, String tag) {
  final value = headers[tag];
  if (value == null || value.isEmpty || value == '?') return 0;
  return int.tryParse(value) ?? 0;
}

final RegExp _fourDigitYear = RegExp(r'(\d{4})');

int? _year(String? date) {
  if (date == null) return null;
  final match = _fourDigitYear.firstMatch(date);
  return match == null ? null : int.tryParse(match.group(1)!);
}

// ── Warning throttling ───────────────────────────────────────────────────

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
    debugPrint(
      '[PgnFreqParser] Warning: $reason SAN "$failingSan" at FEN $fen '
      '(game #$gameIndex: White=${headers['White'] ?? '?'}, '
      'Black=${headers['Black'] ?? '?'}, Event=${headers['Event'] ?? '?'}, '
      'Date=${headers['Date'] ?? '?'})',
    );
  }

  void logSummaryIfNeeded() {
    if (suppressed <= 0) return;
    debugPrint(
      '[PgnFreqParser] Warning: suppressed $suppressed additional parse '
      'warnings (first $maxDetailed shown)',
    );
  }
}
