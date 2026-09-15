/// Plays one game between two UCI engines and writes it out as PGN.
///
/// The rules layer is dartchess, so the arbiter here only has to do what
/// dartchess does not: run the clocks ([GameClock]), decide when a game that
/// will never finish on its own should be stopped ([ScoreAdjudicator]), and
/// treat a broken engine as a loss rather than a crash.
library;

import 'package:dartchess/dartchess.dart';

import '../../../models/game_outcome.dart';
import '../models/adjudication_rules.dart';
import '../models/engine_spec.dart';
import 'game_clock.dart';
import 'game_ending.dart';
import 'game_pgn_writer.dart';
import 'score_adjudicator.dart';
import 'uci_protocol.dart';

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

    final Position start;
    try {
      start = Chess.fromSetup(Setup.parseFen(context.startFen));
    } catch (e) {
      return _played(
        white: white,
        black: black,
        context: context,
        began: began,
        duration: stopwatch.elapsed,
        startPosition: null,
        sanMoves: const [],
        comments: const [],
        ending: GameEnding(
          GameResult.unfinished,
          TerminationReason.aborted,
          'unplayable start position: $e',
        ),
      );
    }

    final game = _GameInProgress(
      white: white,
      black: black,
      context: context,
      adjudication: adjudication,
      began: began,
      stopwatch: stopwatch,
      start: start,
    );

    for (final (side, participant) in [
      (Side.white, white),
      (Side.black, black),
    ]) {
      try {
        await participant.engine.newGame();
      } on UciFailure catch (e) {
        return game.finish(
          GameEnding.lossFor(
            side,
            TerminationReason.engineFailure,
            '${participant.name}: ${e.message}',
          ),
        );
      }
    }

    while (true) {
      if (isCancelled?.call() ?? false) {
        return game.finish(
          const GameEnding(
            GameResult.unfinished,
            TerminationReason.aborted,
            'cancelled',
          ),
        );
      }

      final ending = game.endingBeforeMove();
      if (ending != null) return game.finish(ending);

      final EngineSearch search;
      try {
        search = await game.askForMove();
      } on UciFailure catch (e) {
        return game.finish(
          GameEnding.lossFor(
            game.sideToMove,
            TerminationReason.engineFailure,
            '${game.mover.name}: ${e.message}',
          ),
        );
      }

      final afterMove = game.applyMove(search, onMove: onMove);
      if (afterMove != null) return game.finish(afterMove);
    }
  }
}

/// The mutable state of one game while it is being played.
class _GameInProgress {
  _GameInProgress({
    required this.white,
    required this.black,
    required this.context,
    required AdjudicationRules adjudication,
    required this.began,
    required this.stopwatch,
    required Position start,
  }) : rules = adjudication,
       startPosition = start,
       position = start,
       clock = GameClock(context.timeControl),
       adjudicator = ScoreAdjudicator(adjudication),
       repetitions = {_repetitionKey(start): 1};

  final EngineParticipant white;
  final EngineParticipant black;
  final GamePgnContext context;
  final AdjudicationRules rules;
  final DateTime began;
  final Stopwatch stopwatch;
  final Position startPosition;
  final GameClock clock;
  final ScoreAdjudicator adjudicator;

  Position position;
  final List<String> sanMoves = [];
  final List<String> comments = [];
  final List<String> wireMoves = [];

  /// Occurrences of each position, for the threefold rule.
  final Map<String, int> repetitions;

  Side get sideToMove => position.turn;
  EngineParticipant get mover => sideToMove == Side.white ? white : black;

  /// Checkmate, a drawn position, or the move ceiling — anything that ends
  /// the game without asking the engine.
  GameEnding? endingBeforeMove() {
    if (position.isCheckmate) {
      return GameEnding.lossFor(sideToMove, TerminationReason.checkmate);
    }
    if (position.isStalemate) {
      return const GameEnding(GameResult.draw, TerminationReason.stalemate);
    }
    if (position.isInsufficientMaterial) {
      return const GameEnding(
        GameResult.draw,
        TerminationReason.insufficientMaterial,
      );
    }
    if (rules.fiftyMoveRule && position.halfmoves >= 100) {
      return const GameEnding(GameResult.draw, TerminationReason.fiftyMoveRule);
    }
    if (rules.threefoldRepetition &&
        (repetitions[_repetitionKey(position)] ?? 0) >= 3) {
      return const GameEnding(
        GameResult.draw,
        TerminationReason.threefoldRepetition,
      );
    }
    if (position.fullmoves > rules.maxMoves) {
      return GameEnding(
        GameResult.draw,
        TerminationReason.maxMoves,
        'reached ${rules.maxMoves} moves',
      );
    }
    return null;
  }

  Future<EngineSearch> askForMove() => mover.engine.search(
    startFen: context.startFen,
    movesUci: wireMoves,
    limits: clock.limitsFor(sideToMove),
    hardLimit: clock.hardLimitFor(sideToMove),
  );

  /// Charge the clock, play the move and adjudicate. Returns the ending if
  /// the move finished the game one way or another.
  GameEnding? applyMove(
    EngineSearch search, {
    required void Function(GameMoveEvent event)? onMove,
  }) {
    final side = sideToMove;
    final remainingMs = clock.remainingMs(side);
    if (clock.charge(side, search.elapsedMs)) {
      return GameEnding.lossFor(
        side,
        TerminationReason.timeForfeit,
        _timeForfeitDetail(search.elapsedMs, remainingMs),
      );
    }

    final move = search.hasMove ? Move.parse(search.bestMoveUci) : null;
    if (move == null || !_isPlayable(position, move)) {
      return GameEnding.lossFor(
        side,
        TerminationReason.illegalMove,
        '${mover.name} played "${search.bestMoveUci}" in ${position.fen}',
      );
    }

    final resetsDrawCounter = _resetsDrawCounter(position, move);
    final moveNumber = position.fullmoves;
    final wire = wireUci(position, move);
    final (next, san) = position.makeSan(move);
    position = next;
    sanMoves.add(san);
    wireMoves.add(wire);
    comments.add(formatMoveComment(search));
    final key = _repetitionKey(position);
    repetitions[key] = (repetitions[key] ?? 0) + 1;

    onMove?.call(
      GameMoveEvent(
        ply: sanMoves.length,
        moveNumber: moveNumber,
        san: san,
        fen: position.fen,
        byWhite: side == Side.white,
        depth: search.depth,
        elapsedMs: search.elapsedMs,
        scoreCp: search.scoreCp,
        scoreMate: search.scoreMate,
        whiteClockMs: clock.displayMs(Side.white),
        blackClockMs: clock.displayMs(Side.black),
      ),
    );

    return adjudicator.observe(
      mover: side,
      moverName: (side == Side.white ? white : black).name,
      scoreCp: search.comparableCp,
      resetsDrawCounter: resetsDrawCounter,
      fullmoves: position.fullmoves,
    );
  }

  String _timeForfeitDetail(int elapsedMs, int remainingMs) {
    final tc = context.timeControl;
    final used = (elapsedMs / 1000).toStringAsFixed(1);
    final budget = tc.isTimed
        ? 'with ${(remainingMs / 1000).toStringAsFixed(1)}s left'
        : 'on a ${tc.label} budget';
    return '${mover.name} used ${used}s $budget';
  }

  PlayedGame finish(GameEnding ending) {
    stopwatch.stop();
    return _played(
      white: white,
      black: black,
      context: context,
      began: began,
      duration: stopwatch.elapsed,
      startPosition: startPosition,
      sanMoves: sanMoves,
      comments: comments,
      ending: ending,
    );
  }
}

PlayedGame _played({
  required EngineParticipant white,
  required EngineParticipant black,
  required GamePgnContext context,
  required DateTime began,
  required Duration duration,
  required Position? startPosition,
  required List<String> sanMoves,
  required List<String> comments,
  required GameEnding ending,
}) => PlayedGame(
  result: ending.result,
  termination: ending.termination,
  detail: ending.detail,
  sanMoves: List.unmodifiable(sanMoves),
  duration: duration,
  pgn: buildGamePgn(
    whiteName: white.name,
    blackName: black.name,
    context: context,
    startPosition: startPosition,
    sanMoves: sanMoves,
    comments: comments,
    result: ending.result,
    termination: ending.termination,
    detail: ending.detail,
    began: began,
    duration: duration,
  ),
);

/// Legal, *and* complete. dartchess accepts a pawn move to the last rank
/// with no promotion piece and then leaves the pawn standing there; UCI
/// requires the piece, so an engine that omits it has made an illegal
/// move, not a queen.
bool _isPlayable(Position position, Move move) {
  if (!position.isLegal(move)) return false;
  return move is! NormalMove ||
      move.promotion != null ||
      !position.board.pawns.has(move.from) ||
      !SquareSet.backranks.has(move.to);
}

/// Captures and pawn moves restart the draw-adjudication count, because the
/// position is no longer the one that looked dead.
bool _resetsDrawCounter(Position position, Move move) {
  if (move is! NormalMove) return true;
  final piece = position.board.pieceAt(move.from);
  if (piece?.role == Role.pawn) return true;
  return position.board.pieceAt(move.to) != null;
}

/// Repetition identity: the position without the move counters, which is what
/// the threefold rule actually compares.
String _repetitionKey(Position position) =>
    position.fen.split(' ').take(4).join(' ');

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
