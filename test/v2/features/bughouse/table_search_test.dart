import 'dart:async';

import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

/// The book's answer for the start: e4 and d4 on board 1 scored for
/// `even` and `ahead`, A + B's side.
HivemindFound startInBook() => const HivemindFound({
  (BoardNumber.one, 'e2e4'): {
    ClockCase.even: (score: TableScore(score: 0.20), pv: 'A e4 · C e5'),
    ClockCase.abMaySit: (score: TableScore(score: 2.40), pv: 'A e4 · sit'),
  },
  (BoardNumber.one, 'd2d4'): {
    ClockCase.even: (score: TableScore(score: 0.30), pv: 'A d4 · C d5'),
  },
});

void main() {
  late BughouseLab lab;
  late ScriptedBughouse outside;
  late TableSearch search;

  setUp(() {
    lab = BughouseLab();
    outside = ScriptedBughouse();
    search = TableSearch(
      lab: lab,
      book: outside.book,
      startEngine: () => outside.outside.launch(cores: 2),
      depth: (ownNodes: 50, childNodes: 20, topMoves: 2),
      passes: const [Duration(seconds: 1), Duration(seconds: 2)],
    );
  });

  tearDown(() {
    search.dispose();
    lab.dispose();
  });

  test(
    'a position in the book is scored at once, and nothing is searched',
    () async {
      outside.book.positions[TablePosition.initial.bookKey] = startInBook();
      search.open();
      await pumpEventQueue();
      expect(search.scores, isA<ScoresFromBook>());
      final rows = tableRows(
        lab.position,
        BoardNumber.one,
        search.scores.scores,
      );
      // Board 1 is A's (A + B), so the book's numbers read as they are.
      expect(rows.first.move.san, 'd4');
      expect(rows.first.score.text, '+0.30');
      expect(rows[1].move.san, 'e4');
      expect(rows[2].score.text, '—');
      expect(outside.starts, 0);
    },
  );

  test('the Time chip reads the book’s other clock without a search', () async {
    outside.book.positions[TablePosition.initial.bookKey] = startInBook();
    search.open();
    await pumpEventQueue();
    lab.setClock(ClockCase.abMaySit);
    await pumpEventQueue();
    final rows = tableRows(lab.position, BoardNumber.one, search.scores.scores);
    expect(rows.first.score.text, '+2.40');
    expect(outside.starts, 0);
  });

  test('a position the book lacks is scored by the engine', () async {
    search.open();
    await pumpEventQueue();
    final scores = search.scores as ScoresSearched;
    expect(scores.finished, isTrue);
    // Both teams searched for the zero, then two moves a board answered.
    final asked = outside.engine.asked;
    expect(asked.take(2).map((q) => q.team), [Team.ab, Team.cd]);
    expect(asked.first.budget, isA<NodeBudget>());
    expect(asked.length, 2 + 4);
    expect(scores.scores.length, 4);
    // The table is read from the mover's side: C + D moves on board 2.
    final two = tableRows(lab.position, BoardNumber.two, scores.scores);
    expect(two.first.score.isEmpty, isFalse);
    expect(two.first.pv, startsWith('D '));
  });

  test('a clock the book lacks is searched, not shown empty', () async {
    outside.book.positions[TablePosition.initial.bookKey] = startInBook();
    lab.setClock(ClockCase.cdMaySit);
    search.open();
    await pumpEventQueue();
    expect(search.scores, isA<ScoresSearched>());
    expect(outside.engine.asked.first.maySit, isFalse);
    expect(outside.engine.asked[1].maySit, isTrue);
  });

  test('a search made before is remembered', () async {
    search.open();
    await pumpEventQueue();
    final asked = outside.engine.asked.length;
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    lab.go(BoardNumber.one, 0);
    await pumpEventQueue();
    final before = outside.engine.asked.length;
    expect(before, greaterThan(asked));
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    expect(outside.engine.asked.length, before);
  });

  test('a new position makes the search on the old one stale', () async {
    outside.engine.hold = true;
    search.open();
    await pumpEventQueue();
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    // The move cut the old search short; its answer is not the new table's.
    expect(outside.engine.stops, greaterThan(0));
    outside.engine.hold = false;
    outside.engine.release();
    await pumpEventQueue();
    final scores = search.scores as ScoresSearched;
    for (final key in scores.scores.keys) {
      expect(
        lab.position.legalMoves(key.$1).map((m) => m.uci),
        contains(key.$2),
      );
    }
    expect(scores.finished, isTrue);
  });

  test(
    'an engine that will not start says so, until it is switched on',
    () async {
      outside.startFailure = 'This build has no bughouse engine.';
      search.open();
      await pumpEventQueue();
      final trouble = (search.scores as ScoresFailed).trouble;
      expect(trouble, isA<EngineNotStarted>());
      expect(trouble.reason, 'This build has no bughouse engine.');
      lab.play(BoardNumber.one, 'e2e4');
      await pumpEventQueue();
      expect(outside.starts, 1);
      outside.startFailure = null;
      search.toggleEngine();
      await pumpEventQueue();
      expect(outside.starts, 2);
      expect((search.scores as ScoresSearched).finished, isTrue);
    },
  );

  test('an engine that dies mid-search fails the tables in words', () async {
    outside.engine.hold = true;
    search.open();
    await pumpEventQueue();
    outside.engine.crash();
    await pumpEventQueue();
    final trouble = (search.scores as ScoresFailed).trouble;
    expect(trouble, isA<SearchFailed>());
    expect(trouble.reason, 'The bughouse engine stopped.');
  });

  group('The engine switch', () {
    List<HivemindQuestion> passes() => [
      for (final q in outside.engine.asked)
        if (q.budget is TimeBudget) q,
    ];

    test('searches both teams in passes that think longer each time', () async {
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      final on = search.lines as LinesOn;
      expect(on.thinking, isNull);
      expect(on.zero, ZeroSource.measured);
      expect(on.lines.keys, {Team.ab, Team.cd});
      expect(on.lines[Team.ab]!.rows.length, 3);
      // A + B's cp −200 against C + D's −200 is level.
      expect(on.lines[Team.ab]!.advantage.text, '0.00');
      expect(passes().map((q) => (q.budget as TimeBudget).time), [
        const Duration(seconds: 1),
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 2),
      ]);
      expect(passes().map((q) => q.team), [Team.ab, Team.cd, Team.ab, Team.cd]);
      expect(passes().every((q) => q.lines == 3), isTrue);
    });

    test('waits for the tables before its first pass', () async {
      search
        ..toggleEngine()
        ..open();
      await pumpEventQueue();
      final asked = outside.engine.asked;
      final firstPass = asked.indexWhere((q) => q.budget is TimeBudget);
      expect(firstPass, greaterThan(0));
      expect(
        asked.skip(firstPass).where((q) => q.budget is NodeBudget),
        isEmpty,
      );
    });

    test('asks with the clock chip', () async {
      lab.setClock(ClockCase.abMaySit);
      search
        ..open()
        ..toggleEngine();
      await pumpEventQueue();
      expect(passes().first.maySit, isTrue);
      expect(passes()[1].maySit, isFalse);
      expect(passes().every((q) => q.mustMove == MustMove.either), isTrue);
    });

    test('off, the pass under way is cut short and its lines go', () async {
      search.open();
      await pumpEventQueue();
      outside.engine.hold = true;
      search.toggleEngine();
      await pumpEventQueue();
      expect(search.lines, isA<LinesOn>());
      final stops = outside.engine.stops;
      search.toggleEngine();
      expect(outside.engine.stops, greaterThan(stops));
      await pumpEventQueue();
      expect(search.lines, isA<LinesOff>());
      expect(passes().length, 1);
    });

    test('a new position starts the passes again from there', () async {
      search.open();
      await pumpEventQueue();
      outside.engine.hold = true;
      search.toggleEngine();
      await pumpEventQueue();
      lab.play(BoardNumber.one, 'e2e4');
      outside.engine.hold = false;
      outside.engine.release();
      await pumpEventQueue();
      final on = search.lines as LinesOn;
      expect(on.position, lab.position);
      expect(on.thinking, isNull);
    });

    test('an engine that fails turns the switch off in words', () async {
      search.open();
      await pumpEventQueue();
      outside.engine.answer = (_) => const HivemindFailed('it broke');
      search.toggleEngine();
      await pumpEventQueue();
      expect(search.engineOn, isFalse);
      final stopped = search.lines as LinesStopped;
      expect(stopped.trouble.reason, 'it broke');
    });
  });

  test('leaving the mode quits the engine; coming back starts one', () async {
    outside.engine.hold = true;
    search.open();
    await pumpEventQueue();
    search.close();
    await outside.engine.exited;
    expect(outside.starts, 1);
    search.open();
    await pumpEventQueue();
    // The scripted engine has gone, so the next start hands back a dead
    // one; what matters is that another was asked for.
    expect(outside.starts, 2);
  });

  test(
    'an engine that finishes starting after the lab is gone is quit',
    () async {
      final starting = Completer<HivemindStart>();
      final late = TableSearch(
        lab: lab,
        book: outside.book,
        startEngine: () => starting.future,
      )..open();
      await pumpEventQueue();
      late.dispose();
      final engine = ScriptedHivemind();
      starting.complete(HivemindStarted(engine));
      await pumpEventQueue();
      expect(engine.gone, isTrue);
    },
  );
}
