import 'dart:async';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/playing_engine.dart';
import 'package:chess_auto_prep/features/tournaments/game_runner.dart';
import 'package:flutter_test/flutter_test.dart';

TournamentConfig config({
  Map<String, Object?> extra = const {},
  Map<String, Object?> rules = const {},
}) => TournamentConfig({
  'name': 'Test match',
  'engines': [
    TournamentEngine.bundled('A').json,
    TournamentEngine.bundled('B').json,
  ],
  'gamesPerPairing': 2,
  'timeControl': {'kind': 'fixedDepth', 'depth': 1},
  'adjudication': {'drawEnabled': false, 'resignEnabled': false, ...rules},
  ...extra,
});

/// Plays [moves] in turn, each with [score] from its own side (no score
/// line at all when null), after [delay]; throws from `play` when [fails].
final class ScriptEngine implements PlayingEngine {
  ScriptEngine(
    this.moves, {
    this.score = 0,
    this.delay = Duration.zero,
    this.fails = false,
  });
  final List<String?> moves;
  final int? score;
  final Duration delay;
  final bool fails;
  final requests = <List<String>>[];
  final budgets = <MoveBudget>[];
  bool quitCalled = false;
  final _exit = Completer<EngineExit>();
  @override
  String get name => 'Scripted';
  @override
  Future<EngineExit> get exited => _exit.future;
  @override
  Future<void> quit() async {
    quitCalled = true;
    if (!_exit.isCompleted) _exit.complete(EngineExit.ended);
  }

  @override
  Search analyse(Fen fen, {required int multiPv, int? depth}) =>
      throw UnimplementedError();
  @override
  PlayingSearch play(Fen root, List<String> history, MoveBudget budget) {
    requests.add(history);
    budgets.add(budget);
    if (fails) throw StateError('engine gone');
    final move = moves.isEmpty ? null : moves.removeAt(0);
    final score = this.score;
    return PlayingSearch(
      Search(
        lines: score == null
            ? const Stream.empty()
            : Stream.value(
                EngineLine(
                  depth: 1,
                  multiPv: 1,
                  score: Centipawns(score),
                  pv: const [],
                ),
              ),
        stop: () async {},
      ),
      delay == Duration.zero
          ? Future.value(move)
          : Future.delayed(delay, () => move),
    );
  }
}

Future<PlayedGame> game(
  TournamentConfig cfg,
  List<ScriptEngine> engines, {
  bool Function()? stopping,
  void Function(LiveGame position)? onPosition,
}) async {
  var next = 0;
  return TournamentGameRunner(
    config: cfg,
    pairing: cfg.schedule.first,
    launch: (_, _) async => Started(engines[next++]),
    stopping: stopping ?? () => false,
    onPosition: onPosition ?? (_) {},
  ).play();
}

/// Quiet pawn moves that neither repeat nor end the game: eight a side.
final whitePawns = [for (final f in 'abcdefgh'.split('')) '${f}2${f}3'];
final blackPawns = [for (final f in 'abcdefgh'.split('')) '${f}7${f}6'];

/// Knight moves that keep every count of reversible moves running.
final whiteKnights = ['g1f3', 'b1c3', 'f3d4', 'c3b5'];
final blackKnights = ['g8f6', 'b8c6', 'f6d5', 'c6b4'];

void main() {
  test(
    'mate is legal, history is sent, both seats quit, PGN matches record',
    () async {
      final white = ScriptEngine(['f2f3', 'g2g4']);
      final black = ScriptEngine(['e7e5', 'd8h4']);
      final result = await game(config(), [white, black]);
      expect(result.record.result, '0-1');
      expect(result.record.termination, 'checkmate');
      expect(result.pgn, contains('Qh4#'));
      expect(result.pgn, contains('[Result "0-1"]'));
      expect(black.requests.last, ['f2f3', 'e7e5', 'g2g4']);
      expect(white.quitCalled && black.quitCalled, isTrue);
    },
  );
  test('illegal bestmove forfeits; null bestmove is engine failure', () async {
    for (final move in ['e2e5', null]) {
      final result = await game(config(), [
        ScriptEngine([move]),
        ScriptEngine([]),
      ]);
      expect(result.record.result, '0-1');
      expect(
        result.record.termination,
        move == null ? 'engineFailure' : 'illegalMove',
      );
    }
  });
  test('a bestmove missing its promotion piece forfeits before play', () async {
    final black = ScriptEngine([]);
    final result = await game(
      config(extra: {'startFen': '7k/P7/8/8/8/8/8/K7 w - - 0 1'}),
      [
        ScriptEngine(['a7a8']),
        black,
      ],
    );
    expect(result.record.termination, 'illegalMove');
    expect(result.record.result, '0-1');
    expect(black.requests, isEmpty);
  });
  test('threefold ends before a ninth engine request', () async {
    final result = await game(config(), [
      ScriptEngine(['g1f3', 'f3g1', 'g1f3', 'f3g1']),
      ScriptEngine(['g8f6', 'f6g8', 'g8f6', 'f6g8']),
    ]);
    expect(result.record.termination, 'threefoldRepetition');
    expect(result.record.result, '1/2-1/2');
  });
  test('maximum moves and custom FEN are represented in PGN', () async {
    final result = await game(config(rules: {'maxMoves': 1}), [
      ScriptEngine(['e2e4']),
      ScriptEngine(['e7e5']),
    ]);
    expect(result.record.termination, 'maxMoves');
    final end = await game(
      config(extra: {'startFen': '8/8/8/8/8/8/4k3/6K1 w - - 0 1'}),
      [ScriptEngine([]), ScriptEngine([])],
    );
    expect(end.record.termination, 'insufficientMaterial');
    expect(end.pgn, contains('[SetUp "1"]'));
  });
  test(
    'failed second launch quits the first engine and awards forfeit',
    () async {
      final first = ScriptEngine([]);
      var n = 0;
      final cfg = config();
      final result = await TournamentGameRunner(
        config: cfg,
        pairing: cfg.schedule.first,
        launch: (_, _) async =>
            n++ == 0 ? Started(first) : const StartFailed('missing binary'),
        stopping: () => false,
        onPosition: (_) {},
      ).play();
      expect(first.quitCalled, isTrue);
      expect(result.record.result, '1-0');
      expect(result.record.detail, 'missing binary');
    },
  );
  test('stop before start is unfinished and earns no points', () async {
    final result = await game(config(), [], stopping: () => true);
    expect(result.record.result, '*');
    final tournament = Tournament({
      'config': config().json,
      'games': [result.record.json],
    });
    expect(tournament.scores.map((s) => s.points), [0, 0]);
  });
  test('TimeControl writes whole seconds without a decimal', () async {
    Future<String> tag(Map<String, Object?> time) async {
      final result = await game(config(extra: {'timeControl': time}), [
        ScriptEngine([]),
        ScriptEngine([]),
      ], stopping: () => true);
      return RegExp(r'\[TimeControl "([^"]*)"\]').firstMatch(result.pgn)![1]!;
    }

    expect(await tag({'kind': 'movetime', 'movetimeMs': 2000}), '*2');
    expect(await tag({'kind': 'movetime', 'movetimeMs': 1500}), '*1.5');
    expect(
      await tag({'kind': 'incremental', 'baseMs': 60000, 'incrementMs': 600}),
      '60+0.6',
    );
    expect(
      await tag({
        'kind': 'incremental',
        'baseMs': 600000,
        'incrementMs': 10000,
        'movesPerSession': 40,
      }),
      '40/600+10',
    );
    expect(
      await tag({
        'kind': 'incremental',
        'baseMs': 60000,
        'incrementMs': 0,
        'movesPerSession': 0,
      }),
      '60+0',
    );
    expect(await tag({'kind': 'fixedDepth', 'depth': 3}), '?');
  });
  group('resignation adjudication', () {
    Future<PlayedGame> resign(
      Map<String, Object?> rules, {
      required int white,
      required int black,
    }) => game(config(rules: {'resignEnabled': true, ...rules}), [
      ScriptEngine([...whitePawns], score: white),
      ScriptEngine([...blackPawns], score: black),
    ]);

    test('with both engines agreeing, White resigns on its fourth losing '
        'move after Black first agrees', () async {
      final result = await resign({}, white: -1000, black: 1000);
      expect(result.record.result, '0-1');
      expect(result.record.termination, 'resignAdjudication');
      // White's first losing move has no agreement yet: moves 2 to 5 count.
      expect(result.record.json['plies'], 9);
    });

    test('a losing engine whose opponent does not agree plays on unless one '
        'side may resign alone', () async {
      final both = await resign({'maxMoves': 8}, white: -1000, black: 0);
      expect(both.record.termination, 'maxMoves');
      final alone = await resign(
        {'twoSidedResign': false},
        white: -1000,
        black: 0,
      );
      expect(alone.record.result, '0-1');
      expect(alone.record.termination, 'resignAdjudication');
      expect(alone.record.json['plies'], 7);
    });

    test('Black resigns at the threshold itself after the moves set', () async {
      final result = await resign(
        {'twoSidedResign': false, 'resignMoveCount': 2},
        white: 0,
        black: -900,
      );
      expect(result.record.result, '1-0');
      expect(result.record.termination, 'resignAdjudication');
      expect(result.record.json['plies'], 4);
    });

    test('nothing resigns with resignation off or without scores', () async {
      final off = await resign(
        {'resignEnabled': false, 'twoSidedResign': false, 'maxMoves': 4},
        white: -1000,
        black: -1000,
      );
      expect(off.record.termination, 'maxMoves');
      final unscored = await game(
        config(
          rules: {
            'twoSidedResign': false,
            'resignEnabled': true,
            'drawEnabled': true,
            'drawMoveNumber': 1,
            'drawMoveCount': 1,
            'maxMoves': 2,
          },
        ),
        [
          ScriptEngine([...whitePawns], score: null),
          ScriptEngine([...blackPawns], score: null),
        ],
      );
      expect(unscored.record.termination, 'maxMoves');
      expect(unscored.record.json['plies'], 4);
    });

    test('the move cap reached on the resigning move ends it drawn', () async {
      final result = await resign(
        {'twoSidedResign': false, 'resignMoveCount': 2, 'maxMoves': 2},
        white: 0,
        black: -1000,
      );
      expect(result.record.result, '1/2-1/2');
      expect(result.record.termination, 'maxMoves');
    });
  });

  group('draw adjudication', () {
    Future<PlayedGame> level(
      Map<String, Object?> rules, {
      int score = 0,
      List<String>? black,
    }) => game(
      config(
        rules: {
          'drawEnabled': true,
          'drawScoreCp': 10,
          'maxMoves': 4,
          ...rules,
        },
      ),
      [
        ScriptEngine([...whiteKnights], score: score),
        ScriptEngine([...(black ?? blackKnights)], score: score),
      ],
    );

    test('level scores from the move set, for the moves set, draw', () async {
      final result = await level({'drawMoveNumber': 3, 'drawMoveCount': 2});
      expect(result.record.result, '1/2-1/2');
      expect(result.record.termination, 'drawAdjudication');
      // Black's second move reaches move 3; its third is the second level.
      expect(result.record.json['plies'], 6);
    });

    test('scores past the threshold, or draws off, play on', () async {
      final wide = await level({
        'drawMoveNumber': 1,
        'drawMoveCount': 1,
      }, score: 50);
      expect(wide.record.termination, 'maxMoves');
      final off = await level({
        'drawEnabled': false,
        'drawMoveNumber': 1,
        'drawMoveCount': 1,
      });
      expect(off.record.termination, 'maxMoves');
    });

    test('a pawn move starts the count of level moves again', () async {
      final result = await level(
        {'drawMoveNumber': 1, 'drawMoveCount': 2},
        black: ['g8f6', 'e7e6', 'b8c6'],
      );
      expect(result.record.termination, 'drawAdjudication');
      expect(result.record.json['plies'], 6);
    });
  });

  group('clocks', () {
    test('incremental clocks add the increment each move and the base '
        'again each period, and tell the engine the moves to go', () async {
      final white = ScriptEngine([...whitePawns]);
      final result = await game(
        config(
          extra: {
            'timeControl': {
              'kind': 'incremental',
              'baseMs': 60000,
              'incrementMs': 1000,
              'movesPerSession': 2,
            },
          },
          rules: {'maxMoves': 3},
        ),
        [
          white,
          ScriptEngine([...blackPawns]),
        ],
      );
      expect(result.record.termination, 'maxMoves');
      expect(white.budgets.map((b) => b.movesToGo), [2, 1, 2]);
      expect(white.budgets.map((b) => b.increment), [1000, 1000, 1000]);
      final clocks = white.budgets.map((b) => b.whiteTime!).toList();
      expect(clocks.first, 60000);
      expect(clocks[1], inInclusiveRange(59000, 61000));
      expect(clocks[2], inInclusiveRange(120000, 122000));
      expect(white.budgets.last.blackTime, inInclusiveRange(120000, 122000));
    });

    test('a period of one move gives the base back after every move', () async {
      final white = ScriptEngine([...whitePawns]);
      await game(
        config(
          extra: {
            'timeControl': {
              'kind': 'incremental',
              'baseMs': 60000,
              'incrementMs': 0,
              'movesPerSession': 1,
            },
          },
          rules: {'maxMoves': 2},
        ),
        [
          white,
          ScriptEngine([...blackPawns]),
        ],
      );
      expect(white.budgets.map((b) => b.movesToGo), [1, 1]);
      expect(white.budgets.last.whiteTime, inInclusiveRange(118000, 120000));
    });

    test('sudden death sends no moves to go', () async {
      final white = ScriptEngine([...whitePawns]);
      final result = await game(
        config(
          extra: {
            'timeControl': {
              'kind': 'incremental',
              'baseMs': 60000,
              'incrementMs': 0,
              'movesPerSession': 0,
            },
          },
          rules: {'maxMoves': 2},
        ),
        [
          white,
          ScriptEngine([...blackPawns]),
        ],
      );
      expect(result.record.termination, 'maxMoves');
      expect(white.budgets.map((b) => b.movesToGo), [null, null]);
    });

    test('a move slower than the clock loses on time', () async {
      final result = await game(
        config(
          extra: {
            'timeControl': {
              'kind': 'incremental',
              'baseMs': 30,
              'incrementMs': 0,
            },
          },
        ),
        [
          ScriptEngine([
            ...whitePawns,
          ], delay: const Duration(milliseconds: 120)),
          ScriptEngine([...blackPawns]),
        ],
      );
      expect(result.record.result, '0-1');
      expect(result.record.termination, 'timeForfeit');
      expect(result.record.detail, 'The clock expired.');
      expect(result.record.json['plies'], 0);
    });

    test('time per move and fixed nodes are sent as set', () async {
      Future<MoveBudget> first(Map<String, Object?> time) async {
        final white = ScriptEngine([]);
        await game(config(extra: {'timeControl': time}), [
          white,
          ScriptEngine([]),
        ]);
        return white.budgets.single;
      }

      expect(
        (await first({'kind': 'movetime', 'movetimeMs': 1500})).milliseconds,
        1500,
      );
      expect((await first({'kind': 'fixedNodes', 'nodes': 5000})).nodes, 5000);
      expect((await first({'kind': 'fixedDepth', 'depth': 7})).depth, 7);
    });
  });

  test('an engine that fails while thinking loses the game', () async {
    for (final whiteFails in [true, false]) {
      final result = await game(config(), [
        ScriptEngine([...whitePawns], fails: whiteFails),
        ScriptEngine([...blackPawns], fails: !whiteFails),
      ]);
      expect(result.record.result, whiteFails ? '0-1' : '1-0');
      expect(result.record.termination, 'engineFailure');
      expect(result.record.detail, contains('engine gone'));
    }
  });

  test('each move is reported live, and the PGN is dated and can carry '
      'the evaluations', () async {
    final seen = <LiveGame>[];
    final result = await game(
      config(extra: {'annotateMoves': true}, rules: {'maxMoves': 1}),
      [
        ScriptEngine(['e2e4'], score: 35),
        ScriptEngine(['e7e5'], score: 20),
      ],
      onPosition: seen.add,
    );
    expect(seen.map((p) => (p.move, p.plies)), [('e4', 1), ('e5', 2)]);
    expect(seen.last.fen.position, startsWith('rnbqkbnr/pppp1ppp/8/4p3'));
    expect(result.pgn, matches(RegExp(r'\[Date "\d{4}\.\d\d\.\d\d"\]')));
    // Each comment is from White's side: Black's +0.20 is -0.20.
    expect(result.pgn, contains('+0.35/1 '));
    expect(result.pgn, contains('-0.20/1 '));
  });

  test('round robin and gauntlet alternate seats deterministically', () {
    final cfg = config(
      extra: {
        'engines': [
          for (final n in ['A', 'B', 'C']) TournamentEngine.bundled(n).json,
        ],
      },
    );
    expect(cfg.schedule.length, 6);
    expect(cfg.schedule[3].white, 1);
    expect(cfg.schedule[3].black, 0);
    final gauntlet = TournamentConfig({...cfg.json, 'format': 'gauntlet'});
    expect(gauntlet.schedule.length, 4);
    expect(
      gauntlet.schedule.every((p) => p.white == 0 || p.black == 0),
      isTrue,
    );
  });
}
