import 'dart:async';

import 'package:dartchess/dartchess.dart' show Position;

import '../chess/fen.dart';
import '../chess/generation/legal_moves.dart';
import '../chess/pgn/tree_edit.dart';
import 'engine.dart';
import 'engine_line.dart';
import 'engine_supervisor.dart';

sealed class SolitaireVerdict {
  const SolitaireVerdict();
}

/// Both scores are from the guessing side, regardless of board orientation.
final class SolitaireScored extends SolitaireVerdict {
  const SolitaireScored({
    required this.accepted,
    required this.better,
    required this.gameScore,
    required this.guessScore,
  });

  final bool accepted;
  final bool better;
  final Score gameScore;
  final Score guessScore;
}

final class SolitaireUnavailable extends SolitaireVerdict {
  const SolitaireUnavailable(this.reason);
  final String reason;
}

/// A private supervised engine for one solitaire session. Searches are serial;
/// a new position replaces the cache and invalidates any older comparison.
/// Call [cancel] when the session ends, including while launch is pending.
final class SolitaireEvaluator {
  SolitaireEvaluator(
    this.launch, {
    this.depth = 14,
    this.multiPv = 5,
    this.toleranceCp = 50,
    this.patience = const Duration(seconds: 30),
    this.closingPatience = const Duration(seconds: 2),
  }) : assert(depth >= 2),
       assert(multiPv > 0),
       assert(toleranceCp >= 0);

  final Future<EngineStart> Function() launch;
  final int depth;
  final int multiPv;
  final int toleranceCp;
  final Duration patience;
  final Duration closingPatience;
  final _closed = Completer<void>();
  Future<void> _tail = Future.value();
  Future<Engine>? _starting;
  Engine? _engine;
  int _generation = 0;
  _PositionScores? _current;

  /// Warms the top-five ranking and the game move, without exposing spoilers.
  /// False means no reliable verdict is available; no score is invented.
  Future<bool> prepare(Fen fen, String gameUci) async {
    _PositionScores? current;
    try {
      current = _position(fen, gameUci);
      await current.ready;
      _check(current);
      return true;
    } on Object {
      await _failed(current);
      return false;
    }
  }

  Future<SolitaireVerdict> compare(
    Fen fen,
    String gameUci,
    String guessUci,
  ) async {
    _PositionScores? current;
    try {
      current = _position(fen, gameUci);
      await current.ready;
      final position = current;
      return await _serial(() async {
        _check(position);
        final game = await _score(position, gameUci);
        final guess = await _score(position, guessUci);
        _check(position);
        final order = _compareScores(guess, game);
        final accepted = switch ((guess, game)) {
          (Centipawns(value: final a), Centipawns(value: final b)) =>
            a >= b - toleranceCp,
          _ => order >= 0,
        };
        return SolitaireScored(
          accepted: accepted,
          better: order > 0,
          gameScore: game,
          guessScore: guess,
        );
      });
    } on Object {
      await _failed(current);
      return const SolitaireUnavailable(
        'The engine could not finish this check. Try again or show the game move.',
      );
    }
  }

  _PositionScores _position(Fen fen, String gameUci) {
    if (_closed.isCompleted) throw const EngineFailure('Session ended');
    final existing = _current;
    if (existing != null && existing.fen == fen && existing.game == gameUci) {
      return existing;
    }
    final position = positionOf(fen);
    if (position == null) throw const EngineFailure('Invalid position');
    final current = _PositionScores(fen, gameUci, position);
    _current = current;
    current.ready = _serial(() async {
      _check(current);
      final engine = await (_starting ??= _start());
      _check(current);
      final lines = await _lines(engine, fen, count: multiPv, atDepth: depth);
      _check(current);
      final count = current.moves.length < multiPv
          ? current.moves.length
          : multiPv;
      for (var rank = 1; rank <= count; rank++) {
        final line = lines[rank];
        if (line == null || line.pv.isEmpty || !_settled(line, depth)) {
          throw const EngineFailure('Incomplete ranking');
        }
        current.scores[current.key(line.pv.first)] = line.score;
      }
      if (current.scores.length != count) {
        throw const EngineFailure('Incomplete ranking');
      }
      await _score(current, gameUci);
    });
    return current;
  }

  Future<Score> _score(_PositionScores current, String uci) async {
    _check(current);
    final key = current.key(uci);
    if (current.scores[key] case final score?) return score;
    final move = current.moves.firstWhere((move) => move.uci == key).move;
    final child = current.position.play(move);
    final Score score;
    if (child.isCheckmate) {
      score = const MateIn(1);
    } else if (child.isGameOver) {
      score = const Centipawns(0);
    } else {
      final lines = await _lines(
        _engine!,
        Fen(child.fen),
        count: 1,
        atDepth: depth - 1,
      );
      _check(current);
      final line = lines[1];
      if (line == null || line.pv.isEmpty || !_settled(line, depth - 1)) {
        throw const EngineFailure('Incomplete move evaluation');
      }
      // Mate distances count moves by the mating side. If we mate from the
      // child, include the root move; an opponent's mate needs no added move.
      score = switch (line.score) {
        Centipawns(:final value) => Centipawns(-value),
        MateIn(:final moves, :final mating) =>
          mating ? MateIn(-moves.abs()) : MateIn(moves.abs() + 1),
      };
    }
    _check(current);
    return current.scores[key] = score;
  }

  Future<Map<int, EngineLine>> _lines(
    Engine engine,
    Fen fen, {
    required int count,
    required int atDepth,
  }) async {
    final lines = <int, EngineLine>{};
    final search = engine.analyse(fen, multiPv: count, depth: atDepth);
    await for (final line in search.lines) {
      lines[line.multiPv] = line;
    }
    return lines;
  }

  Future<Engine> _start() async {
    final generation = _generation;
    final started = await launch();
    if (started case StartFailed(:final reason)) throw EngineFailure(reason);
    final engine = (started as Started).engine;
    if (_closed.isCompleted || generation != _generation) {
      await _quit(engine);
      throw const EngineFailure('Session ended');
    }
    return _engine = engine;
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) async {
      if (_closed.isCompleted) throw const EngineFailure('Session ended');
      try {
        return await Future.any([
          work(),
          _closed.future.then<T>(
            (_) => throw const EngineFailure('Session ended'),
          ),
        ]).timeout(patience);
      } on TimeoutException {
        await _restart();
        rethrow;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _failed(_PositionScores? current) async {
    if (current == null || !identical(current, _current)) return;
    _current = null;
    await _restart();
  }

  Future<void> _restart() async {
    _generation++;
    _starting = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) await _quit(engine);
  }

  void _check(_PositionScores current) {
    if (_closed.isCompleted || !identical(current, _current)) {
      throw const EngineFailure('Position changed');
    }
  }

  /// Bounded even if launch, search, or quit does not answer. A late launch
  /// still quits through its supervisor; it cannot start a stale search.
  Future<void> cancel() async {
    if (!_closed.isCompleted) _closed.complete();
    _current = null;
    await _restart();
  }

  Future<void> _quit(Engine engine) async {
    try {
      await engine.quit().timeout(closingPatience);
    } on Object {
      // The supervisor remains the owner of any process still shutting down.
    }
  }
}

bool _settled(EngineLine line, int depth) =>
    line.depth >= depth || line.score is MateIn;

int _compareScores(Score guess, Score game) {
  final guessKind = guess is MateIn ? (guess.mating ? 1 : -1) : 0;
  final gameKind = game is MateIn ? (game.mating ? 1 : -1) : 0;
  if (guessKind != gameKind) return guessKind.compareTo(gameKind);
  if (guess is Centipawns && game is Centipawns) {
    return guess.value.compareTo(game.value);
  }
  final a = guess as MateIn;
  final b = game as MateIn;
  return a.mating
      ? b.moves.abs().compareTo(a.moves.abs())
      : a.moves.abs().compareTo(b.moves.abs());
}

final class _PositionScores {
  _PositionScores(this.fen, this.game, this.position)
    : moves = legalMovesOf(position);
  final Fen fen;
  final String game;
  final Position position;
  final List<NamedMove> moves;
  final scores = <String, Score>{};
  late final Future<void> ready;

  String key(String uci) =>
      moves.firstWhere((move) => move.uci == uci || move.move.uci == uci).uci;
}
