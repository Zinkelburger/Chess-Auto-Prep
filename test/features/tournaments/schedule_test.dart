import 'dart:async';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/playing_engine.dart';
import 'package:chess_auto_prep/features/tournaments/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

import 'game_runner_test.dart' show ScriptEngine, config;

/// Plays 1.e4 e5 from either seat; its first move as White waits for [gate].
final class _SlowWhite implements PlayingEngine {
  _SlowWhite(this.name, this.gate);
  @override
  final String name;
  final Future<void> gate;
  final _exit = Completer<EngineExit>();
  @override
  Future<EngineExit> get exited => _exit.future;
  @override
  Future<void> quit() async {
    if (!_exit.isCompleted) _exit.complete(EngineExit.ended);
  }

  @override
  Search analyse(Fen fen, {required int multiPv, int? depth}) =>
      throw UnimplementedError();
  @override
  PlayingSearch play(Fen root, List<String> history, MoveBudget budget) {
    final search = ScriptEngine([
      history.isEmpty ? 'e2e4' : 'e7e5',
    ]).play(root, history, budget);
    return PlayingSearch(
      search.analysis,
      history.isEmpty ? gate.then((_) => search.bestMove) : search.bestMove,
    );
  }
}

void main() {
  test('without a holding check every pairing is played, and the games '
      'are kept in schedule order whatever order they finish in', () async {
    // A-B and B-A side by side: A's first move as White waits, so the
    // second game ends first.
    final gate = Completer<void>();
    final cfg = config(rules: {'maxMoves': 1}, extra: {'concurrency': 2});
    final schedule = TournamentSchedule(
      cfg,
      (engine, _) async => Started(
        _SlowWhite(
          engine.name,
          engine.name == 'A' ? gate.future : Future.value(),
        ),
      ),
    );
    final ended = <int>[];
    final work = schedule.play(
      stopping: () => false,
      afterGame: (pairing, _) async {
        ended.add(pairing.index);
        if (!gate.isCompleted) gate.complete();
      },
    );
    await work;

    expect(ended, [1, 0]);
    final (:records, :pgn) = schedule.finished;
    expect(records.map((game) => game['whiteName']), ['A', 'B']);
    expect(records.map((game) => game['gameIndex']), [0, 1]);
    expect(RegExp(r'\[White "(\w)"\]').allMatches(pgn).map((m) => m[1]), [
      'A',
      'B',
    ]);
  });

  test('a holding check starts no more games; those in flight play out', () {
    final cfg = config(rules: {'maxMoves': 1});
    final schedule = TournamentSchedule(
      cfg,
      (engine, _) async =>
          Started(ScriptEngine([engine.name == 'A' ? 'e2e4' : 'e7e5'])),
    );
    var held = false;
    return schedule
        .play(
          stopping: () => false,
          holding: () => held,
          afterGame: (_, _) async => held = true,
        )
        .then((_) {
          final records = schedule.finished.records;
          expect(records, hasLength(1));
          expect(records.single['result'], isNot('unfinished'));
        });
  });
}
