/// Plays a bughouse match out: the engine on both teams, from one opening,
/// as many times as asked.
///
/// The chess side of the app has [EngineGameRunner], which drives two UCI
/// processes and arbitrates between them. This is the two-board equivalent and
/// it is a different shape, for a reason worth stating up front: **bughouse
/// has no turn**. Each board has its own side to move, so at any moment one
/// team may hold both moves, one, or none, and a "ply" here is a *joint
/// action* — one decision spanning two boards, in which sitting is a legal
/// choice.
///
/// So there is no alternation to arbitrate. What there is instead:
///
///   * the two teams are asked in turn, skipping a team with nothing to move,
///     which is exactly what `playout` does in the MCP server;
///   * a captured piece crosses to the other board, which
///     [BughouseState.playMove] already does — the arbiter here does not
///     re-implement a single rule of the game;
///   * both halves of a joint action are resolved against the position the
///     engine saw, before either is applied, so a piece captured on board 1
///     cannot pay for a drop on board 2 in the same action. The engine never
///     chose that, because it decided both halves from one position.
///
/// One Hivemind process plays both teams. That is not a shortcut — there is
/// one bughouse engine and one network — and it is why a participant differs
/// from another only in how hard it thinks.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';

import '../../../models/game_outcome.dart';
import '../models/bughouse_history.dart';
import '../models/bughouse_rules.dart';
import '../models/bughouse_state.dart';
import '../models/bughouse_tournament.dart';
import 'bughouse_engine.dart';

/// Thrown when the match cannot continue — the engine died, or its answers
/// stopped making sense.
class BughouseTournamentFailure implements Exception {
  BughouseTournamentFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class BughouseTournamentRunner {
  BughouseTournamentRunner({
    required this.engine,
    required this.config,
    this.onGameFinished,
    this.onPosition,
  }) : _random = math.Random(config.seed);

  final BughouseAnalysisEngine engine;
  final BughouseTournamentConfig config;

  /// Called as each game finishes, so the panel and the file on disk fill in
  /// while the match runs rather than at the end of it.
  final void Function(BughouseGameRecord game)? onGameFinished;

  /// Called after every joint action with the game so far, so the lab's own
  /// two boards show the game being played.
  final void Function(BughouseHistory line)? onPosition;

  final math.Random _random;

  bool _stopped = false;

  /// Asks the match to stop after the game in flight. The search already
  /// running is cut short; its `bestmove` still arrives.
  void stop() {
    _stopped = true;
    engine.stop();
  }

  bool get isStopped => _stopped;

  /// Plays every game, returning them in order. Stops early — with the games
  /// already played — when [stop] is called.
  Future<List<BughouseGameRecord>> run() async {
    final start = config.startState;
    if (start == null) {
      throw BughouseTournamentFailure(
        'The starting position could not be read: ${config.startDualFen}',
      );
    }
    // The process is shared, so these belong to the match rather than to a
    // team, and they only have to be sent once.
    await engine.setOption('Hash', config.hashMb);
    await engine.setOption('BatchSize', config.batchSize);

    final played = <BughouseGameRecord>[];
    for (var index = 0; index < config.games && !_stopped; index++) {
      final game = await _playGame(index, start);
      played.add(game);
      onGameFinished?.call(game);
      if (game.termination == TerminationReason.engineFailure) {
        throw BughouseTournamentFailure(game.detail);
      }
    }
    return played;
  }

  /// Which participant holds White on board 1 in game [index].
  ///
  /// Colours alternate so an even number of games gives each participant the
  /// same number of Whites — the same rule the engine tournament uses, and the
  /// reason its crosstable measures the engines rather than the opening.
  (int white, int black) seatsFor(int index) {
    final swap = config.alternateSeats && index.isOdd;
    return swap ? (1, 0) : (0, 1);
  }

  Future<BughouseGameRecord> _playGame(int index, BughouseState start) async {
    final startedAt = DateTime.now();
    final stopwatch = Stopwatch()..start();
    final (whiteIndex, blackIndex) = seatsFor(index);
    final line = BughouseHistory(start);

    var result = GameResult.unfinished;
    var termination = TerminationReason.aborted;
    var detail = '';

    // Teams take it in turns to be asked. Whoever is not on move anywhere is
    // skipped rather than searched: asking costs a full search and comes back
    // with `bestmove (none)`.
    var mover = Side.white;
    var consecutivePasses = 0;

    try {
      while (true) {
        if (_stopped) {
          termination = TerminationReason.aborted;
          detail = 'stopped';
          break;
        }
        final position = line.current;

        final ending = _endingOf(position);
        if (ending != null) {
          result = ending.result;
          termination = ending.termination;
          detail = ending.detail;
          break;
        }

        if (line.length >= config.maxPlies) {
          result = GameResult.draw;
          termination = TerminationReason.maxMoves;
          break;
        }

        if (!position.hasMoveFor(mover)) {
          mover = mover.opposite;
          continue;
        }

        final participant =
            config.participants[mover == Side.white ? whiteIndex : blackIndex];
        final action = await _chooseAction(
          position,
          team: mover,
          participant: participant,
          sampling: line.length < config.variety.plies && config.variety.isOn,
        );

        if (_stopped) {
          detail = 'stopped';
          break;
        }
        final plies = _applyAction(line, position, action, mover);
        if (plies == 0) {
          // The engine explicitly chose to sit on every board it holds.
          consecutivePasses++;
          if (consecutivePasses >= 4) {
            result = GameResult.draw;
            termination = TerminationReason.mutualSitting;
            break;
          }
        } else {
          consecutivePasses = 0;
          onPosition?.call(line);
        }
        mover = mover.opposite;
      }
    } on BughouseEngineFailure catch (e) {
      termination = TerminationReason.engineFailure;
      detail = e.message;
    } on BughouseTournamentFailure catch (e) {
      termination = TerminationReason.engineFailure;
      detail = e.message;
    }

    stopwatch.stop();
    return BughouseGameRecord(
      number: index + 1,
      whiteIndex: whiteIndex,
      blackIndex: blackIndex,
      whiteName: config.participants[whiteIndex].name,
      blackName: config.participants[blackIndex].name,
      result: result,
      termination: termination,
      detail: detail,
      moves: [for (final ply in line.plies) ply.enginePrefixedUci],
      startedAt: startedAt,
      durationMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// One search, and the joint action to take from it.
  Future<BughouseJointMove?> _chooseAction(
    BughouseState position, {
    required Side team,
    required BughouseParticipant participant,
    required bool sampling,
  }) async {
    await engine.configure(
      team: team,
      hasTimeAdvantage: position.timeAdvantageFor(team),
      multiPv: sampling ? config.variety.lines : 1,
    );
    await engine.setPosition(position);
    final search = await engine.search(
      movetime: participant.budget.movetime,
      nodes: participant.budget.nodes,
    );
    if (!sampling) return search.best;
    return pickFromShortlist(search, config.variety, _random);
  }

  /// The move to play, given a search and how much variety is allowed.
  ///
  /// Pure and static because this is the part of the runner worth pinning
  /// down: it decides whether a match of ten games is ten games or one game
  /// ten times, and it must never pick a move the engine did not rank.
  ///
  /// Rank 1 is [BughouseSearchResult.best] rather than the top line's own
  /// first move — those differ, because `bestmove` is Hivemind's solver-aware
  /// choice. Everything else comes from a line's principal variation.
  static BughouseJointMove? pickFromShortlist(
    BughouseSearchResult search,
    BughouseVariety variety,
    math.Random random,
  ) {
    final lines = search.lines;
    if (lines.isEmpty) return search.best;
    final top = lines.first;
    // A proven mate is not a matter of taste. Sampling around one would throw
    // away a won game to make the match look varied.
    if (top.mateIn != null) return search.best;

    final candidates = <BughouseJointMove>[];
    final first = search.best ?? _headOf(top);
    if (first != null) candidates.add(first);
    for (final line in lines.skip(1).take(variety.lines - 1)) {
      if (line.mateIn != null) continue;
      if (top.q - line.q > variety.window) continue;
      final head = _headOf(line);
      if (head != null) candidates.add(head);
    }
    if (candidates.isEmpty) return search.best;
    return candidates[random.nextInt(candidates.length)];
  }

  static BughouseJointMove? _headOf(BughouseInfo info) =>
      info.pv.isEmpty ? null : info.pv.first;

  /// Plays [action] onto [line], returning how many plies it added.
  ///
  /// Both halves are resolved against [position] before either is applied —
  /// see the library comment. Invalid answers preserve the partial game and
  /// fail the match rather than silently changing the engine's decision.
  static int _applyAction(
    BughouseHistory line,
    BughouseState position,
    BughouseJointMove? action,
    Side team,
  ) {
    if (action == null) {
      throw BughouseTournamentFailure(
        'Engine returned no joint action in a live position.',
      );
    }
    final resolved = <BughouseBoard, Move>{};
    for (final which in BughouseBoard.values) {
      final half = action.half(which);
      final uci = half.uci;
      if (half.isPass) continue;
      final board = position.board(which);
      final move = uci == null ? null : parseEngineUci(board, uci);
      final side = which == BughouseBoard.a ? team : team.opposite;
      if (board.turn != side || move == null || !board.isLegal(move)) {
        throw BughouseTournamentFailure('Illegal engine action: $action');
      }
      resolved[which] = move;
    }

    var played = 0;
    for (final entry in resolved.entries) {
      final before = line.current;
      final board = before.board(entry.key);
      if (!board.isLegal(entry.value)) continue;
      final san = board.makeSan(entry.value).$2;
      final after = before.playMove(entry.key, entry.value);
      if (after == null) continue;
      line.push(
        BughousePly(
          board: entry.key,
          move: entry.value,
          san: san,
          before: before,
          after: after,
        ),
      );
      played++;
    }
    return played;
  }

  static ({GameResult result, TerminationReason termination, String detail})?
  _endingOf(BughouseState position) {
    for (final team in Side.values) {
      final which = BughouseRules.losingBoard(position, team);
      if (which != null) {
        return (
          result: team == Side.white
              ? GameResult.blackWins
              : GameResult.whiteWins,
          termination: TerminationReason.checkmate,
          detail: position.board(which).isCheck
              ? which.label.toLowerCase()
              : '${which.label.toLowerCase()}: no legal joint action',
        );
      }
    }
    return null;
  }
}

/// Parses the engine's UCI on one board, including `P@e5` drops.
///
/// The same reading the analysis controller uses — a bare `e7e8` becomes a
/// queen promotion — kept here so a replayed game and a live one agree about
/// what a move string meant.
Move? parseEngineUci(Crazyhouse position, String uci) {
  final move = Move.parse(uci);
  if (move == null) return null;
  if (move is NormalMove && move.promotion == null) {
    final piece = position.board.pieceAt(move.from);
    final lastRank = piece?.color == Side.white ? 7 : 0;
    if (piece?.role == Role.pawn && move.to.rank == lastRank) {
      return NormalMove(from: move.from, to: move.to, promotion: Role.queen);
    }
  }
  return move;
}

/// Rebuilds a stored game into a line the lab's boards can walk.
///
/// A game is stored as its board-prefixed half-moves and nothing else, so this
/// is the only thing that turns one back into positions — and it does it with
/// the same [BughouseState.playMove] that produced them, which is what keeps
/// the cross-board piece flow from drifting between playing a game and
/// replaying it. Stops at the first move that will not play, so a record from
/// a different starting position degrades to as much of itself as fits.
BughouseHistory replayBughouseGame(BughouseState start, List<String> moves) {
  final line = BughouseHistory(start);
  for (final prefixed in moves) {
    if (prefixed.length < 2) break;
    final which = prefixed[0] == '2' ? BughouseBoard.b : BughouseBoard.a;
    final before = line.current;
    final board = before.board(which);
    final move = parseEngineUci(board, prefixed.substring(1));
    if (move == null || !board.isLegal(move)) break;
    final after = before.playMove(which, move);
    if (after == null) break;
    line.push(
      BughousePly(
        board: which,
        move: move,
        san: board.makeSan(move).$2,
        before: before,
        after: after,
      ),
    );
  }
  line.toStart();
  return line;
}
