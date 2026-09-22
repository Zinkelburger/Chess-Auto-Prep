/// Folding one PGN game into a [PgnFreqMap].
///
/// The scanner replays a game's moves, counting each position and move it
/// passes through (up to the configured depth, and only once the game has
/// reached the tracking target), and offers strong games whole to the map's
/// model-game reservoir.  Lenient by design: an unparsable move ends the
/// game's statistics rather than the scan.
library;

import 'package:dartchess/dartchess.dart' show Chess, Move, Position;
import 'package:flutter/foundation.dart';

import '../../utils/chess_utils.dart' show isNullMoveSan, playSanOrNullMove;
import '../../chess_core/position/eval_canonicalize.dart';
import 'pgn_freq_map.dart';
import 'pgn_lexer.dart';

/// Deepest ply at which a position still records references to the games that
/// passed through it.  Model-game matching only ever walks the repertoire
/// spine, and past this depth a position belongs to a single game anyway.
const int kGameRefMaxPly = 40;

/// What became of one game handed to [PgnGameScanner.scan].
enum GameScan {
  /// Counted into the map.
  ok,

  /// Both players rated and both below the Elo floor.
  belowEloFloor,

  /// Never reached the tracking target position.
  prefixSkip,

  /// A move inside the counted window could not be parsed.
  error,
}

/// Elo tag value, 0 when absent, empty or `?`.
int eloTag(Map<String, String> headers, String tag) {
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

/// Everything the scanner extracts from a game's headers up front.
class _GameContext {
  final GameOutcome? outcome;
  final int? averageElo;
  final int? year;

  const _GameContext({this.outcome, this.averageElo, this.year});

  factory _GameContext.fromHeaders(Map<String, String> headers) {
    final white = eloTag(headers, 'WhiteElo');
    final black = eloTag(headers, 'BlackElo');
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

/// Scans games into [map] under [config].
///
/// [targetKey] is the 4-field FEN a game must reach before its moves count
/// (see `buildTrackingTarget`); null tracks from move one.
class PgnGameScanner {
  PgnGameScanner({
    required this.map,
    required this.config,
    required this.targetKey,
    required this.warnings,
  });

  final PgnFreqMap map;
  final PgnFreqConfig config;
  final String? targetKey;
  final PgnScanWarnings warnings;

  /// Fold [game] into [map].  [gameIndex] only labels warnings.
  GameScan scan(PgnGame game, {required int gameIndex}) {
    if (_belowEloFloor(game.headers)) return GameScan.belowEloFloor;

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
      map.recordReach(fenKey);
      visitedKeys.add(fenKey);
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
          );
          return GameScan.error;
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
        );
        return GameScan.error;
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

    if (!tracking) return GameScan.prefixSkip;

    _retainGame(game.headers, context, trackedMoves, visitedKeys);
    return GameScan.ok;
  }

  /// True when both players are rated and *both* fall below the Elo floor.
  /// A single known rating above the floor keeps the game — databases are
  /// full of half-rated pairings and dropping them silently skews the sample.
  bool _belowEloFloor(Map<String, String> headers) {
    final minElo = config.minElo;
    if (minElo <= 0) return false;
    final white = eloTag(headers, 'WhiteElo');
    final black = eloTag(headers, 'BlackElo');
    return white > 0 && black > 0 && white < minElo && black < minElo;
  }

  /// Offer the game to the reservoir and, if admitted, back-reference it
  /// from every position it passed through.
  void _retainGame(
    Map<String, String> headers,
    _GameContext context,
    List<String> movesSan,
    List<String> visitedKeys,
  ) {
    if (config.retainGames <= 0 || movesSan.isEmpty) return;
    final elo = context.averageElo ?? 0;
    if (config.retainMinElo > 0 && elo > 0 && elo < config.retainMinElo) {
      return;
    }

    final index = map.games.offer(
      PgnGameRecord(
        white: headers['White'] ?? '',
        black: headers['Black'] ?? '',
        whiteElo: eloTag(headers, 'WhiteElo'),
        blackElo: eloTag(headers, 'BlackElo'),
        event: headers['Event'] ?? '',
        date: headers['Date'] ?? headers['UTCDate'] ?? '',
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

  static Move? _parseSanMove(Position position, String san) {
    try {
      return position.parseSan(san);
    } catch (_) {
      // dartchess throws on a malformed SAN token; the caller treats it
      // exactly like an illegal move.
      return null;
    }
  }
}

/// Throttled warnings for unparsable moves: the first few in full, then a
/// count, so a corrupt database does not flood the log.
class PgnScanWarnings {
  static const int maxDetailed = 10;
  int logged = 0;
  int suppressed = 0;

  void logMoveFailure({
    required int gameIndex,
    required Map<String, String> headers,
    required String failingSan,
    required String fen,
  }) {
    if (logged >= maxDetailed) {
      suppressed++;
      return;
    }
    logged++;
    debugPrint(
      '[PgnFreqParser] Warning: cannot parse move SAN "$failingSan" at FEN '
      '$fen (game #$gameIndex: White=${headers['White'] ?? '?'}, '
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
