import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `match.json` as the old app writes it (its `StoredBughouseTournament.
/// toJson`): a movetime budget, the `ahead` stance, two games.
Map<String, Object?> oldMatch() =>
    jsonDecode(
          File('test/fixtures/v2_bughouse/old_match.json').readAsStringSync(),
        )
        as Map<String, Object?>;

void main() {
  test('an old match reads and writes back the same', () {
    final json = oldMatch();
    final match = StoredMatch.fromJson(json);
    expect(match.config.clock, ClockCase.abMaySit);
    expect(match.config.teams[1].budget, (nodes: null, movetimeMs: 1000));
    expect(match.games.first.ending, MatchEnding.checkmate);
    expect(match.games.last.result, MatchResult.draw);
    expect(match.toJson(), json);
  });

  test('a run the old app left running reads as stopped', () {
    final json = oldMatch()..['status'] = 'running';
    expect(StoredMatch.fromJson(json).status, MatchStatus.cancelled);
  });

  test('BPGN: four seats, the set-up start, moves in the order played', () {
    final match = StoredMatch.fromJson(oldMatch());
    final bpgn = gameBpgn(match.config, match.games.first);
    expect(bpgn, contains('[WhiteA "Hivemind A"]'));
    expect(bpgn, contains('[BlackA "Hivemind B"]'));
    expect(bpgn, contains('[WhiteB "Hivemind B"]'));
    expect(bpgn, contains('[BlackB "Hivemind A"]'));
    expect(bpgn, contains('[Result "1-0"]'));
    expect(bpgn, contains('[Termination "normal"]'));
    expect(bpgn, contains('[Opening "1. e4 d5"]'));
    expect(bpgn, contains('[SetUpDualFEN "${match.config.startDualFen}"]'));
    expect(bpgn, contains('2A. exd5 1B. d4 2a. Qxd5\n1-0\n'));
    expect(matchBpgn(match).split('[Event ').length, 3);
  });

  test('the line’s score counts White on board 1 and leaves out the rest', () {
    final match = StoredMatch.fromJson(oldMatch());
    final score = match.openingScore;
    expect(score.text, '1½/2');
    expect((score.wins, score.draws, score.adjudicated), (1, 1, 1));
    expect(score.margin, greaterThan(0));
  });

  test('a game replays onto the boards as far as it plays', () {
    final start = StoredMatch.fromJson(oldMatch()).config.start!;
    final line = replayGame(start, ['1e4d5', '2d2d4', '1a1a8', '1d8d5']);
    expect(line.moves.map((m) => m.san), ['exd5', 'd4']);
    expect(line.upto(BoardNumber.one), 1);
  });

  test('seats swap every other game unless the match says not to', () {
    const config = MatchConfig(name: 'x', startDualFen: '', seed: 1);
    expect(
      [for (var i = 0; i < 3; i++) config.seatsFor(i)],
      [(0, 1), (1, 0), (0, 1)],
    );
    const fixed = MatchConfig(
      name: 'x',
      startDualFen: '',
      seed: 1,
      alternateSeats: false,
    );
    expect(fixed.seatsFor(1), (0, 1));
  });

  test('a loss is scored for the pair holding White on board 1', () {
    expect(lossFor(Team.ab), MatchResult.blackWins);
    expect(lossFor(Team.cd), MatchResult.whiteWins);
  });
}
