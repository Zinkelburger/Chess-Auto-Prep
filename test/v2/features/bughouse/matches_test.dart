import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/matches.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late ScriptedBughouse outside;
  late TableSearch tables;
  late Matches matches;

  setUp(() {
    lab = BughouseLab();
    outside = ScriptedBughouse();
    tables = TableSearch(
      lab: lab,
      book: outside.book,
      startEngine: () => outside.outside.launch(cores: 2),
    );
    matches = Matches(
      store: outside.matches,
      startEngine: () => outside.outside.launch(cores: 2),
      lab: lab,
      tables: tables,
      now: () => DateTime(2026, 9, 23),
    );
  });

  tearDown(() {
    matches.dispose();
    tables.dispose();
    lab.dispose();
  });

  /// Two short games from the start: the scripted engine plays each team's
  /// first legal move, so a game runs to the move limit.
  MatchConfig twoGames() => MatchConfig(
    name: 'Start',
    startDualFen: TablePosition.initial.dualFen,
    seed: 0,
    games: 2,
    maxPlies: 12,
  );

  StoredMatch only() => outside.matches.saved.values.single;

  test('a match plays every game, each written as it ends', () async {
    await matches.start(twoGames());
    final match = only();
    expect(match.status, MatchStatus.completed);
    expect(match.games.map((g) => g.number), [1, 2]);
    expect(match.games.first.moves, hasLength(12));
    expect(match.games.first.ending, MatchEnding.maxMoves);
    // Seats swap: the second game has Hivemind B holding White on board 1.
    expect(match.games.last.whiteName, 'Hivemind B');
    expect(match.config.seed, isNot(0));
    expect(matches.running, isNull);
    expect(outside.engine.gone, isTrue);
  });

  test('stop drops the game in flight; resume plays it and the rest', () async {
    outside.engine.hold = true;
    final starting = matches.start(twoGames());
    await pumpEventQueue();
    expect(matches.running?.game, 1);
    matches.stop();
    await starting;
    expect(only().status, MatchStatus.cancelled);
    expect(only().games, isEmpty);
    expect(only().resumable, isTrue);
    await matches.resume(only().id);
    expect(only().status, MatchStatus.completed);
    expect(only().games, hasLength(2));
  });

  test('a match directory that cannot be made is said', () async {
    outside.matches.failCreate = 'Permission denied';
    await matches.start(twoGames());
    expect(
      matches.problem,
      'Could not create the match directory: Permission denied',
    );
    expect(outside.matches.saved, isEmpty);
  });

  test('an engine that will not start fails the match in words', () async {
    outside.startFailure = 'This build has no bughouse engine.';
    await matches.start(twoGames());
    expect(only().status, MatchStatus.failed);
    expect(only().error, 'This build has no bughouse engine.');
    expect(matches.problem, 'This build has no bughouse engine.');
  });

  test(
    'the boards follow the game being played, and the tables rest',
    () async {
      tables.open();
      await pumpEventQueue();
      outside.engine.hold = true;
      final starting = matches.start(twoGames());
      await pumpEventQueue();
      matches.follow();
      final asked = outside.engine.asked.length;
      outside.engine.hold = false;
      outside.engine.release();
      await starting;
      // The live games went by on the boards…
      expect(lab.line.moves, isNotEmpty);
      // …and the tables took the engine back once the match was over.
      expect(matches.following, isFalse);
      expect(outside.engine.asked.length, greaterThanOrEqualTo(asked));
    },
  );

  test('a finished game goes on the boards, at its end', () async {
    await matches.start(twoGames());
    matches.open(only().games.first);
    expect(lab.line.moves, hasLength(12));
    expect(matches.openGame, 1);
    matches.showOpening();
    expect(lab.line.moves, isEmpty);
  });

  test('delete takes a match out of the list', () async {
    await matches.start(twoGames());
    await matches.delete(only().id);
    expect(matches.matches, isEmpty);
    expect(outside.matches.deleted, hasLength(1));
  });
}
