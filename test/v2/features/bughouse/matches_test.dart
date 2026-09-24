import 'dart:async';

import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/matches.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;

  /// The tables' engine and book, and the matches' own engine and store.
  late ScriptedBughouse forTables;
  late ScriptedBughouse forMatches;
  late TableSearch tables;
  late Matches matches;

  Matches matchesOver(Future<HivemindStart> Function() startEngine) => Matches(
    store: forMatches.matches,
    startEngine: startEngine,
    lab: lab,
    tables: tables,
    now: () => DateTime(2026, 9, 23),
  );

  setUp(() {
    lab = BughouseLab();
    forTables = ScriptedBughouse();
    forMatches = ScriptedBughouse();
    tables = TableSearch(
      lab: lab,
      book: forTables.book,
      startEngine: () => forTables.outside.launch(cores: 2),
    );
    matches = matchesOver(() => forMatches.outside.launch(cores: 2));
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

  StoredMatch only() => forMatches.matches.saved.values.single;

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
    expect(forMatches.engine.gone, isTrue);
  });

  test('a second start while the first is on its way does nothing', () async {
    final first = matches.start(twoGames());
    final second = matches.start(twoGames());
    await Future.wait([first, second]);
    expect(forMatches.matches.saved, hasLength(1));
  });

  test('stop drops the game in flight; resume plays it and the rest', () async {
    forMatches.engine.hold = true;
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

  test('stop while the engine is still starting stops the match', () async {
    final engine = Completer<HivemindStart>();
    matches.dispose();
    matches = matchesOver(() => engine.future);
    final starting = matches.start(twoGames());
    await pumpEventQueue();
    matches.stop();
    final started = ScriptedHivemind();
    engine.complete(HivemindStarted(started));
    await starting;
    expect(only().status, MatchStatus.cancelled);
    expect(started.asked, isEmpty);
    expect(started.gone, isTrue);
  });

  test('closing the app mid-match files it as stopped', () async {
    forMatches.engine.hold = true;
    final starting = matches.start(twoGames());
    await pumpEventQueue();
    matches.dispose();
    await starting;
    expect(only().status, MatchStatus.cancelled);
    matches = matchesOver(() => forMatches.outside.launch(cores: 2));
  });

  test('a game the engine failed is played again on resume', () async {
    forMatches.engine.answer = (_) => const HivemindFailed('it broke');
    await matches.start(twoGames());
    expect(only().status, MatchStatus.failed);
    expect(only().games.single.ending, MatchEnding.engineFailure);
    expect((matches.problem as MatchEngineFailed).reason, 'it broke');
    forMatches.engine.answer = firstMoves;
    await matches.resume(only().id);
    expect(only().status, MatchStatus.completed);
    expect(only().games.map((g) => g.ending), [
      MatchEnding.maxMoves,
      MatchEnding.maxMoves,
    ]);
  });

  test('a match directory that cannot be made is said', () async {
    forMatches.matches.failCreate = 'Permission denied';
    await matches.start(twoGames());
    expect((matches.problem as CannotCreate).detail, 'Permission denied');
    expect(forMatches.matches.saved, isEmpty);
  });

  test('an engine that will not start fails the match in words', () async {
    forMatches.startFailure = 'This build has no bughouse engine.';
    await matches.start(twoGames());
    expect(only().status, MatchStatus.failed);
    expect(only().error, 'This build has no bughouse engine.');
    expect(matches.problem, isA<EngineWouldNotStart>());
  });

  test(
    'the boards follow the game being played, and the tables rest',
    () async {
      tables.open();
      await pumpEventQueue();
      forMatches.engine.hold = true;
      final starting = matches.start(twoGames());
      await pumpEventQueue();
      matches.follow();
      final asked = forTables.engine.asked.length;
      forMatches.engine.hold = false;
      forMatches.engine.release();
      var followed = 0;
      lab.addListener(() => followed++);
      await starting;
      // The live games went by on the boards, and the tables asked nothing
      // about them…
      expect(followed, greaterThan(10));
      expect(lab.line.moves, isNotEmpty);
      expect(forTables.engine.asked.length, asked);
      // …until the match was over, when they took up the table on the boards.
      expect(matches.following, isFalse);
      await pumpEventQueue();
      expect(forTables.engine.asked.length, greaterThan(asked));
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
    expect(forMatches.matches.deleted, hasLength(1));
  });
}
