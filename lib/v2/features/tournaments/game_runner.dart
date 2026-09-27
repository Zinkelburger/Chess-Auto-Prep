import 'dart:async';

import 'package:dartchess/dartchess.dart';

import '../../chess/fen.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/game_tree.dart';
import '../../chess/pgn/move_text.dart';
import '../../chess/tournament/config.dart';
import '../../chess/tournament/result.dart';
import '../../diagnostics/log.dart';
import '../../engines/engine_supervisor.dart';
import '../../engines/engine_line.dart';
import '../../engines/playing_engine.dart';

typedef TournamentLauncher =
    Future<EngineStart> Function(TournamentEngine engine);
typedef PlayedGame = ({TournamentGame record, String pgn});
typedef LiveGame = ({Fen fen, String move, int plies, Pairing pairing});

/// One game's resources and clocks. The supervisor owns its processes; this
/// runner always quits its two seats, including a half-completed startup.
final class TournamentGameRunner {
  TournamentGameRunner({
    required this.config,
    required this.pairing,
    required this.launch,
    required this.stopping,
    required this.onPosition,
  }) : _position = Chess.fromSetup(Setup.parseFen(config.root.value)),
       _clocks = List.filled(2, config.timeNumber('baseMs', 60000));
  final TournamentConfig config;
  final Pairing pairing;
  final TournamentLauncher launch;
  final bool Function() stopping;
  final void Function(LiveGame) onPosition;
  Position _position;
  final List<int> _clocks;
  final _nodes = <MoveNode>[];
  final _engines = <PlayingEngine>[];
  final _positions = <String, int>{};
  final List<int?> _scores = [null, null];
  final _losing = [0, 0];
  final _playedBySide = [0, 0];
  int _level = 0;
  String _result = '*';
  String _reason = 'aborted';
  String _detail = '';

  Future<PlayedGame> play() async {
    final started = DateTime.now().toUtc();
    final watch = Stopwatch()..start();
    _positions[Fen(_position.fen).position] = 1;
    try {
      if (await _start()) await _moves();
    } on Object catch (error) {
      log.w('play tournament game ${pairing.index + 1}', error);
      _lose(_position.turn == Side.white ? 0 : 1, 'engineFailure', '$error');
    } finally {
      await Future.wait([for (final engine in _engines) _quit(engine)]);
    }
    return _finished(started, watch.elapsedMilliseconds);
  }

  Future<bool> _start() async {
    for (final seat in [pairing.white, pairing.black]) {
      if (stopping()) return false;
      final result = await launch(config.engines[seat]);
      switch (result) {
        case Started(:final engine):
          if (engine is! PlayingEngine) {
            await engine.quit();
            _lose(
              _engines.length,
              'engineFailure',
              'Engine cannot play finite moves.',
            );
            return false;
          }
          _engines.add(engine);
        case StartFailed(:final reason):
          _lose(_engines.length, 'engineFailure', reason);
          return false;
      }
    }
    return true;
  }

  Future<void> _moves() async {
    while (!stopping()) {
      if (_ended()) return;
      final side = _position.turn == Side.white ? 0 : 1;
      final clock = Stopwatch()..start();
      final search = _engines[side].play(config.root, [
        for (final node in _nodes) node.uci,
      ], _budget(side));
      EngineLine? score;
      final lines = search.analysis.lines.forEach((line) {
        if (line.multiPv == 1) score = line;
      });
      final answers = await Future.wait<Object?>([search.bestMove, lines]);
      final move = answers.first as String?;
      if (stopping()) return;
      if (!_spend(side, clock.elapsedMilliseconds)) return;
      final parsed = move == null ? null : Move.parse(move);
      if (parsed == null || !_position.isLegal(parsed)) {
        _lose(
          side,
          move == null ? 'engineFailure' : 'illegalMove',
          'No legal best move was returned.',
        );
        return;
      }
      _played(parsed, score, clock.elapsedMilliseconds);
      if (_adjudicated(side)) return;
    }
  }

  MoveBudget _budget(int side) {
    final period = config.timeNumber('movesPerSession', 0);
    return switch (config.kind) {
      'fixedDepth' => MoveBudget(depth: config.timeNumber('depth', 12)),
      'fixedNodes' => MoveBudget(nodes: config.timeNumber('nodes', 1000000)),
      'incremental' => MoveBudget(
        whiteTime: _clocks[0],
        blackTime: _clocks[1],
        increment: config.timeNumber('incrementMs', 600),
        movesToGo: period > 0 ? period - _playedBySide[side] % period : null,
        deadline: Duration(
          milliseconds: (_clocks[side] + 5000).clamp(5000, 3600000),
        ),
      ),
      _ => MoveBudget(
        milliseconds: config.timeNumber('movetimeMs', 2000),
        deadline: Duration(
          milliseconds:
              (config.timeNumber('movetimeMs', 2000) * 1.75).round() + 2000,
        ),
      ),
    };
  }

  bool _spend(int side, int milliseconds) {
    if (config.kind != 'incremental') return true;
    _clocks[side] -= milliseconds;
    if (_clocks[side] <= 0) {
      _lose(side, 'timeForfeit', 'The clock expired.');
      return false;
    }
    _clocks[side] += config.timeNumber('incrementMs', 600);
    final period = config.timeNumber('movesPerSession', 0);
    if (period > 0 && (_playedBySide[side] + 1) % period == 0)
      _clocks[side] += config.timeNumber('baseMs', 60000);
    return true;
  }

  void _played(Move move, EngineLine? info, int milliseconds) {
    final side = _position.turn == Side.white ? 0 : 1;
    _playedBySide[side]++;
    _scores[side] = null;
    if (info != null) {
      final score = info.score.forWhite(whiteToMove: side == 0);
      _scores[side] = switch (score) {
        Centipawns(:final value) => value,
        MateIn(:final mating) => mating ? 32000 : -32000,
      };
    }
    final (next, san) = _position.makeSan(move);
    _position = next;
    _nodes.add(
      MoveNode(
        san: san,
        uci: move.uci,
        fen: Fen(next.fen),
        comment: config.annotate && info != null
            ? '${info.score.forWhite(whiteToMove: side == 0).text}/${info.depth} ${(milliseconds / 1000).toStringAsFixed(3)}s'
            : null,
      ),
    );
    final key = Fen(next.fen).position;
    _positions[key] = (_positions[key] ?? 0) + 1;
    onPosition((
      fen: Fen(next.fen),
      move: san,
      plies: _nodes.length,
      pairing: pairing,
    ));
  }

  bool _ended() {
    if (_position.isCheckmate) {
      _lose(_position.turn == Side.white ? 0 : 1, 'checkmate', '');
      return true;
    }
    final rules = config.adjudication;
    final reason = _position.isStalemate
        ? 'stalemate'
        : _position.isInsufficientMaterial
        ? 'insufficientMaterial'
        : rules['fiftyMoveRule'] != false && _position.halfmoves >= 100
        ? 'fiftyMoveRule'
        : rules['threefoldRepetition'] != false &&
              (_positions[Fen(_position.fen).position] ?? 0) >= 3
        ? 'threefoldRepetition'
        : _nodes.length >= config.maxMoves * 2
        ? 'maxMoves'
        : null;
    if (reason == null) return false;
    _result = '1/2-1/2';
    _reason = reason;
    return true;
  }

  bool _adjudicated(int side) {
    // Natural endings take precedence over an evaluation or the move cap.
    if (_ended()) return true;
    final rules = config.adjudication;
    final score = _scores[side];
    final other = _scores[1 - side];
    if (score == null) return false;
    final cp = tournamentInt(rules, 'resignScoreCp', 900);
    final losing = side == 0 ? score <= -cp : score >= cp;
    final agreed = other != null && (side == 0 ? other <= -cp : other >= cp);
    _losing[side] = losing && (rules['twoSidedResign'] == false || agreed)
        ? _losing[side] + 1
        : 0;
    if (rules['resignEnabled'] != false &&
        _losing[side] >= tournamentInt(rules, 'resignMoveCount', 4)) {
      _lose(side, 'resignAdjudication', '');
      return true;
    }
    if (_position.halfmoves == 0) _level = 0;
    if (side == 0 || rules['drawEnabled'] == false) return false;
    final drawCp = tournamentInt(rules, 'drawScoreCp', 10);
    final level =
        other != null && score.abs() <= drawCp && other.abs() <= drawCp;
    _level =
        level &&
            _position.fullmoves >= tournamentInt(rules, 'drawMoveNumber', 40)
        ? _level + 1
        : 0;
    if (_level < tournamentInt(rules, 'drawMoveCount', 8)) return false;
    _result = '1/2-1/2';
    _reason = 'drawAdjudication';
    return true;
  }

  void _lose(int side, String reason, String detail) {
    _result = side == 0 ? '0-1' : '1-0';
    _reason = reason;
    _detail = detail;
  }

  PlayedGame _finished(DateTime started, int milliseconds) {
    final white = config.engines[pairing.white].name;
    final black = config.engines[pairing.black].name;
    final record = TournamentGame({
      'gameIndex': pairing.index,
      'round': pairing.round,
      'whiteIndex': pairing.white,
      'blackIndex': pairing.black,
      'whiteName': white,
      'blackName': black,
      'result': switch (_result) {
        '1-0' => 'whiteWins',
        '0-1' => 'blackWins',
        '1/2-1/2' => 'draw',
        _ => 'unfinished',
      },
      'termination': _reason,
      'detail': _detail,
      'plies': _nodes.length,
      'startedAt': started.toIso8601String(),
      'durationMs': milliseconds,
    });
    final headers = <String, String>{
      'Event': config.name,
      'Site': '${config.json['site'] ?? 'Chess Auto Prep'}',
      'Date': started.toIso8601String().substring(0, 10).replaceAll('-', '.'),
      'Round': '${pairing.round}',
      'White': white,
      'Black': black,
      'Result': _result,
      'Opening': '${config.json['openingLabel'] ?? ''}',
      'Termination': _reason,
      'PlyCount': '${_nodes.length}',
      'WhiteType': 'program',
      'BlackType': 'program',
      'GameStartTime': started.toIso8601String(),
      'GameDuration': '${milliseconds / 1000}',
      'TimeControl': _timeTag(),
      if (config.root != Fen.initial) ...{
        'FEN': config.root.value,
        'SetUp': '1',
      },
    };
    var children = <MoveNode>[];
    for (final node in _nodes.reversed)
      children = [node.copyWith(children: children)];
    final tree = GameTree(
      rootFen: config.root,
      children: children,
      rootComment: _reason,
    );
    final text = headers.entries
        .map((e) => PgnTag(e.key, e.value).text)
        .join('\n');
    return (
      record: record,
      pgn: '$text\n\n${writeMoveText(tree, terminator: _result)}\n',
    );
  }

  String _timeTag() => switch (config.kind) {
    'movetime' => '*${config.timeNumber('movetimeMs', 2000) / 1000}',
    'incremental' =>
      '${config.timeNumber('movesPerSession', 0) > 0 ? '${config.timeNumber('movesPerSession', 0)}/' : ''}'
          '${config.timeNumber('baseMs', 60000) / 1000}+${config.timeNumber('incrementMs', 600) / 1000}',
    _ => '?',
  };
}

Future<void> _quit(PlayingEngine engine) async {
  try {
    await engine.quit();
  } on Object catch (error) {
    log.w('quit tournament engine', error);
  }
}
