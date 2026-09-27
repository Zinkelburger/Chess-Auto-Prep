import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tournament/config.dart';
import 'package:chess_auto_prep/v2/chess/tournament/result.dart';
import 'package:chess_auto_prep/v2/engines/engine.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/engines/playing_engine.dart';
import 'package:chess_auto_prep/v2/features/tournaments/game_runner.dart';
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

final class ScriptEngine implements PlayingEngine {
  ScriptEngine(this.moves, {this.score = 0});
  final List<String?> moves;
  final int score;
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
    final move = moves.isEmpty ? null : moves.removeAt(0);
    return PlayingSearch(
      Search(
        lines: Stream.value(
          EngineLine(
            depth: 1,
            multiPv: 1,
            score: Centipawns(score),
            pv: const [],
          ),
        ),
        stop: () async {},
      ),
      Future.value(move),
    );
  }
}

Future<PlayedGame> game(
  TournamentConfig cfg,
  List<ScriptEngine> engines, {
  bool Function()? stopping,
}) async {
  var next = 0;
  return TournamentGameRunner(
    config: cfg,
    pairing: cfg.schedule.first,
    launch: (_) async => Started(engines[next++]),
    stopping: stopping ?? () => false,
    onPosition: (_) {},
  ).play();
}

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
        launch: (_) async =>
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
