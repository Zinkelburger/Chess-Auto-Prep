import 'dart:math' as math;

import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/v2/features/bughouse/match_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

JointLine line(int rank, int cp, JointMove move) =>
    JointLine(rank: rank, cp: cp, nodes: 100, pv: [move]);

void main() {
  final config = MatchConfig(
    name: 'x',
    startDualFen: TablePosition.initial.dualFen,
    seed: 3,
    maxPlies: 30,
  );

  MatchRunner runner(ScriptedHivemind engine) =>
      MatchRunner(engine: engine, config: config, now: () => DateTime(2026));

  group('sampling', () {
    const best = JointMove('e2e4', null);
    const close = JointMove('d2d4', null);
    const far = JointMove('a2a3', null);
    final searched = HivemindSearched(
      best: best,
      lines: [line(1, -200, best), line(2, -205, close), line(3, -400, far)],
    );

    test('draws only from moves the engine ranked near the best', () {
      final random = math.Random(1);
      final picks = {
        for (var i = 0; i < 50; i++)
          pickFromShortlist(searched, defaultVariety, random),
      };
      expect(picks, {best, close});
    });

    test('a mate is played, not sampled around', () {
      final mating = HivemindSearched(
        best: best,
        lines: [
          const JointLine(rank: 1, mate: 2, nodes: 100, pv: [best]),
          line(2, -200, close),
        ],
      );
      expect(pickFromShortlist(mating, defaultVariety, math.Random(1)), best);
    });
  });

  test('a team with no legal joint action loses the game', () async {
    final engine = ScriptedHivemind()
      ..answer = (q) => q.team == Team.cd
          ? const HivemindSearched(best: null, lines: [])
          : firstMoves(q);
    final game = (await runner(engine).play(0, TablePosition.initial))!;
    expect(game.ending, MatchEnding.checkmate);
    expect(game.result, MatchResult.whiteWins);
    expect(game.detail, 'no legal joint action');
  });

  test('an answer that is not the team’s to play ends the game', () async {
    // A + B is asked first; the engine moves on board 2, which is D's.
    final engine = ScriptedHivemind()
      ..answer = (_) =>
          const HivemindSearched(best: JointMove(null, 'e2e4'), lines: []);
    final game = (await runner(engine).play(0, TablePosition.initial))!;
    expect(game.ending, MatchEnding.engineFailure);
    expect(game.detail, contains('Illegal engine action'));
    expect(game.moves, isEmpty);
  });

  test('four joint actions in a row that sit are a draw', () async {
    final engine = ScriptedHivemind()
      ..answer = (_) =>
          const HivemindSearched(best: JointMove(null, null), lines: []);
    final game = (await runner(engine).play(0, TablePosition.initial))!;
    expect(game.ending, MatchEnding.mutualSitting);
    expect(game.result, MatchResult.draw);
    expect(engine.asked, hasLength(4));
  });

  test('the ply limit is a draw, and the teams take turns', () async {
    final engine = ScriptedHivemind();
    final game = (await runner(engine).play(0, TablePosition.initial))!;
    expect(game.ending, MatchEnding.maxMoves);
    expect(game.moves.length, greaterThanOrEqualTo(30));
    expect(engine.asked.take(4).map((q) => q.team), [
      Team.ab,
      Team.cd,
      Team.ab,
      Team.cd,
    ]);
    // The first plies sample from a shortlist; later ones ask for one line.
    expect(engine.asked.first.lines, defaultVariety.lines);
    expect(engine.asked.last.lines, 1);
  });

  test('a stopped runner plays nothing more', () async {
    final engine = ScriptedHivemind()..hold = true;
    final play = runner(engine);
    final game = play.play(0, TablePosition.initial);
    await pumpEventQueue();
    play.stop();
    expect(await game, isNull);
    expect(await play.play(1, TablePosition.initial), isNull);
  });
}
