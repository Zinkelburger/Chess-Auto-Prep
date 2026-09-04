/// Plays one game between two UCI engines and writes it out as PGN.
///
/// The rules layer is dartchess, so the arbiter here only has to do what
/// dartchess does not: run the clocks, decide when a game that will never
/// finish on its own should be stopped, and treat a broken engine as a loss
/// rather than a crash.
///
/// Move comments are opt-in (`GamePgnContext.annotateMoves`). When they are
/// on, the scores follow the cutechess convention — the value the engine
/// reported, from *its own* side's point of view — so `{+0.31/24 2.0s}` after
/// a Black move means Black thinks Black is better.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';

import '../../../constants/chess_constants.dart';
import '../../../models/game_outcome.dart';
import '../../../services/generation/export/pgn_game_writer.dart'
    show escapePgnHeaderValue;
import '../../../utils/movetext_builder.dart';
import '../models/adjudication_rules.dart';
import '../models/engine_spec.dart';
import '../models/time_control.dart';
import 'uci_engine.dart';

/// Slack allowed on a clock before the flag falls, covering pipe latency and
/// process scheduling rather than the engine's own thinking. cutechess calls
/// the same knob `-timemargin`; a desktop running several games at once
/// needs more of it than a dedicated test box.
const int kTimeMarginMs = 500;

/// A competitor, bound to a live process for the duration of a game.
class EngineParticipant {
  EngineParticipant({
    required this.index,
    required this.spec,
    required this.engine,
  });

  /// Index into `TournamentConfig.engines` — the crosstable's identity, which
  /// display names cannot supply because an engine may play itself.
  final int index;

  final EngineSpec spec;
  final PlayingEngine engine;

  String get name => spec.name;
}

/// One move, as it happens, for the live view.
class GameMoveEvent {
  const GameMoveEvent({
    required this.ply,
    required this.moveNumber,
    required this.san,
    required this.fen,
    required this.byWhite,
    required this.depth,
    required this.elapsedMs,
    this.scoreCp,
    this.scoreMate,
    this.whiteClockMs,
    this.blackClockMs,
  });

  /// 1-based ply within this game.
  final int ply;

  /// Full-move number the move belongs to, counted from the start position —
  /// a game beginning at move 31 says 31, not 1.
  final int moveNumber;

  final String san;
  final String fen;
  final bool byWhite;
  final int depth;
  final int elapsedMs;
  final int? scoreCp;
  final int? scoreMate;
  final int? whiteClockMs;
  final int? blackClockMs;
}

/// Everything a finished game leaves behind.
class PlayedGame {
  const PlayedGame({
    required this.result,
    required this.termination,
    required this.detail,
    required this.sanMoves,
    required this.pgn,
    required this.duration,
  });

  final GameResult result;
  final TerminationReason termination;
  final String detail;
  final List<String> sanMoves;
  final String pgn;
  final Duration duration;

  int get plies => sanMoves.length;
}

/// Header material that comes from the tournament rather than the game.
class GamePgnContext {
  const GamePgnContext({
    required this.event,
    required this.site,
    required this.round,
    required this.startFen,
    required this.timeControl,
    this.openingLabel = '',
    this.annotateMoves = false,
  });

  final String event;
  final String site;
  final int round;
  final String startFen;
  final TimeControl timeControl;
  final String openingLabel;

  /// Write the engine's score/depth/time after every move.
  ///
  /// Off by default: a comment on every ply is what engine-testing tools want
  /// and what makes the game unreadable for anyone opening it in the PGN
  /// viewer, which is where these games are usually opened.
  final bool annotateMoves;
}

class EngineGameRunner {
  const EngineGameRunner();

  /// Play [white] against [black] from [context].startFen.
  ///
  /// Never throws for engine misbehaviour: a crash, a hang, or an illegal
  /// move is a *result* (a loss for the offender), because a tournament that
  /// aborts on the first flaky engine is useless for the thing tournaments
  /// are for.
  Future<PlayedGame> play({
    required EngineParticipant white,
    required EngineParticipant black,
    required GamePgnContext context,
    required AdjudicationRules adjudication,
    DateTime? startedAt,
    void Function(GameMoveEvent event)? onMove,
    bool Function()? isCancelled,
  }) async {
    final began = startedAt ?? DateTime.now();
    final stopwatch = Stopwatch()..start();
    final tc = context.timeControl;

    Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(context.startFen));
    } catch (e) {
      return _finish(
        white: white,
        black: black,
        context: context,
        began: began,
        stopwatch: stopwatch,
        sanMoves: const [],
        comments: const [],
        startPosition: null,
        result: GameResult.unfinished,
        termination: TerminationReason.aborted,
        detail: 'unplayable start position: $e',
      );
    }

    final startPosition = position;
    final sanMoves = <String>[];
    final comments = <String>[];
    final wireMoves = <String>[];
    final repetitions = <String, int>{_repetitionKey(position): 1};

    var whiteClockMs = tc.baseMs;
    var blackClockMs = tc.baseMs;
    var whiteMovesThisSession = 0;
    var blackMovesThisSession = 0;

    var drawStreakPlies = 0;
    final losingStreak = {Side.white: 0, Side.black: 0};
    final winningStreak = {Side.white: 0, Side.black: 0};

    for (final participant in [white, black]) {
      try {
        await participant.engine.newGame();
      } on UciFailure catch (e) {
        return _finish(
          white: white,
          black: black,
          context: context,
          began: began,
          stopwatch: stopwatch,
          sanMoves: sanMoves,
          comments: comments,
          startPosition: startPosition,
          result: participant.index == white.index
              ? GameResult.blackWins
              : GameResult.whiteWins,
          termination: TerminationReason.engineFailure,
          detail: '${participant.name}: ${e.message}',
        );
      }
    }

    while (true) {
      if (isCancelled?.call() ?? false) {
        return _finish(
          white: white,
          black: black,
          context: context,
          began: began,
          stopwatch: stopwatch,
          sanMoves: sanMoves,
          comments: comments,
          startPosition: startPosition,
          result: GameResult.unfinished,
          termination: TerminationReason.aborted,
          detail: 'cancelled',
        );
      }

      final natural = _naturalEnd(position, repetitions, adjudication);
      if (natural != null) {
        return _finish(
          white: white,
          black: black,
          context: context,
          began: began,
          stopwatch: stopwatch,
          sanMoves: sanMoves,
          comments: comments,
          startPosition: startPosition,
          result: natural.result,
          termination: natural.termination,
          detail: '',
        );
      }

      if (position.fullmoves > adjudication.maxMoves) {
        return _finish(
          white: white,
          black: black,
          context: context,
          began: began,
          stopwatch: stopwatch,
          sanMoves: sanMoves,
          comments: comments,
          startPosition: startPosition,
          result: GameResult.draw,
          termination: TerminationReason.maxMoves,
          detail: 'reached ${adjudication.maxMoves} moves',
        );
      }

      final toMove = position.turn;
      final mover = toMove == Side.white ? white : black;
      final remainingMs = toMove == Side.white ? whiteClockMs : blackClockMs;

      final limits = _limitsFor(
        tc,
        whiteClockMs: whiteClockMs,
        blackClockMs: blackClockMs,
        movesPlayedThisSession: toMove == Side.white
            ? whiteMovesThisSession
            : blackMovesThisSession,
      );

      final EngineSearch search;
      try {
        search = await mover.engine.search(
          startFen: context.startFen,
          movesUci: wireMoves,
          limits: limits,
          hardLimit: tc.hardLimitFor(remainingMs: remainingMs),
        );
      } on UciFailure catch (e) {
        return _finish(
          white: white,
          black: black,
          context: context,
          began: began,
          stopwatch: stopwatch,
          sanMoves: sanMoves,
          comments: comments,
          startPosition: startPosition,
          result: toMove == Side.white
              ? GameResult.blackWins
              : GameResult.whiteWins,
          termination: TerminationReason.engineFailure,
          detail: '${mover.name}: ${e.message}',
        );
      }

      // ── Clock ──────────────────────────────────────────────────────────
      final overspend = _updateClock(
        tc: tc,
        elapsedMs: search.elapsedMs,
        remainingMs: remainingMs,
      );
      if (overspend.forfeit) {
        return _finish(
          white: white,
          black: black,
          context: context,
          began: began,
          stopwatch: stopwatch,
          sanMoves: sanMoves,
          comments: comments,
          startPosition: startPosition,
          result: toMove == Side.white
              ? GameResult.blackWins
              : GameResult.whiteWins,
          termination: TerminationReason.timeForfeit,
          detail:
              '${mover.name} used ${(search.elapsedMs / 1000).toStringAsFixed(1)}s '
              '${tc.isTimed ? "with ${(remainingMs / 1000).toStringAsFixed(1)}s left" : "on a ${tc.label} budget"}',
        );
      }
      if (toMove == Side.white) {
        whiteClockMs = overspend.remainingMs;
        whiteMovesThisSession++;
        if (tc.movesPerSession != null &&
            whiteMovesThisSession % tc.movesPerSession! == 0) {
          whiteClockMs += tc.baseMs;
        }
      } else {
        blackClockMs = overspend.remainingMs;
        blackMovesThisSession++;
        if (tc.movesPerSession != null &&
            blackMovesThisSession % tc.movesPerSession! == 0) {
          blackClockMs += tc.baseMs;
        }
      }

      // ── The move itself ────────────────────────────────────────────────
      final move = search.hasMove ? Move.parse(search.bestMoveUci) : null;
      if (move == null || !position.isLegal(move)) {
        return _finish(
          white: white,
          black: black,
          context: context,
          began: began,
          stopwatch: stopwatch,
          sanMoves: sanMoves,
          comments: comments,
          startPosition: startPosition,
          result: toMove == Side.white
              ? GameResult.blackWins
              : GameResult.whiteWins,
          termination: TerminationReason.illegalMove,
          detail:
              '${mover.name} played "${search.bestMoveUci}" in '
              '${position.fen}',
        );
      }

      final wasCaptureOrPawn = _resetsDrawCounter(position, move);
      final moveNumber = position.fullmoves;
      final wire = wireUci(position, move);
      final (next, san) = position.makeSan(move);
      position = next;
      sanMoves.add(san);
      wireMoves.add(wire);
      comments.add(_moveComment(search));

      final key = _repetitionKey(position);
      repetitions[key] = (repetitions[key] ?? 0) + 1;

      onMove?.call(
        GameMoveEvent(
          ply: sanMoves.length,
          moveNumber: moveNumber,
          san: san,
          fen: position.fen,
          byWhite: toMove == Side.white,
          depth: search.depth,
          elapsedMs: search.elapsedMs,
          scoreCp: search.scoreCp,
          scoreMate: search.scoreMate,
          whiteClockMs: tc.isTimed ? whiteClockMs : null,
          blackClockMs: tc.isTimed ? blackClockMs : null,
        ),
      );

      // ── Adjudication ───────────────────────────────────────────────────
      final scoreCp = search.comparableCp;

      if (adjudication.drawEnabled) {
        if (wasCaptureOrPawn ||
            scoreCp == null ||
            scoreCp.abs() > adjudication.drawScoreCp) {
          drawStreakPlies = 0;
        } else {
          drawStreakPlies++;
        }
        if (position.fullmoves >= adjudication.drawMoveNumber &&
            drawStreakPlies >= adjudication.drawMoveCount * 2) {
          return _finish(
            white: white,
            black: black,
            context: context,
            began: began,
            stopwatch: stopwatch,
            sanMoves: sanMoves,
            comments: comments,
            startPosition: startPosition,
            result: GameResult.draw,
            termination: TerminationReason.drawAdjudication,
            detail:
                'both engines under ${adjudication.drawScoreCp}cp for '
                '${adjudication.drawMoveCount} moves',
          );
        }
      }

      if (adjudication.resignEnabled) {
        if (scoreCp != null && scoreCp <= -adjudication.resignScoreCp) {
          losingStreak[toMove] = losingStreak[toMove]! + 1;
        } else {
          losingStreak[toMove] = 0;
        }
        if (scoreCp != null && scoreCp >= adjudication.resignScoreCp) {
          winningStreak[toMove] = winningStreak[toMove]! + 1;
        } else {
          winningStreak[toMove] = 0;
        }
        final opponent = toMove.opposite;
        final resigns =
            losingStreak[toMove]! >= adjudication.resignMoveCount &&
            (!adjudication.twoSidedResign ||
                winningStreak[opponent]! >= adjudication.resignMoveCount);
        if (resigns) {
          return _finish(
            white: white,
            black: black,
            context: context,
            began: began,
            stopwatch: stopwatch,
            sanMoves: sanMoves,
            comments: comments,
            startPosition: startPosition,
            result: toMove == Side.white
                ? GameResult.blackWins
                : GameResult.whiteWins,
            termination: TerminationReason.resignAdjudication,
            detail:
                '${mover.name} below -${adjudication.resignScoreCp}cp for '
                '${adjudication.resignMoveCount} moves',
          );
        }
      }
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  ({GameResult result, TerminationReason termination})? _naturalEnd(
    Position position,
    Map<String, int> repetitions,
    AdjudicationRules rules,
  ) {
    if (position.isCheckmate) {
      return (
        result: position.turn == Side.white
            ? GameResult.blackWins
            : GameResult.whiteWins,
        termination: TerminationReason.checkmate,
      );
    }
    if (position.isStalemate) {
      return (
        result: GameResult.draw,
        termination: TerminationReason.stalemate,
      );
    }
    if (position.isInsufficientMaterial) {
      return (
        result: GameResult.draw,
        termination: TerminationReason.insufficientMaterial,
      );
    }
    if (rules.fiftyMoveRule && position.halfmoves >= 100) {
      return (
        result: GameResult.draw,
        termination: TerminationReason.fiftyMoveRule,
      );
    }
    if (rules.threefoldRepetition &&
        (repetitions[_repetitionKey(position)] ?? 0) >= 3) {
      return (
        result: GameResult.draw,
        termination: TerminationReason.threefoldRepetition,
      );
    }
    return null;
  }

  GoLimits _limitsFor(
    TimeControl tc, {
    required int whiteClockMs,
    required int blackClockMs,
    required int movesPlayedThisSession,
  }) {
    switch (tc.kind) {
      case TimeControlKind.movetime:
        return GoLimits(movetimeMs: tc.movetimeMs);
      case TimeControlKind.fixedDepth:
        return GoLimits(depth: tc.depth);
      case TimeControlKind.fixedNodes:
        return GoLimits(nodes: tc.nodes);
      case TimeControlKind.incremental:
        final period = tc.movesPerSession;
        return GoLimits(
          whiteTimeMs: whiteClockMs < 1 ? 1 : whiteClockMs,
          blackTimeMs: blackClockMs < 1 ? 1 : blackClockMs,
          whiteIncrementMs: tc.incrementMs,
          blackIncrementMs: tc.incrementMs,
          movesToGo: period == null
              ? null
              : period - (movesPlayedThisSession % period),
        );
    }
  }

  /// Charge [elapsedMs] to the mover's clock and say whether the flag fell.
  ///
  /// Untimed controls cannot forfeit on the clock — a slow engine there is
  /// caught by the hang guard in [UciEngine.search] instead — except in the
  /// per-move case, where Scid vs. PC's 175%-of-nominal rule applies.
  ({bool forfeit, int remainingMs}) _updateClock({
    required TimeControl tc,
    required int elapsedMs,
    required int remainingMs,
  }) {
    switch (tc.kind) {
      case TimeControlKind.movetime:
        final ceiling = (tc.movetimeMs * 1.75).round() + kTimeMarginMs;
        return (forfeit: elapsedMs > ceiling, remainingMs: remainingMs);
      case TimeControlKind.fixedDepth:
      case TimeControlKind.fixedNodes:
        return (forfeit: false, remainingMs: remainingMs);
      case TimeControlKind.incremental:
        final left = remainingMs - elapsedMs;
        if (left < -kTimeMarginMs) {
          return (forfeit: true, remainingMs: 0);
        }
        return (
          forfeit: false,
          remainingMs: (left < 0 ? 0 : left) + tc.incrementMs,
        );
    }
  }

  bool _resetsDrawCounter(Position position, Move move) {
    if (move is! NormalMove) return true;
    final piece = position.board.pieceAt(move.from);
    if (piece?.role == Role.pawn) return true;
    return position.board.pieceAt(move.to) != null;
  }

  PlayedGame _finish({
    required EngineParticipant white,
    required EngineParticipant black,
    required GamePgnContext context,
    required DateTime began,
    required Stopwatch stopwatch,
    required List<String> sanMoves,
    required List<String> comments,
    required Position? startPosition,
    required GameResult result,
    required TerminationReason termination,
    required String detail,
  }) {
    stopwatch.stop();
    final duration = stopwatch.elapsed;
    return PlayedGame(
      result: result,
      termination: termination,
      detail: detail,
      sanMoves: List.unmodifiable(sanMoves),
      duration: duration,
      pgn: buildGamePgn(
        whiteName: white.name,
        blackName: black.name,
        context: context,
        startPosition: startPosition,
        sanMoves: sanMoves,
        comments: comments,
        result: result,
        termination: termination,
        detail: detail,
        began: began,
        duration: duration,
      ),
    );
  }
}

/// `{+0.31/24 2.001s}` — cutechess's move comment, which every engine-testing
/// tool and most GUIs already know how to read.
String _moveComment(EngineSearch search) {
  final buffer = StringBuffer();
  if (search.scoreMate != null) {
    final n = search.scoreMate!;
    buffer.write('${n >= 0 ? '+' : '-'}M${n.abs()}');
  } else if (search.scoreCp != null) {
    final pawns = search.scoreCp! / 100;
    buffer.write('${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(2)}');
  } else {
    buffer.write('book');
  }
  if (search.depth > 0) buffer.write('/${search.depth}');
  buffer.write(' ${(search.elapsedMs / 1000).toStringAsFixed(3)}s');
  return buffer.toString();
}

/// Repetition identity: the position without the move counters, which is what
/// the threefold rule actually compares.
String _repetitionKey(Position position) {
  final parts = position.fen.split(' ');
  return parts.take(4).join(' ');
}

/// The spelling of [move] to put on the wire.
///
/// dartchess encodes castling as king-takes-own-rook, which a non-Chess960
/// engine rejects when it is replayed to it in `position … moves`. Standard
/// engines emit and expect the king-two-squares form, so that is what is
/// forwarded.
String wireUci(Position position, Move move) {
  if (move is! NormalMove) return move.uci;
  final piece = position.board.pieceAt(move.from);
  if (piece == null || piece.role != Role.king) return move.uci;
  final target = position.board.pieceAt(move.to);
  if (target == null ||
      target.color != position.turn ||
      target.role != Role.rook) {
    return move.uci;
  }
  final side = move.to > move.from ? CastlingSide.king : CastlingSide.queen;
  return NormalMove(
    from: move.from,
    to: kingCastlesTo(position.turn, side),
  ).uci;
}

/// Serialize a finished game. Public so the headless runner and the tests can
/// build the same text the app writes.
String buildGamePgn({
  required String whiteName,
  required String blackName,
  required GamePgnContext context,
  required Position? startPosition,
  required List<String> sanMoves,
  required List<String> comments,
  required GameResult result,
  required TerminationReason termination,
  required String detail,
  required DateTime began,
  required Duration duration,
}) {
  final headers = <String, String>{
    'Event': context.event,
    'Site': context.site,
    'Date': _pgnDate(began),
    'Round': '${context.round}',
    'White': whiteName,
    'Black': blackName,
    'Result': result.pgnToken,
    if (context.openingLabel.isNotEmpty) 'Opening': context.openingLabel,
    'TimeControl': context.timeControl.pgnTag,
    'Termination': termination.pgnTag,
    'PlyCount': '${sanMoves.length}',
    'WhiteType': 'program',
    'BlackType': 'program',
    'GameStartTime': began.toIso8601String(),
    'GameDuration': _hms(duration),
  };

  final buffer = StringBuffer();
  for (final entry in headers.entries) {
    if (entry.value.isEmpty) continue;
    buffer.writeln('[${entry.key} "${escapePgnHeaderValue(entry.value)}"]');
  }
  final needsFen =
      startPosition != null && context.startFen != kStandardStartFen;
  if (needsFen) {
    buffer
      ..writeln('[FEN "${context.startFen}"]')
      ..writeln('[SetUp "1"]');
  }
  buffer.writeln();

  // Why the game stopped is the first thing anyone opening the PGN wants,
  // and PGN's own Termination vocabulary is too coarse to carry it.
  final reason = detail.isEmpty
      ? termination.label
      : '${termination.label}: $detail';
  buffer.write('{${_commentSafe(reason)}} ');

  final movetext = buildNumberedMovetext(
    sanMoves,
    startMoveNumber: startPosition?.fullmoves ?? 1,
    whiteToMoveFirst: (startPosition?.turn ?? Side.white) == Side.white,
    suffix: !context.annotateMoves
        ? null
        : (index) => index < comments.length ? ' {${comments[index]}}' : null,
  );
  if (movetext.isNotEmpty) buffer.write('$movetext ');
  buffer.writeln(result.pgnToken);
  return buffer.toString();
}

/// Braces close a PGN comment and newlines end a line of movetext, so
/// neither can survive inside one. Engine failure details carry raw stderr,
/// which is exactly where both turn up.
String _commentSafe(String text) =>
    text.replaceAll(RegExp(r'[{}]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

String _pgnDate(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}.'
    '${when.month.toString().padLeft(2, '0')}.'
    '${when.day.toString().padLeft(2, '0')}';

String _hms(Duration d) =>
    '${d.inHours.toString().padLeft(2, '0')}:'
    '${(d.inMinutes % 60).toString().padLeft(2, '0')}:'
    '${(d.inSeconds % 60).toString().padLeft(2, '0')}';
